# Doris 侧代码索引

> 基线：`wt-gpu` @ `df36be5a86d`（追踪 apache/master，2026-08-31）
> 行号会漂移，用符号名二次确认。

## ⚠️ 目录结构已重构

这个版本的 Doris **没有 `be/src/vec/`，也没有顶层 `be/src/pipeline/`**。老资料里的路径基本都失效了：

| 内容 | 现在的位置 |
|---|---|
| pipeline 执行 | `be/src/exec/pipeline/` |
| 算子（151 个文件） | `be/src/exec/operator/` |
| 扫描 | `be/src/exec/scan/` |
| 各类 sink | `be/src/exec/sink/` |
| Block / Column / DataType | `be/src/core/` |
| 列序列化（含 Arrow） | `be/src/core/data_type_serde/` |
| 文件格式读取（parquet/orc/native） | `be/src/format/`、`be/src/format_v2/` |
| 表达式 | `be/src/exprs/` |
| fragment 生命周期 | `be/src/runtime/fragment_mgr.{h,cpp}` |

## pipeline 构建路径（GPU 卸载的挂载点）

```
PInternalService::exec_plan_fragment          be/src/service/internal_service.cpp
  └─ FragmentMgr::exec_plan_fragment          be/src/runtime/fragment_mgr.cpp
       └─ PipelineFragmentContext::prepare()                    exec/pipeline/pipeline_fragment_context.cpp:359
            └─ _build_and_prepare_full_pipeline()               :285      ← ★ 卸载判定插在这之前
                 └─ _build_pipelines()                          :703
                      └─ _create_tree_helper()                  :903      扁平先序递归重建
                           └─ _create_operator()                :1502     ~550 行 switch
```

**M0.1 的 dump 点**：`prepare()` 里 `_params` 已就位；或更早在 `FragmentMgr::exec_plan_fragment`
拿到 thrift 结构时。前者更靠近卸载判定的位置，语料形状也更接近实际输入。

**M1.4 的挂载点**：`_build_and_prepare_full_pipeline()` 里 `_build_pipelines()` 之前。
注意 L2 回退（`design.md` §4.5）需要「pipeline 能重建一次」，当前这条路径是一次性的，要小改造。

## IDL 索引

| 结构 | 文件 : 行 | 备注 |
|---|---|---|
| `TPipelineFragmentParams` | `gensrc/thrift/PaloInternalService.thrift:720` | Doris 用它，**不是** StarRocks 的 `TExecPlanFragmentParams` |
| ↳ `.fragment` | 字段 23 | `Planner.TPlanFragment`，内含 `TPlan plan` |
| ↳ `.desc_tbl` | 字段 5 | `TDescriptorTable` |
| ↳ `.file_scan_params` | 字段 29（:751） | scan node id → `TFileScanRangeParams`，**MVP-3 叶子下沉的入口** |
| ↳ `.local_params` | 字段 24 | `list<TPipelineInstanceParams>`，每实例参数 |
| ↳ 下一个可用字段号 | **47**（46 = `need_notify_close`） | 加 `executor_hint` 时用 |
| `TPlanNodeType` | `gensrc/thrift/PlanNodes.thrift:28` | 0–38，`LOCAL_EXCHANGE_NODE=38`；新增外部执行器节点可用 **39** |
| `TExprNodeType` | `gensrc/thrift/Exprs.thrift:24` | 0–37 |
| `TPrimitiveType` | `gensrc/thrift/Types.thrift:59` | 0–44 |
| `TDataSinkType` | `gensrc/thrift/DataSinks.thrift:27` | `DATA_STREAM_SINK=0`、`RESULT_SINK=1` |
| `TResultSinkType` | 同上 :51 | `MYSQL_PROTOCOL=0`、`ARROW_FLIGHT_PROTOCOL=1` |
| `TFileRangeDesc` | `gensrc/thrift/PlanNodes.thrift:597` | `path` / `start_offset` / `size` / `format_type` |
| `TFileFormatType` | 同上 :112 | `FORMAT_PARQUET=6` |
| `TBackendInfo` | `gensrc/thrift/HeartbeatService.thrift:55` | 目前无 capabilities 字段（改进建议之一） |
| `PBackendService` | `gensrc/proto/internal_service.proto:1229–1288` | 60+ RPC，方案 A 被否决的直接原因 |

**plan 与 expr 都是扁平先序数组**：每个节点带 `num_children`，孩子紧随其后（深度优先）。
重建时按 `num_children` 递归消费，最后必须恰好用光整个 slice —— 这条不变式见 `tasklist.md` M0.3。

## Block / Column 内存布局

`be/src/core/column/`

| 列类型 | 布局 | → Arrow |
|---|---|---|
| `ColumnVector<T>` | 连续 `PODArray` | 零拷贝，直接给 `data()` |
| `ColumnDecimal<Decimal32/64/128>` | 同上 | 零拷贝，scale 映射到 `decimal128(p,s)` |
| `ColumnStr<UInt32>` | `chars` + `offsets`（**末尾偏移**，长度 n） | 见下 |
| `ColumnStr<UInt64>` | 同上，64 位 offsets | → `large_utf8` |
| `ColumnNullable` | `NullMap = ColumnUInt8::Container`，**byte per row，1 = null** | 需打包成 bitmap，且语义取反（Arrow 1 = valid） |

### ★ 字符串 offsets 可以零拷贝

`column_string.h:86` 注释：*"Maps i'th position to offset to i+1'th element"*，
即 `offsets` 是长度 n 的**末尾偏移**数组，而 `offset_at(i)` 实现为 `offsets[i-1]` ——
i=0 时读 `offsets[-1]`。

这是合法的：`PaddedPODArray` 在 `be/src/core/pod_array.h:167` 显式
`if (pad_left) memset(c_start - ELEMENT_SIZE, 0, ELEMENT_SIZE);`，
**保证 `offsets[-1] == 0` 且可读**。

所以 `&offsets[-1]` 就是一个合法的、长度 n+1 的、语义正确的 Arrow offset buffer。

**必须加的守卫**：Arrow `utf8` 的 offset 是有符号 int32，而 `ColumnStr<UInt32>` 上限是
`MAX_STRING_SIZE = 4294967295`。当 `offsets.back() > INT32_MAX` 时降级 `large_utf8`（需拷贝）
或拒绝该 batch。

### 现有 Arrow 转换是慢路径

`be/src/core/data_type_serde/data_type_serde.h:500`
```cpp
virtual Status write_column_to_arrow(const IColumn&, const NullMap*,
                                     arrow::ArrayBuilder*, int64_t start, int64_t end, ...);
```
逐值构建，GB 级数据不可用。**不要走这条路**，新写基于 Arrow C Data Interface 的导出
（`tasklist.md` M1.1，本身也是给 Doris 提的独立改进）。

## 工具链、ABI 与依赖（嵌入 libsirius 相关）

P0 调研（`../tasklist.md`）的起手材料。

### 工具链与标准库

| 项 | 值 | 出处 |
|---|---|---|
| 默认编译器 | **clang**（Linux 和 macOS 都是） | `env.sh:127-133` |
| `USE_LIBCPP` | **Linux 上 OFF**，仅 macOS ON | `be/CMakeLists.txt:81`、`:97-99`、`build.sh:622-627` |
| ⇒ Linux 上的标准库 | **libstdc++**（clang + libstdc++） | 推论 |
| C++ 标准 | C++20 | `be/CMakeLists.txt:406` |
| `_GLIBCXX_USE_CXX11_ABI` | 未显式设置（= 默认 1） | grep 无命中 |

Sirius 侧走 pixi/conda 的 `cxx-compiler`（gcc）→ 也是 libstdc++。
**stdlib 家族一致，但工具链是两套独立管理的**，版本skew 与异常跨界仍需要一个明确答案。

### 与 Sirius 重叠的第三方依赖 ⚠️

进程内加载 libsirius 会把它的依赖闭包拉进 BE 地址空间。已知重叠：

| 库 | Doris BE | Sirius | 风险 |
|---|---|---|---|
| **protobuf** | thirdparty 固定 **21.11**（`thirdparty/vars.sh`） | conda `libprotobuf`（`pixi.toml:38`） | 🔴 全局注册表 / 静态初始化顺序 / inline ODR |
| **abseil** | `thirdparty/installed/include/absl` | `libabseil`（`pixi.toml:49`） | 🔴 版本间 ABI 断裂是常态；protobuf≥22 的硬依赖 |
| **arrow** | `thirdparty/arrow-24.0.0`（`be/CMakeLists.txt:231`） | cuDF 的 Arrow interop | 🟡 |
| openssl / curl | thirdparty | `pixi.toml:55-56` | 🟡 |
| spdlog / sqlite | thirdparty | `pixi.toml:51-52` | 🟡 |

**Doris BE 已经链了 Arrow 24.0.0** —— 这既是风险（版本冲突）也是机会
（Block↔Arrow 桥接可以复用已有的 Arrow 类型系统，不必额外引入依赖）。

## 其它

- **算子基类**：`be/src/exec/operator/operator.h` — `OperatorXBase`（`get_block_impl` 纯虚，:905）、
  `DataSinkOperatorXBase`（`sink_impl` 纯虚，:623）。自定义 source 算子照着实现即可。
- **session 变量**：`fe/fe-core/src/main/java/org/apache/doris/qe/SessionVariable.java`，
  `@VarAttr` 注解，现有 503 个。加 `enable_gpu_execution` 照抄 `ENABLE_FILE_SCANNER_V2` 的写法。
- **BE 无插件机制**：`be/src/runtime/plugin/` 只有 cloud plugin downloader，不是通用扩展点。
- **worktree 协议**：`wt-gpu/AGENTS.md` 顶部有 worktree 初始化要求，见 `../environment.md`。
