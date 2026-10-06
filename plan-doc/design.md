# Apache Doris × Sirius GPU 引擎集成设计

> 状态：设计草案 · 2026-09-01
> 勘察基线：Doris master @ `6b5c53fdb4e` · Sirius `dev` @ `84ea4ab5`
> 开发基线：`wt-gpu` 分支 @ `df36be5a86d`（本文所有 Doris 代码位置已在该分支复核）
> 本文是文档空间的一部分，入口见 [README.md](README.md)；开工前先读 [handoff.md](handoff.md)

---

## 0. TL;DR

**不要复制 `experimental/starrocks` 的伪 CN 方案。** Doris BE 的对外契约（60+ 个 BRPC 方法、
AgentService、心跳/汇报、runtime filter、load stream）远比 StarRocks CN 厚，伪装一个 BE 的成本
和版本漂移风险不可接受，而且它天然读不到 Doris 的存储。

**推荐方案：在 BE 进程内做「fragment 子树卸载」。** 在 `PipelineFragmentContext` 构建 pipeline
之前插入一次判定，把 fragment 中「最大的可翻译连续子树」替换成一个 `SiriusOffloadOperator`；
子树的所有叶子（无论原本是 OLAP scan、file scan 还是 exchange）统一退化成「Doris 喂 Block 进
来」。Doris 的调度、shuffle、runtime filter、内存管理、错误处理全部原样保留。

**契约只有两个，且都是版本化的行业标准**：进去是 Substrait plan bytes，出来是 Arrow C Data
Interface。Doris 侧只依赖 `sirius_ffi.hpp` 一个头文件，不引入任何 cuDF/RMM/DuckDB 头文件；
Sirius 侧完全不知道 Doris 存在。

**MVP 的诚实定位**：第一版是「GPU 加速 fragment 的计算部分，扫描仍在 CPU」，因此只在
compute/scan 比高的查询上赢。要拿到 Sirius 在 DuckDB 上那种 5x 量级的数字，必须走到 MVP-3
（GPU 直读 parquet）之后。这一点必须提前对齐预期，否则 MVP-1 的 benchmark 会很难看。

---

## 1. 背景与约束

### 1.1 事实基线（勘察结论）

**Sirius 侧**

| 事实 | 依据 |
|---|---|
| 已经有一套为「分布式引擎接入」专门设计的 FFI | `src/include/sirius_ffi.hpp`：`Context` / `Fragment`，declare stream → build(substrait) → run → 拉 Arrow |
| 输入/输出以 stream 建模，`push()` 线程安全，可边跑边喂 | `docs/super-sirius/streaming-sessions.md` 不变式 S1/S2 |
| 消费的是 **duckdb-substrait 方言**，不是纯 Substrait | `src/sirius_ffi.cpp:73` → `duckdb::SubstraitToDuckDB` |
| 算子面：scan / filter / project / agg / 9 类 join / sort / topn / limit / CTE | `docs/super-sirius/physical-plan-generation.md:18` |
| 函数面很窄：8 个聚合、29 个标量函数 id | `src/expression/aggregate_id.cpp:34`、`src/expression/function_id.cpp:34` |
| 不支持：窗口函数、UNION/EXCEPT/INTERSECT、DISTINCT、递归 CTE、全部写路径 | `sirius_physical_plan_generator.cpp:1111` 起 |
| **HUGEINT/UHUGEINT 静默截断为 64 位** | `src/include/cudf/cudf_utils.hpp:169`，代码自带 `FIXME: silently corrupted` |
| 引擎**进程内串行**：一个 Context 同时只能跑一个 query | `sirius_ffi.hpp` Fragment 文档注释 |
| input stream **无背压**（无界队列） | `docs/super-sirius/streaming-sessions.md` §No backpressure |

**Doris 侧**

| 事实 | 依据 |
|---|---|
| pipeline 从 thrift 扁平先序树构建，入口单一 | `be/src/exec/pipeline/pipeline_fragment_context.cpp:703` `_build_pipelines` → `_create_tree_helper` |
| 算子创建是一个 ~550 行的 switch，无注册机制 | 同文件 `:1502` `_create_operator` |
| `Block` 列存布局对 Arrow 极友好 | `ColumnVector<T>` = 连续 PODArray；`ColumnStr<T>` = chars + 末尾偏移；`ColumnNullable` = byte-per-row null map |
| **`PaddedPODArray` 保证 `offsets[-1] == 0`** | `be/src/core/pod_array.h:167` `memset(c_start - ELEMENT_SIZE, 0, ELEMENT_SIZE)` |
| 现有 Block→Arrow 是逐值 `ArrayBuilder` 路径（慢） | `be/src/core/data_type_serde/data_type_serde.h:500` `write_column_to_arrow` |
| 外表 file scan 的 split 已在 fragment 参数里 | `TPipelineFragmentParams.file_scan_params` (`PaloInternalService.thrift:751`) |
| BE 无任何能力上报机制 | `TBackendInfo` (`HeartbeatService.thrift:55`) 只有端口/版本/内存 |
| BE 无插件/动态算子注册机制 | `be/src/runtime/plugin/` 只有 cloud plugin downloader |

### 1.2 设计目标

1. **可行性**：MVP 能在 3 个月内跑通端到端、结果正确、有可复现的 benchmark。
2. **可维护性**：GPU 相关代码可以整体从 BE 中摘除；Doris 主干代码的改动面尽量小且是「通用能力增强」而非「为 GPU 打的补丁」。
3. **正确性优先于覆盖率**：宁可少卸载，不可跑出错误结果。
4. **零默认风险**：默认关闭；打开后遇到任何不确定情况都退回 CPU。

### 1.3 非目标（MVP 阶段明确不做）

- 写路径（INSERT / load / MOW / compaction）
- Doris 原生存储格式（segment v2）的 GPU 解码
- 多 GPU 跨 BE 调度、GPU 亲和的 FE 代价模型
- 执行期动态回退

---

## 2. 可行性分析：三种候选架构

### 2.1 方案 A — 伪 BE / CN 进程（StarRocks shim 模式）

独立进程注册进 FE，接管 `exec_plan_fragment`，自己实现心跳、汇报、结果拉取。

| | |
|---|---|
| ✅ | 零侵入 Doris 代码；可以独立仓库演进 |
| ❌ | Doris `PBackendService` 有 **60+ 个 RPC**（`internal_service.proto:1229-1288`），还有 AgentService 的 tablet 生命周期、runtime filter 的 merge/publish、load stream。要「看起来像个 BE」的表面积极大 |
| ❌ | 每个 Doris 版本都会加字段/加 RPC，shim 永远在追 |
| ❌ | **读不到 Doris 存储**。和 StarRocks 那边一样，只能查外表 —— 而 Doris 用户的主力场景是内表 |
| ❌ | runtime filter、colocate、bucket shuffle 这些 Doris 的核心优化全部失效 |

**它到底是什么**：不是「用 Rust 重写了一套 BE 执行代码」，而是一个**协议外壳**。
~9000 行 Rust 里，协议外壳（thrift servers、手写 BRPC/PRPC 帧、FE 自注册与心跳）约 4600 行、
plan 翻译约 3400 行、结果编码约 460 行、引擎桥接约 510 行，**查询执行 0 行** —— 扫描、过滤、
join、聚合、表达式求值全部由 Sirius 的 C++/CUDA 引擎完成，入口就是
`context.execute_substrait(plan)` 一行。BRPC `PInternalService` 只实现了 4 个方法，
thrift `BackendService` 24 个 handler 里 15 处直接返回 `NOT_IMPLEMENTED`。

**耦合面是三处**，不止 plan：① 节点身份（自注册 / 心跳 / 汇报）② plan 分发 ③ 结果回传
（自己编码成宿主的 `TResultBatch` MySQL 行格式）。那 4600 行协议外壳就花在 ① 和 ③ 上 ——
纯阻抗匹配，零业务价值，且成本随宿主协议表面积线性增长。

**公允地说，这个方案启动更快**：不用读宿主一行 C++、不进宿主构建系统、不处理 ABI、
不用做回退（翻译失败就查询失败，因为它没有 CPU 引擎可退）、不用过宿主社区 review、
崩了只崩自己。它的代价是协议外壳成为永久税，且版本锁死（pin 在 StarRocks 4.1.1）。

**结论：否决作为长期架构。** 但保留其思想用于 **MVP-0 的离线验证**（见 §5）。

### 2.2 方案 B — BE 内 fragment 子树卸载 ✅

libsirius 作为 BE 的**可选、动态加载**依赖。在 pipeline 构建前判定，把可卸载子树换成一个算子。

| | |
|---|---|
| ✅ | 复用 Doris 全部基础设施：调度、exchange、runtime filter、spill、内存追踪、profile、cancel |
| ✅ | 天然支持所有表类型（内表 / Hive / Iceberg / JDBC / TVF），因为 scan 仍是 Doris 的 |
| ✅ | 卸载粒度可调：从「一个 agg」到「半个 fragment」，可以渐进放开 |
| ✅ | 契约窄（Substrait + Arrow），两边可以独立演进 |
| ⚠️ | libsirius 崩溃会带走整个 BE 进程 —— 需要边车化作为生产硬化手段（§3.4） |
| ⚠️ | MVP 阶段 scan 仍在 CPU，H2D 带宽是瓶颈 |

**代价要说全**（相对 A 的增量复杂度，按工作量倒序）：

1. **在宿主的执行框架里活下去** —— 算子生命周期、`Dependency` 阻塞语义、cancel 传播、
   内存追踪、profile、与 spill 的交互。A 方案有自己的进程，爱怎么活怎么活。**这条最重。**
2. **回退机制** —— 子树最大化判定、L1/L2 两级回退，且因执行期不回退（§4.5），
   eligibility gate 必须完备。A 方案完全不需要（失败就失败）。
3. **嵌入形态本身** —— Sirius 今天还不是一个可嵌入的库（§8.0 的三个缺口）。
4. **依赖闭包冲突** —— 两份 protobuf / abseil 在一个进程里（§8.0(d)）。
5. **社区流程** —— Doris 侧改动要过 apache/doris review；A 方案在 Sirius 自己的
   `experimental/` 下自己说了算。

**结论：采纳。** 判断依据是成本形状：A 的协议外壳是随宿主演进的永久税且拿不到宿主能力，
B 的复杂度是一次性投入，写完即稳定，换来 Doris 的全部基础设施。

### 2.3 方案 C — 算子级替换

给每个 Doris 算子写一个 GPU 版本，在 `_create_operator` 里按需替换。

| | |
|---|---|
| ❌ | 每个算子边界都要 Block↔cuDF 往返，H2D/D2H 反复，性能上根本不成立 |
| ❌ | Doris 算子接口耦合极深：`LocalState` / `SharedState` / `Dependency` / spill / reserve_mem。每个 GPU 算子都要重新实现这一整套，且随 Doris 重构不断破裂 |
| ❌ | 与 Sirius 的 pipeline/任务模型是两套调度器打架 |

**结论：否决。**

### 2.4 决策矩阵

| | A 伪 BE | **B 子树卸载** | C 算子级 |
|---|---|---|---|
| 首次跑通成本 | 中 | 中 | 高 |
| 长期维护成本 | **很高** | 低 | 很高 |
| 内表支持 | 不可能 | **天然** | 天然 |
| 性能上限 | 高（若解决存储） | 高 | 低（往返开销） |
| 对 Doris 主干侵入 | 零 | 小且可摘除 | 大 |
| 崩溃隔离 | **天然** | 需边车化 | 无 |

---

## 3. 总体架构

### 3.1 分层与依赖方向

```
┌──────────────────────────────────────────────────────────────┐
│ Doris FE                                                     │
│   · session var  enable_gpu_execution (默认 false)           │
│   · BE 能力上报  TBackendInfo.capabilities["gpu.sirius"]     │
│   · (可选) Coordinator 的 GPU 亲和调度                        │
└──────────────────────────────────────────────────────────────┘
                    │  TPipelineFragmentParams（结构不变）
                    ▼
┌──────────────────────────────────────────────────────────────┐
│ Doris BE                                                     │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  be/src/exec/gpu_offload/     ← 新模块，可整体摘除       │  │
│  │                                                        │  │
│  │   ① eligibility/   纯函数判定，无 GPU 依赖，可单测      │  │
│  │   ② translator/    TPlanNode/TExpr → Substrait          │  │
│  │   ③ bridge/        Block ↔ Arrow C Data Interface       │  │
│  │   ④ operator/      SiriusOffloadSource/SinkOperator     │  │
│  │   ⑤ runtime/       dlopen libsirius、槽位准入、生命周期  │  │
│  └────────────────────────────────────────────────────────┘  │
│                    │ 仅依赖 sirius_ffi.hpp                    │
└────────────────────┼─────────────────────────────────────────┘
                     ▼
             libsirius.so（独立版本、独立仓库、dlopen 加载）
```

**三条不可违反的依赖规则：**

1. Doris **只**包含 `sirius_ffi.hpp`。不引入 cuDF / RMM / DuckDB / Arrow C++ 任何头文件
   （Arrow C Data Interface 是两个 struct 定义，直接内联进来，不依赖 libarrow）。
2. Sirius **不知道** Doris 存在。仓库里不出现 `doris` 字样。
3. 契约就是 **Substrait protobuf bytes**（进）+ **ArrowArrayStream**（出）。这两个都是稳定的、
   有版本号的、可序列化的 —— 可序列化意味着**可以在没有 GPU 的机器上做契约测试**。

> 这一条是整个设计里最重要的可维护性决策。`experimental/starrocks` 的 96 个翻译器单测能在
> CPU-only CI 上跑（`.github/workflows/experimental.yml` 用 `--no-default-features`），靠的
> 就是这个。Doris 侧要复刻同样的性质。

### 3.2 卸载单元：极大可翻译连续子树

不是整个 fragment，而是**从叶子往上、最大的连续可翻译子树**。

```
        DataStreamSink              ← 留给 Doris（shuffle 语义复杂，不碰）
             │
        AGGREGATION_NODE     ┐
             │               │
        HASH_JOIN_NODE       ├──  卸载子树 → 一个 SiriusOffloadOperator
          ╱        ╲         │
   OLAP_SCAN    EXCHANGE     ┘
      ↑             ↑
      └─────────────┴──  边界：Doris 原生算子产出 Block，push 进 Sirius input stream
```

**为什么不整段卸载 fragment？**
- fragment 顶上的 sink（DataStreamSink / ResultSink）承载了分区、序列化、跨 BE 传输语义，
  重新实现一遍没有收益，且是 bug 温床。
- 底下的 scan 承载了 split 分配、runtime filter 下推、延迟物化、file cache、delete bitmap ——
  这是 Doris 最有价值也最难复制的部分。

**为什么不更小粒度？** 见 §2.3。子树越大，H2D/D2H 往返越少，GPU 的收益越明显。

### 3.3 边界统一化 —— 本设计的关键杠杆

卸载子树的**所有**叶子，不管原本是 `OLAP_SCAN_NODE`、`FILE_SCAN_NODE` 还是 `EXCHANGE_NODE`，
在翻译时统一变成同一样东西：

```
Substrait ReadRel { NamedTable { names: ["sirius_stream_<k>"] } }
```

`sirius_stream_<k>` 是 Sirius FFI 提供的 input stream 视图（`stream_view_name(k)`，
`sirius_ffi.hpp` 最后一个函数）。运行时，Doris 侧对应的原生算子把产出的 Block 转成 Arrow
batch，`push(k, batch)` 进去。

**这带来三个直接后果：**

1. **翻译器完全不需要理解 Doris 的存储层。** 不用管 tablet、rowset、segment、split、
   delete bitmap、MOW、file cache、S3 凭证、Iceberg manifest ——一行都不用。翻译器只处理
   scan 以上的关系代数。这把 MVP 的工作量砍掉了一大半。
2. **所有表类型 day-1 全支持。** 内表、Hive、Iceberg、Hudi、Paimon、JDBC、TVF ——因为扫描
   还是 Doris 自己干的。
3. **未来把 scan 也下沉时，改动是局部的。** MVP-3 把 `FILE_SCAN_NODE` 的叶子从
   `sirius_stream_k` 换成 `local_files`（Sirius 已有 `parquet_gpu_ingestible`），
   只动翻译器的叶子处理，其余不变。

**代价：** H2D 带宽。一个 SF100 的 lineitem 扫描，CPU 解码 + PCIe 传输会吃掉大部分收益。
这必须在 MVP 的预期管理里写死（§5）。

### 3.4 进程内 vs 边车：一个可以延后的决策

| | 进程内（MVP） | 边车进程（生产硬化） |
|---|---|---|
| 传输 | 直接函数调用 | UDS + 共享内存 |
| 延迟 | 零 | ~µs 级握手 |
| 崩溃隔离 | ❌ CUDA/cuDF 崩溃带走 BE | ✅ 只丢当前查询 |
| 显存泄漏隔离 | ❌ | ✅ 可重启 worker |
| 实现成本 | 低 | 中 |

**关键：因为契约是「Substrait bytes 进、Arrow 出」，从进程内换到边车是纯粹的传输层替换 ——
translator、eligibility、operator 三个模块一行不用改。** 这正是选择窄契约的回报。

MVP 走进程内；生产化前切边车。设计时 `runtime/` 模块要留一个 `SiriusTransport` 抽象接口，
两种实现。

---

## 4. 详细设计

### 4.1 模块划分

```
be/src/exec/gpu_offload/
├── eligibility/
│   ├── plan_gate.{h,cpp}         # TPlanNode 白名单 + 子树最大化算法
│   ├── expr_gate.{h,cpp}         # TExprNode 白名单 + 函数白名单
│   ├── type_gate.{h,cpp}         # TPrimitiveType 白名单（含语义等价性拒绝表）
│   └── capability.{h,cpp}        # 与 libsirius 的能力协商（见 §6.3）
├── translator/
│   ├── plan_translator.{h,cpp}   # TPlan(扁平先序) → substrait::Plan
│   ├── expr_translator.{h,cpp}   # TExpr(扁平先序) → substrait::Expression
│   ├── type_mapper.{h,cpp}       # TTypeDesc → substrait::Type / DuckDB 类型名
│   ├── descriptor_table.{h,cpp}  # TDescriptorTable → 全局 slot 索引解析
│   └── dialect.{h,cpp}           # ★ duckdb-substrait 方言的所有特例集中于此
├── bridge/
│   ├── block_to_arrow.{h,cpp}    # Block → ArrowArray（零拷贝为主）
│   ├── arrow_to_block.{h,cpp}    # ArrowArray → Block
│   └── arrow_c_abi.h             # Arrow C Data Interface 的 struct 定义（内联，不依赖 libarrow）
├── operator/
│   ├── sirius_offload_source_operator.{h,cpp}
│   └── sirius_offload_sink_operator.{h,cpp}
└── runtime/
    ├── sirius_transport.h         # 抽象：进程内 / 边车
    ├── inproc_transport.{h,cpp}   # dlopen libsirius.so
    ├── gpu_admission.{h,cpp}      # 全局槽位准入（Sirius 串行约束的护栏）
    └── fragment_dumper.{h,cpp}    # 调试：dump TPipelineFragmentParams
```

**CMake 开关**：`-DWITH_GPU_OFFLOAD=ON/OFF`，OFF 时整个目录不参与编译，BE 二进制无任何变化。
即使 ON，libsirius 也是 `dlopen` 的 —— 机器上没有这个 so，BE 正常启动，GPU 功能自动禁用。

### 4.2 控制面：生命周期与线程模型

Doris pipeline 是多任务并发的 push/pull 混合模型；Sirius 的 `Fragment::run()` 是阻塞的。桥接：

```
                       ┌── SiriusOffloadSinkOperator (每个输入边界一个) ──┐
  OlapScanOperator ────►  sink(Block, eos)                              │
                       │    ├─ block_to_arrow(Block) → ArrowArray       │
                       │    ├─ 背压等待（见下）                          │
                       │    ├─ Fragment::push(stream_k, batch)          │
                       │    └─ eos → Fragment::close_input(k, sender)   │
  ExchangeSourceOp ────►  （同上，stream_k+1）                           │
                       └────────────────────────────────────────────────┘
                                          │
                       ┌── SiriusOffloadSourceOperator ─────────────────┐
                       │  prepare():  起后台线程执行 Fragment::run()     │
                       │  get_block_impl():                             │
                       │      从 ArrowArrayStream 取下一个 batch         │
                       │      arrow_to_block() → 填 Doris Block          │
                       │      流结束 → *eos = true                       │
                       │  close():    join 后台线程，释放 Fragment       │
                       └────────────────────────────────────────────────┘
```

**几个必须处理好的点：**

**(a) `push()` 的线程安全性** —— Sirius 文档的不变式 S1/S2 明确 `push()` 可从任意线程调用，
且 batch 先入队再触发唤醒。所以 Doris 的多个 scanner 线程可以并发喂。✅

**(b) 背压** —— Sirius input stream 是**无界队列**。Doris 的 scanner 比 GPU 快是常态，不管
就会 OOM。**MVP 必须在 Doris 侧自建限流**：
```cpp
// SiriusOffloadSinkOperator
if (_inflight_bytes.load() > _max_inflight_bytes) {   // 默认 2GB，config 可调
    return Status::WaitForDependency(...);            // 走 Doris 原生的 Dependency 阻塞机制
}
```
用 Doris 自己的 `Dependency` 机制阻塞而不是 sleep，这样能正确参与 pipeline 调度和 cancel。
同时向 Sirius 提有界 channel 的需求（§8）。

**(c) 并发准入** —— Sirius 一个 Context 同时只能跑一个 query。BE 是多租户的。
```cpp
// gpu_admission: 进程级信号量，容量 = GPU 数（MVP 恒为 1）
auto slot = GpuAdmission::instance().try_acquire(query_id, timeout);
if (!slot) { /* 退回 CPU（prepare 期回退，见 §4.5）*/ }
```
超时时长很短（默认 0，即抢不到立刻退 CPU），避免排队放大延迟。

**(d) cancel** —— Doris 的 cancel 要能中断 GPU 执行。Sirius FFI 目前**没有 cancel 接口**
（这是 §8 的一个诉求）。MVP 的兜底：`close_input()` 所有输入流让 fragment 自然收敛，
后台线程 join 有超时，超时则标记 GPU runtime 不可用并拒绝后续查询（避免僵尸线程累积）。
这个兜底很粗糙，但比不做好；真正的解法在 Sirius 侧。

### 4.3 数据面：Block ↔ Arrow 零拷贝

**不要用 Doris 现有的 `write_column_to_arrow(ArrayBuilder*)` 路径** —— 那是逐值构建，
对 GB 级数据完全不可接受。新写一个基于 Arrow C Data Interface 的导出。

| Doris 列 | 导出方式 | 拷贝量 |
|---|---|---|
| `ColumnVector<T>` (int8~64, float, double) | 直接给 `PODArray` 的 `data()` 指针 | **零** |
| `ColumnDecimal<Decimal32/64/128>` | 同上，scale 走 Arrow `decimal128(p,s)` | **零** |
| `ColumnStr<UInt32>` — chars | 直接给 `chars.data()` | **零** |
| `ColumnStr<UInt32>` — offsets | **`&offsets[-1]`，长度 n+1** ★ | **零** |
| `ColumnStr<UInt64>` | 同上，映射 Arrow `large_utf8` | **零** |
| `ColumnNullable` 的 null map | byte-per-row → bitmap，需打包 | O(n/8) |

★ **这是勘察出来的一个漂亮结果**：Doris 的 `offsets` 是「第 i 个元素的**末尾**偏移」，长度 n；
Arrow/cuDF 要「起始偏移」，长度 n+1。看起来要拷贝 —— 但 `PaddedPODArray` 在
`be/src/core/pod_array.h:167` 显式 `memset(c_start - ELEMENT_SIZE, 0, ELEMENT_SIZE)`，
**保证 `offsets[-1] == 0` 且可读**。所以 `&offsets[-1]` 就是一个合法的、长度 n+1 的、
语义完全正确的 Arrow offset buffer。**字符串列可以整列零拷贝导出。**

> ⚠️ 一个必须加的守卫：Arrow `utf8` 的 offset 是 **有符号 int32**，Doris `ColumnStr<UInt32>`
> 的上限是 `MAX_STRING_SIZE = 4294967295`。当 `offsets.back() > INT32_MAX` 时必须降级为
> `large_utf8`（拷贝成 int64 offsets）或拒绝该 batch。

**生命周期**：Arrow C Data Interface 的 `release` callback 里持有一个 Doris `Block` 的
`shared_ptr`，保证 GPU 侧读完之前 Block 不被回收。这是零拷贝方案的正确性关键。

**null map 打包**：唯一必须的转换。`ColumnUInt8` (0/1 per row) → Arrow validity bitmap
(1 bit per row，且语义相反：Doris 1=null，Arrow 1=valid)。一个 SIMD 化的 `bytemap_to_bitmap`，
放在 `bridge/` 里，独立单测。

**反向（Arrow → Block）**：Sirius 产出的 Arrow batch 是 GPU 侧下来的，buffer 布局不受 Doris
控制，所以回程**必然有一次拷贝**。可接受：结果集通常远小于输入。

### 4.4 Eligibility Gate

**这是整个设计里最重要的资产，也是正确性的唯一防线。** 因为执行期不回退（§4.5），
判定必须**保守且完备**。

三层门，全部 fail-closed（任何看不懂的东西一律拒绝，绝不猜）：

#### (a) 算子门 —— TPlanNodeType 白名单

| 阶段 | 允许 |
|---|---|
| MVP-1 | `AGGREGATION_NODE`（仅非 merge 阶段）、`SELECT_NODE` |
| MVP-2 | `+ HASH_JOIN_NODE`（inner/left outer/left semi/left anti）、`SORT_NODE`（带 limit 的 top-n）、`BUCKETED_AGGREGATION_NODE` 的 merge 阶段 |
| MVP-3 | `+ FILE_SCAN_NODE`（叶子下沉，见 §3.3） |

**永久拒绝**（Sirius 不支持）：`ANALYTIC_EVAL_NODE`（窗口函数）、`UNION_NODE` /
`INTERSECT_NODE` / `EXCEPT_NODE`、`REPEAT_NODE`、`TABLE_FUNCTION_NODE`、`REC_CTE_NODE`、
`ASSERT_NUM_ROWS_NODE`、`PARTITION_SORT_NODE`、`MATERIALIZATION_NODE`。

#### (b) 表达式门 —— TExprNodeType + 函数白名单

允许：`SLOT_REF`、各 `*_LITERAL`（除 `LARGE_INT_LITERAL` / `JSON_LITERAL` /
`MAP_LITERAL` / `STRUCT_LITERAL` / `IPV4_LITERAL` / `IPV6_LITERAL`）、`BINARY_PRED`、
`COMPOUND_PRED`、`CAST_EXPR`、`IS_NULL_PRED`、`ARITHMETIC_EXPR`、`IN_PRED`、`CASE_EXPR`、
`LIKE_PRED`、`FUNCTION_CALL`（仅白名单函数）。

**永久拒绝**：`MATCH_PRED`（倒排索引）、`BLOOM_PRED` / `BITMAP_PRED` /
`NULL_AWARE_*`（runtime filter 内部）、`LAMBDA_*`、`SCHEMA_CHANGE_EXPR`、
`TUPLE_IS_NULL_PRED`、`INFO_FUNC`。

函数白名单初版（对齐 Sirius 的 29 个 `function_id`）：
`+ - * / %`、`substring`/`substr`、`like`、`year`/`month`/`day`/`hour`/`minute`/`second`、
`date_trunc`、`length`、`abs`? ❌（Sirius 没有）。

> **必须显式拒绝 `concat`**：Doris 的 `concat` 遇 NULL 返回 NULL，DuckDB 的 `concat` 忽略
> NULL 参数。Sirius 的 StarRocks 翻译器就是因为这个语义差异**故意不映射** concat
> （`experimental/starrocks/crates/starrocks-plan-translator/src/expr_translator.rs:552`）。
> Doris 侧同理。
>
> **`like` 必须要求常量模式且不含转义**：Sirius 的 GPU 求值器不处理转义字符，而 Doris/
> StarRocks 默认反斜杠是转义符。同上出处。

#### (c) 类型门 —— TPrimitiveType 白名单

允许：`BOOLEAN`、`TINYINT`、`SMALLINT`、`INT`、`BIGINT`、`FLOAT`、`DOUBLE`、
`DATEV2`、`DATETIMEV2`、`DECIMAL32`、`DECIMAL64`、`DECIMAL128I`、`VARCHAR`、`CHAR`、`STRING`。

**必须拒绝，理由如下：**

| 类型 | 理由 |
|---|---|
| **`LARGEINT`** | 🔴 Sirius 把 HUGEINT 映射成 INT64 且**静默截断**（`cudf_utils.hpp:169` 自带 FIXME）。这是无声的错误结果，绝对不能放行 |
| `DECIMAL256` | Sirius 不支持 |
| DECIMAL 且 `precision <= 4` | Sirius 明确抛错（DuckDB 用 INT16 存，无 cuDF 对应） |
| `HLL` / `BITMAP` / `QUANTILE_STATE` / `AGG_STATE` | Doris 特有的聚合中间态，GPU 侧无实现 |
| `JSONB` / `VARIANT` | Sirius 只当字符串处理，语义不等价 |
| `IPV4` / `IPV6` / `VARBINARY` / `TIMESTAMPTZ` | 无映射 |
| `ARRAY` / `MAP` / `STRUCT` | Sirius 只允许透传，不允许参与运算。MVP 阶段直接整列拒绝更安全 |
| `DATE` / `DATETIME`（v1） | 老类型，语义与 DATEV2/DATETIMEV2 不同，避免踩坑 |
| `DECIMALV2` | 同上 |

#### (d) 子树最大化算法

```
maximal_offloadable_subtree(nodes, root_idx):
    对每个节点自底向上：
        node.offloadable = plan_gate(node)
                        && all(expr_gate(e) for e in node 的所有表达式)
                        && all(type_gate(t) for t in node 输出的所有 slot 类型)
                        && all(child.offloadable or child 可作为 stream 边界)
    返回最大的 offloadable 连续子树；子树规模 < 阈值则不卸载（不值当）
```

「可作为 stream 边界」的节点：任意 scan 节点、`EXCHANGE_NODE`。它们本身不需要可翻译，
只需要输出类型全部通过 type_gate。

**卸载收益阈值**：子树至少要包含一个 join 或 agg，否则纯 filter/project 卸载只是白白付
H2D 成本。这个阈值应该是 config 可调的（`gpu_offload_min_subtree_ops`）。

### 4.5 回退策略：三级，且执行期不回退

| 级别 | 时机 | 触发条件 | 代价 |
|---|---|---|---|
| **L1 计划期** | `_build_and_prepare_full_pipeline` 之前 | eligibility 判定失败 | **零**。GPU 算子根本没建 |
| **L2 准备期** | `prepare()` 中 | GPU 不可用 / 抢不到槽位 / libsirius 加载失败 / Substrait 翻译失败 | 小。丢弃已建的 GPU pipeline，重建原生 pipeline |
| **L3 执行期** | — | — | **不回退，查询失败** |

**为什么执行期不回退？** 一旦开始喂数据：scanner 已经消费了 split、runtime filter 已经生效、
上游 exchange 的数据已经被拉走。Doris 是分布式的，没法像 DuckDB 那样重放整个查询。

> DuckDB 那边能执行期静默回退（`physical_sirius_execution.cpp:256` catch 后 fallback），
> 是因为它单机、单连接、可以重新 plan + 重新执行。Doris 学不了这一条。

**所以：** L1 必须覆盖 99% 的情况。这反过来要求 eligibility gate 完备 —— 每一个
「运行时才可能发现的问题」都必须在 L1 变成一个静态判定条件。这是本设计对 gate 严苛的根本原因。

L2 需要 Doris 支持「pipeline 重建一次」。当前 `_build_and_prepare_full_pipeline` 是一次性的，
需要小改造（见 §7.1）。

### 4.6 错误与可观测性

- **profile**：`SiriusOffloadSourceOperator` 的 profile 里加：翻译耗时、H2D 字节数/耗时、
  GPU 执行耗时、D2H 字节数/耗时、回退原因（枚举）、槽位等待耗时。
- **回退原因必须可查**。`explain` 里增加一节 `GPU Offload: NOT APPLIED (reason: unsupported
  expr FUNCTION_CALL "upper" at node 3)`。开发期没有这个，调优基本没法做。
- **审计**：`enable_gpu_execution=true` 但实际未卸载的查询要计数上报，用于评估覆盖率。

---

## 5. MVP 分期

### MVP-0 — 离线可行性验证（2–3 周，零侵入）

**目标**：不改 Doris 一行业务代码，验证翻译器路线可行，并产出 100% 可复用的翻译器代码。

1. BE 加一个 config：`dump_fragment_params_dir`，把收到的 `TPipelineFragmentParams`
   序列化成 thrift JSON 落盘。（这个能力本身对任何外部执行器开发都是刚需 —— 见 §7.7）
2. 写一个独立的命令行工具 `doris_plan_to_substrait`：吃 dump 文件，输出 Substrait。
3. 用 Sirius 的 `Context::execute_substrait` 直接跑，对比 Doris 的结果。

**验收**：TPC-H Q1 / Q6 的单表聚合 fragment 能翻译并在 GPU 上跑出正确结果。

**为什么值得做**：翻译器是整个项目里最不确定的部分（duckdb-substrait 方言的坑有多深？
Doris 的 descriptor table / slot 索引怎么映射？），先用最低成本把它验穿。而且这一步产出的
`translator/` 和 `eligibility/` 代码是最终方案的一部分，不是丢弃的原型。

### MVP-1 — 端到端最小闭环

**卸载形状**：`AGGREGATION_NODE`（单阶段）over `SELECT_NODE`? over `<任意 scan | EXCHANGE>`

- 输入：Doris 原生算子 → Block → Arrow → `push()`
- 输出：Arrow → Block → Doris 原生 sink
- gate：`set enable_gpu_execution = true`（默认 false）
- 类型/表达式/函数：§4.4 的 MVP-1 白名单

**验收**：
- TPC-H Q1、Q6 在 GPU 上跑通，结果与 CPU **逐行一致**
- 差分测试进 CI（§6.2）
- 不能卸载的查询 100% 正确回退，无性能回退

**明确不追求性能。** 这一期的 benchmark 大概率是持平甚至变慢（H2D 成本）。要提前说清楚。

### MVP-2 — 覆盖率与第一份性能数据

- `+ HASH_JOIN_NODE`（inner / left outer / left semi / left anti）
- `+ SORT_NODE`（top-n）
- `+` 两阶段聚合的 merge 阶段
- `+` 背压与准入控制的完整实现

**验收**：TPC-H 22 条全部能跑（能卸载的卸载，不能的回退），结果全部正确；给出 SF100 的
逐查询 GPU/CPU 对比表，**包含变慢的查询**。

### MVP-3 — 消除 H2D 瓶颈

`FILE_SCAN_NODE` 叶子下沉：翻译时不再生成 `sirius_stream_k`，而是从
`TPipelineFragmentParams.file_scan_params` + `TFileRangeDesc` 提取 parquet 文件路径，
生成 Substrait `local_files` read —— 复用 Sirius 已有的 `parquet_gpu_ingestible`。
（StarRocks 那边的 `scan_paths.rs` 是现成的参考实现，包括它的一整套 fail-closed 校验：
拒绝分片、拒绝远程 scheme、拒绝路径派生列、拒绝列变换。）

**范围**：Hive / Iceberg / TVF 的 parquet 外表。

**验收**：这是第一次有资格拿出「x 倍加速」这种数字的阶段。

### 长期 — 内表 GPU 直读

给 Sirius 实现一个 `doris_segment_gpu_ingestible`：GPU 解码 Doris segment v2
（bitshuffle / RLE / FOR / dict 编码、page 索引、zone map、delete bitmap、MOW merge-on-read）。

**这是让 Doris 内表真正变快的唯一途径，也是工作量最大的一块**（数人年量级）。
不应进入 MVP 讨论范围，但架构上要保证它是「加一个 ingestible」而不是「重构集成层」——
§3.3 的边界统一化设计已经保证了这一点。

---

## 6. 可维护性设计

### 6.1 契约管理

| 契约 | 版本化方式 | 破坏时的表现 |
|---|---|---|
| Substrait plan | Substrait 版本号 + 自定义 `dialect_version` | 翻译失败 → L1 回退 |
| Arrow C Data Interface | ABI 稳定，无版本问题 | — |
| `sirius_ffi.hpp` | libsirius 语义化版本 + 启动期握手 | dlopen 后符号检查失败 → 禁用 GPU |

**`dialect.{h,cpp}` 的作用**：把「duckdb-substrait 方言」的所有特例集中在一个文件。
函数名映射、类型编码怪癖、`local_files` 的用法、聚合的 phase 表达 —— 全部在这里。
将来如果 Sirius 换了 Substrait 消费端（或者支持了标准方言），只改这一个文件。

> 必须写进文档的一句话：**「用了 Substrait 就能对接任意引擎」是幻觉。** Sirius 消费的是
> `duckdb::SubstraitToDuckDB`，函数名、类型编码、扩展 URN 都是 DuckDB 特定的。承认这一点、
> 并把它隔离在一个文件里，比假装它是标准要健康得多。

### 6.2 测试策略

三层，**前两层不需要 GPU**：

**(1) 翻译器单测（无 GPU，跑在普通 CI）**
```
测试用例 = 手工构造的 TPlanNode/TExpr → 期望的 substrait::Plan
```
对标 `experimental/starrocks` 的 96 个单测。这一层保证翻译逻辑正确，且**每个 fail-closed
拒绝路径都有一个负向用例**（拒绝 LARGEINT、拒绝 concat、拒绝带转义的 like……）。

**(2) 契约 golden 测试（无 GPU）**
```
regression-test 里跑一批 SQL，dump TPipelineFragmentParams
→ 翻译成 Substrait → 与 golden 文件比对
```
这一层的价值：**Doris 改了 plan 生成逻辑时立刻报警**。Doris 的 Nereids 优化器演进很快，
plan 形状变化会静默破坏翻译器 —— golden 测试是唯一能抓到这个的手段。

**(3) 差分测试（需要 GPU，跑在 GPU CI）**
```
regression-test/suites/gpu_offload_p0/
  同一批 SQL，分别 set enable_gpu_execution = true / false
  逐行比对结果（含 NULL、精度、排序稳定性）
```
**这是正确性的最终防线，必须进 merge queue。** 语义差异（decimal 精度推导、除零、
collation、日期边界、cast 溢出）只有差分测试能抓到。

### 6.3 版本与能力协商 —— 避免白名单双写漂移

**问题**：eligibility 白名单写在 Doris 侧，Sirius 加了新算子/新函数，Doris 不知道；
Sirius 删了某个能力，Doris 还在用。两边各写一份必然漂移。

**方案**：libsirius 暴露一个能力描述接口（这是对 Sirius 的一个诉求，见 §8.5）：

```cpp
// 期望的 sirius_ffi.hpp 新增
struct SIRIUS_FFI_EXPORT Capabilities {
  std::string          dialect_version;
  std::vector<std::string> scalar_functions;   // "add", "substring", "like", ...
  std::vector<std::string> aggregate_functions;
  std::vector<std::string> relations;          // "AggregateRel", "JoinRel", ...
  std::vector<std::string> types;              // "DECIMAL128", "DATE", ...
};
SIRIUS_FFI_EXPORT std::unique_ptr<Capabilities> capabilities();
```

BE 启动时调用一次，用返回值**收窄**自己的静态白名单（取交集）。
静态白名单保留 —— 它承载的是「Doris 侧的语义安全判断」（如 concat/like 的语义差异），
这部分 Sirius 不知道，不能靠协商。协商只用于**摘掉 Sirius 已经不支持的东西**。

在 Sirius 提供这个接口之前，MVP 用「libsirius 版本号 → 硬编码能力表」的映射兜底。

---

## 7. 对 Doris 的改进建议

以下每一条都是**独立可合入、独立有价值**的改动，不依赖 GPU 项目落地。

### 7.1 `PipelineFragmentContext` 需要一个 plan 重写扩展点 🔴

**现状**：`_build_pipelines`（`pipeline_fragment_context.cpp:703`）直接从
`_params.fragment.plan.nodes` 递归建树，写死。任何「在建 pipeline 前改写 plan」的需求都
只能去改这个核心函数。

**建议**：
```cpp
class FragmentPlanRewriter {
public:
    virtual ~FragmentPlanRewriter() = default;
    virtual std::string name() const = 0;
    // 返回是否改写了 plan；改写后的 plan 写回 params
    virtual Status rewrite(TPipelineFragmentParams& params, RuntimeState* state, bool* rewritten) = 0;
};
// 注册式，按优先级顺序执行
FragmentPlanRewriterRegistry::instance().register_rewriter(...);
```

**受益方不止 GPU**：查询缓存改写、算子融合、外部执行器（Velox / DataFusion / GPU）、
调试用的 plan 注入 —— 都需要这个。

### 7.2 算子工厂需要可注册 🟡

**现状**：`_create_operator` 是一个 ~550 行的 `switch (tnode.node_type)`
（`pipeline_fragment_context.cpp:1502`）。新增任何节点类型都要改这个 switch。

**建议**：抽出 `OperatorFactoryRegistry`，按 `TPlanNodeType` 注册 creator，
并预留一个 `TPlanNodeType::EXTERNAL_EXECUTOR_NODE = 39` 供外部执行器使用。

**受益**：任何「把一段 plan 交给外部引擎执行」的方案（不只是 GPU）都不再需要改核心 switch。

### 7.3 `Block` 需要官方的零拷贝 Arrow C Data Interface 导出 🔴

**现状**：只有 `DataTypeSerDe::write_column_to_arrow(IColumn&, ..., arrow::ArrayBuilder*, ...)`
（`data_type_serde.h:500`），逐值构建，GB 级数据下不可用。

**建议**：
```cpp
// be/src/core/block/block.h
Status Block::export_to_arrow_c(ArrowArray* out_array, ArrowSchema* out_schema,
                                std::shared_ptr<Block> keepalive);
```
数值列 / decimal 列 / 字符串列全部共享 buffer；`release` callback 持有 Block 引用；
只有 null map 需要 bytemap→bitmap 打包。

**受益方远不止 GPU**：Arrow Flight SQL 的吞吐（`varrow_flight_result_writer.cpp` 现在走的
就是慢路径）、Python UDF/UDAF、`adbc_reader` / `remote_doris_reader`（`be/src/format_v2/table/`）、
将来任何需要 Arrow 交换的场景。**这条单独提一个 PR 就有明确收益，建议优先做。**

> 实现提示（已验证）：`ColumnStr<T>` 的 offsets 可以零拷贝导出 —— `PaddedPODArray` 在
> `pod_array.h:167` 保证 `offsets[-1] == 0` 且可读，所以 `&offsets[-1]` 就是一个合法的、
> 长度 n+1 的 Arrow offset buffer。注意加 `offsets.back() > INT32_MAX` 时降级 `large_utf8`
> 的守卫。

### 7.4 `TBackendInfo` 需要可扩展的能力上报 🟡

**现状**：`TBackendInfo`（`HeartbeatService.thrift:55`）只有端口、版本、内存。
FE 完全不知道某个 BE 有没有 GPU / 有多少显存 / 支持什么扩展。
`Backend.tagMap` 是运维手工设的，不是 BE 自报的。

**建议**：
```thrift
struct TBackendInfo {
    ...
    11: optional map<string, string> capabilities  // "gpu.vendor"="nvidia", "gpu.memory_bytes"="..."
}
```

**受益**：异构集群调度（GPU 节点、大内存节点、本地 NVMe 节点）、灰度发布时按 BE 能力路由、
运维可观测性。这是一个**通用的基础能力缺口**，GPU 只是第一个用例。

### 7.5 fragment 级的执行器提示 🟢

**建议**：`TPipelineFragmentParams` 加
```thrift
47: optional TExecutorHint executor_hint  // { PREFER_GPU, FORCE_CPU, AUTO }
```
让 FE 的代价模型参与决策（FE 知道基数估计、知道数据量、知道集群拓扑），而不是让 BE 盲判。
MVP 可以不用，但接口先留出来，避免以后改 thrift 兼容性麻烦。

### 7.6 `ColumnNullable` 的 null 表示（长期议题）🟢

byte-per-row 的 null map 在每一次跨 Arrow/cuDF 边界时都要打包/展开。长期可以评估内部改用
bitmap，或至少提供一个带缓存的 bitmap 视图。**改动很大，这里只作为议题登记**，不建议为
GPU 项目推动。

### 7.7 BE 需要 fragment 参数的 dump 能力 🟢

**建议**：BE config `dump_fragment_params_dir`，把收到的 `TPipelineFragmentParams` 落盘
（thrift JSON）。

**受益**：任何外部执行器的开发（MVP-0 直接依赖它）、线上问题复现、plan 回归测试。
StarRocks 那边的集成就专门加了 `SIRIUS_CN_DUMP_FRAGMENTS`
（`experimental/starrocks/src/compute_node_service.rs:261`）—— 说明这是刚需。

---

## 8. 对 Sirius 的改进诉求

> 2026-09-01 更新：核实嵌入能力后，优先级重排。8.0 的三条是**阻断性**的 —— 没有它们，
> 进程内方案根本跑不通；原有的 8.1–8.6 相应下调。详见 `reference/sirius-ffi.md`。
>
> 2026-09-01 P0 调研完成：三条缺口的实际工作量、依赖冲突的真实形态（是 libstdc++，不是 protobuf/abseil）、
> libsirius 必须满足的四条链接约束、以及 A/B 结论（ADR-010）见 `embeddability-study.md`；
> 8.0(d) 的「典型爆炸场景」判断已被实测修正。

### 8.0 🔴 让 Sirius 成为一个可嵌入的运行时库

这三条不该包装成「为 Doris 做」—— 它们是让 Sirius 能被**任何**宿主嵌入的通用能力，
对 Rust / Go / JNI / 任意 stdlib 的 C++ 集成方一视同仁。

**(a) 外部 Arrow 输入口 —— 最硬的一条**

FFI 的输入输出不对称：`result_to_arrow()` 能把数据拿出来，但**没有任何方法能把外部产生的
Arrow batch 喂进 input stream**。唯一的输入手段是 `relay_from(Fragment& source, ...)`，
只能从同进程的另一个 Fragment 搬批次。内部的 `stream_session::push` 收
`cucascade::data_batch` 原生类型，且未暴露。

**本设计 §3.3 的边界统一化完全依赖这个能力**（Doris 的 scan 把 Block 转 Arrow 推进
`sirius_stream_k`）。期望：

```cpp
void Fragment::push_arrow(uint64_t stream_id, uint32_t sender_id,
                          uintptr_t arrow_array_addr, uintptr_t arrow_schema_addr);
```

**(b) C ABI 层**

`sirius_ffi.hpp` 里没有任何 `extern "C"`；跨界传 `std::unique_ptr`/`std::string`/`std::vector`
且会抛异常。现有嵌入方 `sirius-sys` 用 cxx.rs，靠**与 Sirius 同构建树共编**回避了 ABI 问题；
独立构建的宿主没法照做。注意数据面已经是纯 C ABI（Arrow C Data Interface），
只有控制面那十来个方法需要改造。

**(c) 可分发的 libsirius 产物**

`sirius_ffi.hpp` 的注释自己写着「今天编在 DuckDB 扩展里，直到有独立的 libsirius」。
CMake 里没有独立 target、没有 install target、没有版本化发布物。

**(d) 附带：依赖闭包的符号隔离**

进程内加载会把 libsirius 的整个依赖闭包拉进宿主地址空间。与 Doris BE 的已知重叠：
protobuf（Doris 固定 21.11 vs conda 版本）、abseil、arrow（Doris 24.0.0）、openssl、curl、
spdlog、sqlite。同进程两份 protobuf + 两份 abseil 是典型爆炸场景。
需要一个明确的隔离方案或指导（全静态 + `-fvisibility=hidden` + version script 等）。



按对 Doris 集成的阻塞程度排序：

### 8.1 🟡 引擎并发

> 原「头号阻塞」；8.0 落地前它排在后面，但仍是生产化的前提。

`Context` 进程内串行（一次一个 query）对单用户的 DuckDB 是可接受的，对多租户的 Doris BE
是致命的。需要：多 Context 共存，或 query 级并发调度。**没有这个，GPU 卸载在生产集群上
只能当单并发的实验特性。**

### 8.2 🔴 HUGEINT 静默截断必须改成报错

`src/include/cudf/cudf_utils.hpp:169` 的 `FIXME: Values outside INT64 range are silently
corrupted`。任何集成方都可能踩到无声的错误结果。至少要能配置成「抛错而不是截断」。
（Doris 侧我们会在 gate 里拒绝 LARGEINT，但这不该是每个集成方各自防御的事。）

### 8.3 🟡 input stream 需要背压

无界队列意味着上游快于 GPU 时无限占内存。需要有界 channel + 阻塞/唤醒语义。
（Doris 侧会自建限流兜底，但语义上应该在 Sirius。）

### 8.4 🟡 异步执行与取消

`Fragment::run()` 阻塞、且「build 与 run 之间同时只能有一个 fragment」的状态机，
对 Doris 的 pipeline 调度不友好。希望有：
- `start()` / `poll()` 的非阻塞形态
- `cancel()` —— Doris 的查询取消必须能中断 GPU 执行，目前 FFI 无此接口

### 8.5 🟡 能力描述接口

见 §6.3。让集成方能在运行时查询「你支持哪些算子/函数/类型」，避免白名单双写漂移。

### 8.6 🟢 Substrait 方言文档化

明确列出 `duckdb::SubstraitToDuckDB` 消费端接受的关系类型、函数扩展 URN、类型编码、
以及已知的与标准 Substrait 的偏离。目前集成方只能靠读 `experimental/starrocks` 的翻译器
反推。

---

## 9. 风险登记

| 风险 | 等级 | 缓解 |
|---|---|---|
| **语义等价性**：decimal 精度推导、除零、collation、日期边界、cast 溢出在 Doris/DuckDB 间不一致 | 🔴 高 | 差分测试进 CI（§6.2 第 3 层）；gate 保守；每发现一处差异就加一条负向用例 |
| **执行期不可回退**，gate 漏判即查询失败 | 🔴 高 | gate fail-closed；每个 gate 分支有单测；灰度按 session var 逐步放开 |
| **libsirius 崩溃带走 BE** | 🔴 高 | MVP 默认关闭 + 只在测试集群开；生产化前切边车进程（§3.4，纯传输层改动） |
| **Sirius 引擎串行**导致高并发下无收益 | 🟡 中 | 准入控制避免排队放大延迟；推动 §8.1 |
| **MVP-1/2 性能不达预期**（H2D 瓶颈） | 🟡 中 | **提前对齐预期**；把 MVP-3 的 GPU 直读作为性能里程碑而非 MVP-1 |
| **Doris plan 形状演进**破坏翻译器 | 🟡 中 | golden 契约测试（§6.2 第 2 层） |
| **Sirius 是 DuckDB 扩展**，libsirius 尚未独立 | 🟡 中 | `sirius_ffi.hpp` 注释已说明「今天编在扩展里，将来会有独立 libsirius」。推动其独立化 |
| 双方仓库/发版节奏不同步 | 🟢 低 | dlopen + 版本握手；能力协商 |

---

## 10. 附录：Doris ↔ Sirius 语义差异清单（持续维护）

这份清单是 gate 的直接依据，发现一条加一条。

| 主题 | Doris | DuckDB / Sirius | 处置 |
|---|---|---|---|
| `concat` 遇 NULL | 返回 NULL | 忽略 NULL 参数 | ❌ 拒绝 |
| `LIKE` 转义 | 反斜杠为默认转义符 | GPU 求值器不处理转义 | ❌ 除非模式是常量且不含 `\` |
| `substring` 参数 | 支持负数起点、两参形式 | 仅 `(col, 常量正 start, 常量正 len)` | ❌ 除非满足约束 |
| INT128 (`LARGEINT`) | 精确 128 位 | **静默截断为 64 位** | ❌ 拒绝 |
| DECIMAL precision ≤ 4 | 正常 | Sirius 抛错 | ❌ 拒绝 |
| DECIMAL256 | 支持 | 不支持 | ❌ 拒绝 |
| 除零 | 返回 NULL（默认） | 待核实 | ⚠️ 需差分测试确认 |
| 字符串比较 | 二进制序 / collation | 二进制序 | ⚠️ 需差分测试确认 |
| DECIMAL 运算结果精度推导 | Doris 规则 | DuckDB 规则 | ⚠️ **高风险，需专项差分测试** |
| `cast` 溢出 | 依 `enable_strict_cast` | Sirius 用 throwing 语义 | ⚠️ 需按 session var 分别验证 |
| 聚合 `avg` 的中间精度 | Doris 规则 | DuckDB 规则 | ⚠️ 需差分测试 |
| NULL 排序位置 | `NULLS FIRST/LAST` 显式 | 同 | ✅ 翻译时显式传递 |

---

## 附:关键代码位置索引

**Doris**
- pipeline 构建入口：`be/src/exec/pipeline/pipeline_fragment_context.cpp:703` / `:1502`
- fragment 参数定义：`gensrc/thrift/PaloInternalService.thrift:720`
- plan / expr 节点类型：`gensrc/thrift/PlanNodes.thrift:28` / `gensrc/thrift/Exprs.thrift:24`
- 类型枚举：`gensrc/thrift/Types.thrift:59`
- 列布局：`be/src/core/column/column_string.h:87`、`be/src/core/pod_array.h:167`
- 现有 Arrow 转换（慢路径）：`be/src/core/data_type_serde/data_type_serde.h:500`
- BE 心跳上报：`gensrc/thrift/HeartbeatService.thrift:55`

**Sirius**
- 集成契约：`src/include/sirius_ffi.hpp`
- Substrait 降级：`src/sirius_ffi.cpp:73`
- 流式 fragment 文档：`docs/super-sirius/streaming-fragments.md`、`streaming-sessions.md`
- 算子/表达式支持面：`docs/super-sirius/physical-plan-generation.md:18`
- 类型映射（含 HUGEINT 缺陷）：`src/include/cudf/cudf_utils.hpp:161`
- 函数/聚合白名单：`src/expression/function_id.cpp:34`、`src/expression/aggregate_id.cpp:34`
- StarRocks 参考实现：`experimental/starrocks/crates/starrocks-plan-translator/`
