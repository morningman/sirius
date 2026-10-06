# Sirius 接口与能力边界

> 基线：`sirius` @ `84ea4ab5`（dev）。权威定义在 `sirius/src/include/sirius_ffi.hpp`，
> 本文是速查 + 集成方视角的注意事项。

## FFI 接口

```cpp
namespace sirius::ffi {

class Context {                       // 一个引擎上下文（含内嵌 DuckDB，仅用于把 Substrait 降级成 LogicalOperator）
  void execute_substrait(const std::string& plan, std::uintptr_t out_stream_addr);
};
std::unique_ptr<Context> make_context();
std::unique_ptr<Context> make_context_from_config(const std::string& config_path);

class Fragment {                      // 多 fragment 查询中的一个
  void declare_input_column(u64 stream_id, const string& name, const string& type);  // type 是 DuckDB 类型名
  void declare_input_sender(u64 stream_id, u32 sender_id);
  void declare_output(u64 stream_id);
  void declare_output_broadcast();
  void declare_output_hash_key(u32 column_index);
  void build(const std::string& substrait_plan);          // 打开 query lifecycle
  size_t relay_from(Fragment& src, u64 src_stream, u64 in_stream, u32 sender_id);
  void close_input(u64 stream_id, u32 sender_id);
  void run();                                             // 阻塞；关闭 query lifecycle
  void result_to_arrow(std::uintptr_t out_stream_addr);
  std::unique_ptr<std::vector<std::string>> output_types() const;
};
std::unique_ptr<Fragment> make_fragment(Context&);
std::unique_ptr<std::string> stream_view_name(u64 stream_id);   // → "sirius_stream_<id>"
}
```

**调用顺序**：declare inputs/outputs → `build()` → 各 sender `relay_from`/`push` → `run()` →
`result_to_arrow()`。

## 集成必须知道的约束

| 约束 | 影响 | 出处 |
|---|---|---|
| 🔴 **引擎进程内串行** —— 一个 Context 同时只能跑一个 query；`build()` 与 `run()` 之间只能有一个 fragment | BE 是多租户的，必须做准入控制（抢不到槽位就退 CPU） | `sirius_ffi.hpp` Fragment 类注释 |
| 🔴 **input stream 无背压** —— 无界队列 | Doris scanner 快过 GPU 是常态，不限流会 OOM。用 Doris 原生 `Dependency` 阻塞 | `docs/super-sirius/streaming-sessions.md` §No backpressure |
| 🟡 **`run()` 阻塞** | 需要后台线程跑 `run()`，主线程 `get_block` 拉结果 | 同上 |
| 🟡 **无 `cancel()` 接口** | Doris 查询取消无法中断 GPU 执行。兜底：`close_input()` 让 fragment 自然收敛 + join 超时 | — |
| ✅ **`push()` 线程安全**，batch 先入队再触发唤醒 | 多个 scanner 线程可以并发喂 | `streaming-sessions.md` 不变式 S1/S2 |
| ✅ **batch 以原生 tier 跨界**，不强制物化成 Arrow | 排队中的 batch 仍可被 spill（GPU→host→disk） | 同上 |

## 🔴 三个阻断性缺口（2026-09-01 核实）

集成 Doris 需要的能力，FFI 今天**不具备**。这三条是提给 Sirius 的核心诉求，按阻断程度排序。

### 缺口 1 · 没有外部 Arrow 输入口 —— 最硬的一条

FFI 的输入输出是**不对称的**：

| 方向 | 手段 | 状态 |
|---|---|---|
| 拿数据出来 | `Fragment::result_to_arrow(addr)` | ✅ 有 |
| 把外部数据喂进去 | 只有 `relay_from(Fragment& source, ...)` —— 从**同进程另一个 Fragment** 搬批次 | ❌ **没有** |

内部是有 `stream_session::push(stream_id, batch)` 的，但它收 `cucascade::data_batch` 原生类型，
且没暴露到 FFI 上。

**这直接打在 ADR-004（边界统一化）的要害上**：整个设计依赖「Doris 的 scan 把 Block 转 Arrow
推进 `sirius_stream_k`」，而这个动作现在做不到。

期望的接口：
```cpp
void Fragment::push_arrow(uint64_t stream_id, uint32_t sender_id,
                          uintptr_t arrow_array_addr, uintptr_t arrow_schema_addr);
```

> 没有 C ABI 只是集成得难看；**没有输入口是根本跑不通**。这条优先级高于下面两条。

### 缺口 2 · 没有 C ABI，接口是纯 C++ 且会抛异常

`sirius_ffi.hpp` 里**一个 `extern "C"` 都没有**。跨边界传的是 `std::unique_ptr` /
`std::string` / `std::vector`，而且方法会抛异常（`@throws on translation/planning failure`）。

现有的嵌入方（`rust/crates/sirius-sys`）用 **cxx.rs** 绑定，靠的是**和 Sirius 在同一个构建树 /
同一套工具链里共编**（`SIRIUS_BUILD_DIR` 指向 build tree）。这回避了问题，没有解决问题。

Doris BE 的工具链是独立的一套（见 `doris-anatomy.md` 的工具链一节），跨 `dlopen` 边界传 std
类型 + 抛异常，要求两边 libstdc++ 版本与 unwinder 严格匹配 —— 没人保证。

**注意数据面已经是纯 C ABI 了**（Arrow C Data Interface 就是为这个设计的）。只有控制面那十来个
方法是 C++ ABI，改造范围有限。

### 缺口 3 · 没有可分发的 libsirius 产物

`sirius_ffi.hpp` 自己的注释就承认：

> *"This is the seed of the public C++ API `libsirius` will expose; today it is compiled into
> the DuckDB extension, which the bindings link against until a dedicated `libsirius` exists."*

CMake 里没有独立的 libsirius target，没有 install target，没有版本化发布物。
外部项目今天没有干净的依赖方式。

> **2026-09-01 P0 修正**：这条只对了一半。`distribution.yml` 的 vcpkg 构建每次 dev push 都产出
> 4 个变体（amd64/arm64 × cuda12/13）的**单文件 DSO**（GitHub Actions artifact，520 MB，90 天过期，
> 无 Release）。它的依赖（cudf/rmm/cuCascade/abseil/openssl/curl/protobuf…）已经全静态隐藏，
> 但 **libstdc++/libgcc/libgomp 和 7 个 CUDA 库仍是动态的**。缺的是：一个用同一组 object 换链接参数
> 的 `libsirius` target（静态 libstdc++ + version script）、C 头文件、版本化、发布渠道。
> 详见 `../embeddability-study.md` §2。

### ⚠️ 附带风险 · 依赖闭包冲突（P0 已实测，结论见 `../embeddability-study.md` §5）

**P0 结论（2026-09-01）**：下表是调研前的猜测，保留作对照，**其中 protobuf / abseil / arrow 三行不成立**：
Sirius 把 protobuf 3.19.4 源码 vendor 进扩展并以 `-fvisibility=hidden` 编译；abseil 有 `lts_YYYYMMDD`
inline namespace，跨版本符号名不同；Sirius 闭包里没有 Arrow C++（cudf 用 nanoarrow）。真实产物
`LD_PRELOAD` 进真实 `doris_be`：这三者绑到 BE 的符号数为 **0**。**真正的冲突面是 libstdc++**：Doris BE
`ENABLE_EXPORTS`（= `-rdynamic`）导出了自己静态链接的 libstdc++（50,662 个符号），Sirius 产物的 549 个
libstdc++ 引用全绑到了它上面。解法在 Sirius 侧：libsirius `-static-libstdc++ -static-libgcc` + 隐藏。

进程内方案会把 libsirius 的整个依赖闭包拉进 Doris BE 的地址空间。调研前列出的重叠：

| 库 | Doris BE | Sirius | 风险 |
|---|---|---|---|
| **protobuf** | `thirdparty` 固定 **21.11** | conda `libprotobuf`（版本差很远） | 🔴 全局注册表、静态初始化顺序、ODR |
| **abseil** | `thirdparty/installed/include/absl` | `libabseil` | 🔴 abseil 版本间 ABI 断裂是常态，且是 protobuf≥22 的硬依赖 |
| **arrow** | `thirdparty/arrow-24.0.0` | cuDF 的 Arrow interop | 🟡 |
| openssl / curl / spdlog / sqlite | thirdparty | conda | 🟡 |

（调研前的判断：「同进程两份 protobuf + 两份 abseil 是典型的爆炸场景」—— 对 Sirius 不成立，见上。）
实测过的缓解手段：全静态 + `-fvisibility=hidden` + `--exclude-libs,ALL` + version script 对 protobuf
等依赖**完全免疫**；再加 `-static-libstdc++ -static-libgcc` 后对宿主导出什么都无感；
`RTLD_DEEPBIND` 能隔离但把 malloc 也劈成两套（插件走 glibc、宿主走 jemalloc），不采用。
C++ 异常在两套运行时之间必崩 → C ABI 必需。

---

## ⚠️ 是 duckdb-substrait 方言，不是纯 Substrait

`sirius/src/sirius_ffi.cpp:73` → `duckdb::SubstraitToDuckDB`。函数名、类型编码、扩展 URN 都是
DuckDB 特定的。**所有方言特例集中放 `translator/dialect.{h,cpp}`。**

叶子读法：
- stream 输入 → `ReadRel{ NamedTable{ names: ["sirius_stream_<k>"] } }`
  （`build()` 会自动建这个 view）
- parquet 直读（MVP-3）→ `local_files`，DuckDB 端解析成 `parquet_scan(<paths>)`

现成参考：`sirius/experimental/starrocks/crates/starrocks-plan-translator/`，
crate 文档（`src/lib.rs:1-80`）列了它支持的算子/表达式对应表，`scan_paths.rs` 是 `local_files`
的 fail-closed 实现范例。

## 能力边界（翻译器白名单的上界）

**算子**（`docs/super-sirius/physical-plan-generation.md:18`）
scan / project / filter / agg（grouped + ungrouped）/ 9 类 join（inner, left, semi, anti, mark,
outer, right, right_semi, right_anti；**single 不支持**）/ order by / top-n / limit /
materialized CTE。

**不支持**：窗口函数、UNION/EXCEPT/INTERSECT、`SELECT DISTINCT`、递归 CTE、UNNEST、SAMPLE、
PIVOT、ASOF/ANY join、CROSS PRODUCT、**全部写路径**、EXPLAIN、PREPARE/EXECUTE。

**聚合函数只有 8 个**（`src/expression/aggregate_id.cpp:34`）
`sum` `sum_no_overflow` `count` `count_star` `min` `max` `avg` `first`
— 没有 stddev / median / approx_count_distinct / string_agg，也没有 DISTINCT 聚合。

**标量函数只有 29 个 id**（`src/expression/function_id.cpp:34`）
`+ - * / // %` · `substring`/`substr` · `~~`(like) `!~~`(not like) · `contains` `prefix` `suffix` ·
`strlen` `length` · `regexp_replace` · `concat` `||` ·
`year` `month` `day` `hour` `minute` `second` `millisecond` `microsecond` `date_trunc` ·
`row` `struct_pack` `error`
— **没有 upper / lower / trim / round / abs / replace / split**。

比较、AND/OR/NOT、CASE、CAST、COALESCE、BETWEEN、IN 是独立 AST 节点
（`src/include/expression/ast/`），不受这 29 个限制。

**类型**（`src/include/cudf/cudf_utils.hpp:161`）
全部整型（含无符号）、float/double、bool、DATE、4 种精度 TIMESTAMP、VARCHAR、
DECIMAL32/64/128、STRUCT/LIST/MAP（**仅透传，不能参与运算**）。

🔴 **HUGEINT / UHUGEINT 映射成 INT64 且静默截断**，代码自带
`FIXME: Values outside INT64 range are silently corrupted`（:169）。
Doris 的 `LARGEINT` 必须硬拒绝。

🔴 **DECIMAL precision ≤ 4 抛错**（DuckDB 用 INT16 存，无 cuDF 对应）。

## 相关文档

`sirius/docs/super-sirius/` 下：`streaming-fragments.md`（fragment 层）、
`streaming-sessions.md`（stream 原语与不变式）、`physical-plan-generation.md`（算子映射与拒绝规则）、
`operators.md`（各算子的 cuDF 实现与 join 模式矩阵）。
