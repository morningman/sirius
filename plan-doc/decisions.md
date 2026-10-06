# 决策记录

**只追加，不改写。** 要推翻某条决策，追加一条新的并写明「取代 ADR-00X」，保留原条目。
这样才能回答「当初为什么这么定」，避免同一个问题被反复推翻。

格式：决策 / 背景 / 理由 / 放弃了什么 / 代价。

---

## ADR-001 · 架构选型：BE 内 fragment 子树卸载

**日期** 2026-09-01 · **状态** 已定

**决策**：在 Doris BE 进程内，于 pipeline 构建之前把 fragment 中「最大可翻译连续子树」
替换成一个卸载算子，交给 Sirius 在 GPU 上执行。

**放弃 A（伪 BE 进程，StarRocks shim 模式）**：Doris `PBackendService` 有 60+ 个 RPC，
加上 AgentService、runtime filter merge、load stream，伪装成 BE 的表面积极大且随每个 Doris
版本漂移。更致命的是它**读不到 Doris 存储**，只能查外表 —— 而内表才是 Doris 的主力场景。

**放弃 C（算子级替换）**：每个算子边界都要 Block↔cuDF 往返，PCIe 反复，性能上不成立；
且 Doris 算子接口耦合极深（LocalState / SharedState / Dependency / spill / reserve_mem），
每个 GPU 算子都要重实现一整套，随 Doris 重构不断破裂。

**代价**：libsirius 崩溃会带走整个 BE 进程（见 ADR-006）；MVP 阶段扫描仍在 CPU，H2D 是瓶颈。

---

## ADR-002 · 契约：Substrait plan bytes + Arrow C Data Interface

**日期** 2026-09-01 · **状态** 已定

**决策**：两侧唯一的契约是「Substrait protobuf bytes 进、ArrowArrayStream 出」。
Doris 只包含 `sirius_ffi.hpp` 一个头文件，不引入 cuDF / RMM / DuckDB / Arrow C++ 任何头文件。
Sirius 仓库里不出现 `doris` 字样。

**理由**：
1. Sirius 的稳定 FFI 本来就吃 Substrait（`Fragment::build(substrait_plan)`）。不用它就得在
   Sirius 里开一个 Doris 专用入口 —— 两个项目立刻互相绑死。
2. **可序列化 = 可测试。** 翻译器能在没有 GPU 的机器上做完整单测。对本项目这不是好习惯而是
   硬性前提（开发机没有 GPU）。
3. 契约窄到这个程度，将来从进程内切边车进程只是传输层替换，translator / eligibility /
   operator 三个模块一行不用改。

**代价**：Sirius 消费的是 **duckdb-substrait 方言**而非纯 Substrait，所以「用了 Substrait
就能对接任意引擎」是幻觉。缓解：所有方言特例集中在 `translator/dialect.{h,cpp}` 一个文件。

---

## ADR-003 · 翻译器用 C++ 直接写在 Doris BE，不经 Rust

**日期** 2026-09-01 · **状态** 结论保留，**理由已被 ADR-008 纠正**

**决策**：`translator/` 与 `eligibility/` 直接用 C++ 写在 `wt-gpu:be/src/exec/gpu_offload/`。

**理由**：StarRocks 那边用 Rust 是因为它的 CN 本来就是 Rust 进程。Doris BE 是 C++，翻译器
最终必须以 C++ 形态跑在 BE 进程内 —— 先写 Rust 再重写一遍纯属浪费。

**MVP-0 的处理**：翻译器编译时只依赖 thrift 生成代码 + Substrait protobuf，
可以作为独立命令行工具先脱离 BE 主体运行，不影响它最终就地融入。

---

## ADR-004 · 卸载子树的叶子统一为 stream 输入

**日期** 2026-09-01 · **状态** 已定

**决策**：卸载子树的**所有**叶子 —— 不论原本是 `OLAP_SCAN_NODE`、`FILE_SCAN_NODE` 还是
`EXCHANGE_NODE` —— 一律翻译成读 `sirius_stream_<k>` 的 `ReadRel{NamedTable}`，
运行时由 Doris 原生算子把 Block 转 Arrow 推进去。

**理由**：这是整个设计的最大杠杆。
1. 翻译器完全不需要理解 Doris 存储层（tablet / rowset / segment / split / delete bitmap /
   MOW / file cache / S3 凭证 / Iceberg manifest 一行都不碰），MVP 工作量砍掉一大半。
2. 所有表类型 day-1 全支持，因为扫描还是 Doris 干的。
3. 将来 scan 下沉（MVP-3 把 `FILE_SCAN_NODE` 换成 `local_files`）只动叶子处理，其余不变。

**代价**：H2D 带宽。MVP-1/2 只在 compute/scan 比高的查询上赢，性能里程碑推迟到 MVP-3。
**这个代价必须提前对齐预期**，否则 MVP-1 的 benchmark 会被误读为方案失败。

---

## ADR-005 · 执行期不回退

**日期** 2026-09-01 · **状态** 已定

**决策**：三级回退 —— L1 计划期（eligibility 判定失败，零成本）、L2 准备期（GPU 不可用 /
抢不到槽位 / 翻译失败，重建原生 pipeline）、**L3 执行期不回退，查询直接失败**。

**理由**：一旦开始喂数据，scanner 已消费 split、runtime filter 已生效、上游 exchange 数据
已被拉走。Doris 是分布式的，没法像 DuckDB 那样重放整个查询（DuckDB 能静默 fallback 靠的是
单机可重新 plan）。

**推论（重要）**：L1 必须覆盖 99% 的情况。每一个「运行时才可能发现的问题」都必须在计划期
变成一个静态判定条件。**这是 eligibility gate 必须 fail-closed 且完备的根本原因**，
也是为什么每个拒绝分支都要有负向单测。

---

## ADR-006 · MVP 走进程内，生产化前切边车

**日期** 2026-09-01 · **状态** 🔄 **重新评估中** —— 见 ADR-009，待 P0 调研结论

**决策**：MVP 阶段 libsirius 以 `dlopen` 方式在 BE 进程内加载；`runtime/` 留一个
`SiriusTransport` 抽象接口，为将来的边车进程实现留位。

**理由**：进程内实现成本低、无传输开销，适合验证期。风险（CUDA/cuDF 崩溃带走 BE）由
「默认关闭 + 只在测试集群打开」控制。ADR-002 的窄契约保证了切换是纯传输层改动。

---

## ADR-007 · 代码落点在 wt-gpu，不在 sirius 建 experimental/doris

**日期** 2026-09-01 · **状态** 已定

**决策**：所有 Doris 侧代码（含 MVP-0 的独立翻译工具）落在
`wt-gpu:be/src/exec/gpu_offload/`，不在 Sirius 仓库建对称于 `experimental/starrocks` 的目录。

**理由**：翻译器最终必须跑在 Doris BE 进程内、读 Doris 的 thrift 结构。放 Sirius 会导致后面
搬家，而且违反 ADR-002 的「Sirius 仓库里不出现 doris 字样」。
`experimental/starrocks` 那种形态适合伪 CN 方案（ADR-001 已否决）。

**例外**：本文档空间放在 `sirius/plan-doc/`，因为它同时描述两侧。

---

---

## ADR-008 · 纠正 ADR-003 的理由：真正的轴是「独立进程 vs 进程内库」

**日期** 2026-09-01 · **状态** 已定 · **修订** ADR-003 的论证（结论不变）

**ADR-003 写错了什么**：原文称「StarRocks 那边用 Rust 是因为它的 CN 本来就是 Rust 进程」。
**这是错的。StarRocks 的 BE/CN 是 C++。**

**事实**：Sirius 根本没有碰 StarRocks 的 BE。`experimental/starrocks/src/main.rs` 是一个
**全新写的独立 Rust 进程** `sirius-starrocks-cn`，它通过 MySQL 协议执行
`ALTER SYSTEM ADD COMPUTE NODE` 把自己注册进一个**原版未改动**的 FE，然后接管
`exec_plan_fragment`。StarRocks submodule 里 BE 的 C++ 源码从未编译（pixi 只跑 `build.sh --fe`）。
既然是绿地新进程，语言就是自由选择 —— 选 Rust 是因为 Sirius 仓库本来就有 Rust workspace。

**所以真正决定语言的不是「宿主用什么语言」，而是「代码活在哪个进程里」**：

| | SR 方案 | Doris 方案 |
|---|---|---|
| Sirius 的身份 | 集群拓扑里的一个**节点**（伪 CN） | BE 进程内的一个**库** |
| 谁知道它存在 | FE（当 CN 调度） | 只有 BE，FE 无感知 |
| 接管粒度 | 整个 fragment（含 sink） | fragment 里的一个**子树** |
| 数据来源 | 自己读 parquet | Doris 的 scan 喂进来 |
| 结果去向 | 自编 MySQL 行回 FE | 转回 Block 交给下游 Doris 算子 |
| 语言约束 | 无（独立进程） | **必须 C++**（要 include Doris 的 `Block`、继承 `OperatorXBase`） |

**ADR-003 的结论仍然成立**，但正确的理由是：本方案的代码运行在 Doris BE 进程内、
要直接操作 Doris 的 C++ 类型，因此必须是 C++。与 StarRocks 用什么语言无关。

### 附：SR 那 9000 行 Rust 的构成（用于成本对照）

| 部分 | 行数 | 内容 |
|---|---|---|
| 协议外壳 | ~4600 | thrift servers、手写 BRPC/PRPC 帧、FE 自注册与心跳 |
| plan 翻译 | ~3400 | thrift → Substrait |
| 结果编码 | ~460 | Arrow → `TResultBatch` MySQL 行格式 + 缓冲 |
| 引擎桥接 | ~510 | 递 Substrait 给 libsirius，收 Arrow |
| **查询执行** | **0** | 全部由 Sirius 的 C++/CUDA 引擎完成（`engine.rs:102` 一行调用） |

它是**协议外壳（protocol shim），不是执行引擎**。BRPC `PInternalService` 只实现了 4 个方法，
thrift `BackendService` 24 个 handler 里 15 处直接返回 `NOT_IMPLEMENTED`。

**成本形状的差异**（不涉及能否读原生数据这一维）：

- SR 方案：**启动快**（隔离彻底 —— 不用读宿主一行 C++、不进宿主构建系统、不处理 ABI、
  不用做回退、不用过宿主社区 review、崩了只崩自己）；代价是协议外壳是**永久税**，
  随宿主协议表面积增长。
- Doris 方案：**启动慢**（下面 ADR-009 的三项 + 回退机制 + 在宿主执行框架里当守规矩的算子 +
  apache/doris 的 review 流程）；但这些是**一次性投入**，写完就稳定。

---

## ADR-009 · 嵌入形态（进程内 vs 边车）暂缓定案，先做 P0 可嵌入性调研

**日期** 2026-09-01 · **状态** 待 P0 调研 · **暂停** ADR-006 的结论

**背景**：核实 Sirius 的嵌入能力后发现三个缺口 + 一个高风险项（详见
`reference/sirius-ffi.md` 的「三个阻断性缺口」）：

1. 🔴 **FFI 没有外部 Arrow 输入口**。只有 `relay_from`（同进程 Fragment 间搬批次），
   没有 `push_arrow`。**ADR-004 的边界统一化今天做不到。**
2. 🔴 **没有 C ABI**。接口传 `std::unique_ptr`/`std::string`/`std::vector` 且抛异常；
   现有嵌入方（`sirius-sys`）靠同构建树共编回避，Doris 无法照做。
3. 🔴 **没有可分发的 libsirius 产物**（头文件注释自己承认）。
4. ⚠️ **依赖闭包冲突**：Doris BE 固定 protobuf 21.11 + 自带 abseil/arrow 24.0.0，
   Sirius 走 conda 的 libprotobuf/libabseil。同进程两份 protobuf + 两份 abseil 是典型爆炸场景。

**决策**：不在信息不足时硬定 A/B。先做 **P0 可嵌入性调研**（见 `tasklist.md`），
用工作量估算和符号冲突实测来决定，产出同时作为提交给 Sirius 社区的提案素材。

**不阻塞开工**：MVP-0 是纯离线的（Doris dump fragment → 独立工具翻译 → 在 GPU 机器上单独跑
Substrait），**完全不涉及链接**。A/B 的决策可以推迟到 MVP-1。

**给 Sirius 的诉求，按优先级重排**：
1. `Fragment::push_arrow(...)` —— 外部 Arrow 输入口（阻断性）
2. C ABI 层（`extern "C"` + 不透明句柄 + 错误码，std 类型与异常不跨界）
3. 独立可分发的 libsirius 产物 + 版本化
4. 依赖闭包的符号隔离方案（或指导）
5. 引擎并发、背压、`cancel()`、能力描述接口（原有诉求，优先级下调）

> 第 2、3 条不该包装成「为 Doris 做」—— 它们是「让 Sirius 成为可嵌入引擎」的通用能力，
> 对 Rust / Go / JNI / 任意 stdlib 的 C++ 集成方一视同仁。这么提对社区更有说服力。
> 同理，边车方案里的 worker 进程也**不该叫 `experimental/doris/`** —— 协议是
> 「Substrait 进、Arrow 出」，跟 Doris 毫无关系，它是通用的「libsirius as a service」。

## ADR-010 · 嵌入形态：MVP 进程内，附 libsirius 交付标准；生产硬化切边车

**日期** 2026-09-01 · **状态** 已定 · **取代** ADR-009 的「暂缓」，**恢复并收紧** ADR-006

**依据**：`embeddability-study.md`（P0 调研，含真实二进制实测）。

**决策**：
1. MVP-1/2 以 `dlopen` 方式在 BE 进程内加载 libsirius；`runtime/` 保留 `SiriusTransport` 抽象。
2. **前提是 libsirius 满足四条链接约束**（study §5.5）：依赖全静态 + `-fvisibility=hidden` +
   `--exclude-libs,ALL`；**`-static-libstdc++ -static-libgcc`**；version script 只导出 `sirius_*`；
   libgomp 静态/移除、cuvs 可选。不满足第 2 条的产物（含今天的 `sirius.duckdb_extension`）**不进 BE**。
3. Doris 侧通过 `dynamic_open()` 加载，永不 `dlclose`；Sirius 线程零回调进 Doris。
4. MVP-3（GPU 直读 parquet）前后切边车：worker 为通用的「Substrait 进、Arrow 出」服务，
   Doris 侧照 Python UDF 的 `PythonServerManager` + Arrow Flight 模式实现。

**理由**：
- 依赖冲突已定位到唯一的真实冲突面 libstdc++，且实验证明约束 2 能完全消除它；
  protobuf/abseil/arrow 的担忧不成立（study §5）。
- 三个缺口合计 Sirius 侧 ≈ 1.3k 行、不动内部实现，且与 Sirius 路线图（#1590）同向。
- 边车在 MVP-1/2 会把本已是瓶颈的传输放大 1.5–3×；到 MVP-3 它的数据面代价归零，那是切换的自然时点。

**放弃了什么**：`RTLD_DEEPBIND`（malloc 分裂 + 已知 bug）；`dlmopen`；conda 口味产物。

**代价**：崩溃隔离要等边车；Doris 侧要自建 in-flight 限流与槽位准入；部署要带 CUDA 运行库、
glibc ≥ 2.28、io_uring 的 seccomp 放行。

---

## ADR-011 · 轨 1：Doris 伪 BE 作为验证/benchmark 载体——定位、落点、版本、环境、数据入口、对外口径

**日期** 2026-09-18 · **状态** 已定 · **关系** 不推翻 ADR-001 / ADR-010（那是产品路径，轨 2）；对轨 1 **取代** ADR-007 的落点结论
（ADR-007 针对的是进程内路线）；ADR-009 附注里「worker 不该叫 `experimental/doris/`」针对的是通用边车，伪 BE 是 Doris 协议壳，这个名字成立。

**依据**：`pseudo-be-feasibility.md`（09-09）、`doris-pseudo-be-plan.md`（09-18）。用户 09-18 拍板 D-1～D-5。

**决策**：
1. **定位**：伪 BE 是轨 1 的验证 / benchmark 载体，**不是** Doris 的正式集成路径；正式路径仍是 ADR-010。两轨共享 TPC-H fragment 语料、
   `semantics-gaps.md`、类型/表达式白名单、差分脚本。两套翻译器（轨 1 Rust / 轨 2 C++）逻辑同构、语言不同，这项维护税**接受**。
2. **落点（D-1）**：个人 fork 分支 `experimental-doris`，目录 `experimental/doris/`（对齐 SR 结构、CODEOWNERS `sirius-integrations`、
   `experimental.yml` 的无 GPU CI 先例）。~~P1 结束、CI 绿后 re-open #137 提 draft PR；在此之前不开上游 PR。~~
   **09-18 修订（用户拍板，P1 完成当天）**：上游 PR 与 re-open #137 **推迟到 MVP-A0 跑通之后**（22/22 在 GPU 上与 DuckDB 基线一致）；
   P1 → MVP-A0 全程在 fork 的 `experimental-doris` 上迭代。理由：只有翻译器、没有 GPU 结果的 PR 对上游是"还不存在的东西"（同 D-5 的逻辑），
   有了 A0 的 22/22 才值得 review。fork 内部 PR（`experimental-doris → fork 的 dev`）仍可随时开，只为触发 `experimental.yml`，不算对外动作。
3. **Doris 版本（D-2）**：pin 4.1.x 最新 release；FE 二进制与 codegen 用的 IDL 是**同一个 tag**；不追 master。
4. **GPU 环境（D-3）**：AWS 自购，**P1 结束前不买**。单节点 `g6e.2xlarge`（省钱 `g5.2xlarge`），多节点 `g6e.12xlarge` 或两台单卡；
   Ubuntu 22.04/24.04、驱动 ≥ 580.65.06（否则 `cuda12` 环境）、gp3 ≥ 500 GB。Doris FE 用官方二进制，不编 Doris。
5. **数据入口（D-4）**：`local()` + `shared_storage=true`，TPC-H 表用 `CREATE VIEW` 包装；`glob` RPC 必做；`s3()`/`hdfs()` 不在 MVP 范围。
6. **对外口径（D-5）**：**暂不**在 #1590 / #137 公开说明；到 re-open #137 时（按 D-1 修订即 MVP-A0 之后）一并说。A/B 阶段对 #1791/#1792 的 cherry-pick 自己维护。
7. **引擎依赖**：MVP-A0 零依赖；MVP-A/B 以 #1791 + #1792 的指定 commit（`891d41c3` Rust `Fragment<'ctx>`、`d7f2a7e3` `pull_arrow/push_arrow`）为契约，
   cherry-pick 不追分支；不再引用 09-15 关闭的 20 个 draft。
8. **分期**：P0 → P1（Mac）→ MVP-A0（拼回一棵树，`execute_substrait`）→ MVP-A（真 fragment，store-and-forward）→ MVP-B（多节点，Arrow 先、NIXL 后）。
   A0 不可跳过（翻译器风险与引擎变动解耦），A 不可跳过（B 的调度器全在 A 里无网络建好）。

**理由**：
- SR 的 CN 已证明「原版 FE + Rust 协议壳 + 嵌入 Sirius」这条路能跑，且 Doris 的 FE→BE 协议面比 SR 还薄（gRPC、TVF 无 runtime filter、BE↔BE 可私有）。
- fork 起步避免重蹈 aocsa 20 个 draft 0 review 的覆辙；到有 22 条语料和绿 CI 再进上游，review 成本最低。
- 同 tag 的 FE 二进制 + IDL 消除翻译器枚举漂移（OQ-009 只需核实一次），且免去编译 Doris。
- P1 之前所有工作都能在 Mac 上 `--no-default-features` 完成，GPU 机早买就是空烧。
- `local()` 让同机多 BE 的 MVP-B 验证零外部依赖；`s3()` 省一个 `glob` 但要先把数据搬上 S3。
- 暂不公开：在没有语料和 CI 之前，对外承诺会把上游的注意力引到还不存在的东西上。

**放弃了什么**：独立仓库（失去 CI / CODEOWNERS 复用）；直接开上游 PR；Doris master；`s3()`；跳过 A0 直接做 A；现在就在 #1590 回帖。

**代价**：两套翻译器的维护税；协议壳随 Doris 版本漂移；`local()` 要求每个 BE 在同一路径看到同一批 parquet（跨主机每机一份）；
上游在 re-open #137 之前不知道我们在做，A/B 阶段 cherry-pick 的 rebase 成本自担。D-1 修订后这段"不知道"的窗口拉长到 MVP-A0，
`dev` 漂移后 `experimental-doris` 的 rebase 也自担（目录独立，冲突面小）。

---

## 开放问题

见 `handoff.md` 的「待决问题」表。OQ-001 / OQ-006 已由 ADR-011 关闭；OQ-002 / OQ-003 属轨 2，搁置；
OQ-007（MVP-B 传输）按 ADR-011 第 8 条 Arrow 先、NIXL 后；OQ-008 / OQ-009 在 P0 语料阶段核实。决定后在这里追加对应 ADR。
