# Doris 伪 BE 接入 Sirius（StarRocks CN 模式）可行性调研

> **日期** 2026-09-09
> **事实基线** sirius `origin/dev` @ `ea1c2783`（2026-09-08）；`experimental/starrocks` pin StarRocks `branch-4.1.1` @ `14b7e3fa`（2026-05-28）、brpc 1.9.0；
> Doris master @ `df36be5a`（2026-09-01，`wt-gpu` worktree）；`origin/doris` @ `9d3d7fe9`（2026-06-03）。
> **方法** 代码通读 + `gh` 元数据 + aocsa fork 分支上的设计/状态文档 + 对方 deck。
> **免责** 所有 benchmark 数字都是 Sirius 团队自测（fork 分支文档），本机无 GPU，未独立复现。
>
> **目标**（本次调研的题设）：参考 `experimental/starrocks/`，把 Doris FE 下发的 plan 翻译成 Sirius 执行计划并**分布式执行**，
> 跑通 TPC-H 全部 22 条，parquet 为文件格式。**非目标**：写入、Doris 内表、TPC-H 之外的能力。
>
> 与既有文档的关系：`design.md`/ADR-001 否决的「方案 A（伪 BE）」正是本文的题设。本文不推翻 ADR-001（那是对**长期产品路径**的判断），
> 只回答「如果把伪 BE 当作**验证/benchmark 载体**来做，要做多少事」——即 `meeting-2026-09-09-agenda.md` 议题 3 的「轨 1」。

---

## 0. 结论

1. **SR 项目要分三层看，不能看 deck。**
   `dev` 上已合并的 CN 只能跑**单 fragment**：翻译器明确拒绝 `EXCHANGE_NODE`、聚合只收一阶段（FE 要 `SET new_planner_agg_stage=1`）、
   只执行 `RESULT_SINK` 的 fragment，其余 fragment 收下即扔（translate-only）。
   9 月 2–3 日 aocsa 开的 **20 个 draft PR**（#1693–#1717，0 review、0 comment）补齐 exchange-as-stream、两阶段聚合、一 GPU 一 CN、byte-range split 等。
   **真正的跨节点 NIXL 传输（T6）、多 fragment 调度（T4c）、packed FFI（T5b）还没有任何可 review 的 PR**，只存在于 aocsa fork 的
   `feat/pin-table-cn`（+77k 行，#1686「demo don't merge」）。deck 的 15/15@SF500、fork 的 22/22@SF1000 都是 fork 的成绩；
   上游可合并线（#1644 rebase 后）2 CN SF100 实测 **12/22 正确 + 5 条 decimal 漂移 + 5 条阻断**。

2. **社区的目标非常明确，且几乎是 aocsa 一个人在推。**
   目标 = 「Sirius 作为 StarRocks shared-data 的 GPU CN：一 GPU 一进程，FE 照旧规划/调度，CN↔CN 用 NIXL/`cuda_ipc` 做 GPU 直传，
   线格式是 `cudf::chunked_pack` 字节（Sirius 自有格式），只在 MySQL 结果边界用 Arrow；**不做**与原生 BE 的 exchange 互通，
   runtime filter「FE 照旧规划、CN 安全忽略」」。8 条 track（T1–T8）正从 fork 切成小 PR，落地顺序 T1→T3→T2→T5→T7→T8→T4→T6。
   Doris 在 2026-06-10 被正式降优先级（#137），但明说「re-open the issue and we'd be happy to collaborate」。

3. **Doris 侧的协议面比 `design.md` §2.1 估的薄得多。**
   FE→BE 走 **gRPC（h2c）**而不是 baidu_std（StarRocks 那边手写 PRPC 帧的 490 行在 Doris 上不需要）；
   **TVF（`local()`/`hdfs()`/`s3()`）路径 FE 根本不生成 runtime filter**；`reportExecStatus` 对 SELECT 非必需；
   心跳 + 6 个 gRPC 方法就能让 FE 把 TPC-H 的全部 fragment 发过来。
   只要集群里**全是我们的节点**，BE↔BE 传输可以完全私有——PBlock 编解码、`transmit_block`、分区 hash 对齐都不必做（SR 正是这么做的）。

4. **建议的 MVP 分三步，前两步不依赖任何未合并的 Sirius PR。**
   - **MVP-A0（单节点、单计划）**：一个伪 BE，把 FE 下发的多 fragment 在翻译期**拼回一棵 Substrait 树**（exchange 处接上游子树、两阶段聚合合并成一阶段），
     走 `dev` 上现成的 `Context::execute_substrait`。产出：TPC-H 22 条在 GPU 上跑通并与 Doris CPU 结果逐行一致。这一步验证的是翻译器和引擎覆盖面，
     也是风险最集中的地方。
   - **MVP-A（单节点、真 fragment）**：按 FE 的 fragment 拓扑逐个执行（store-and-forward，`relay_from` 同进程接力），两阶段聚合按 FE 的 phasing 走。
     依赖 #1697（`Fragment::build()` 修复）+ #1702（Rust `Fragment` 绑定），两者都是小 PR，等不到可以本地 patch。
   - **MVP-B（多节点、一 GPU 一 BE）**：跨进程 exchange。首选复用 aocsa 的 packed/NIXL 链路（T5b/T6，无时间表）；
     过渡方案是 Arrow-IPC-over-gRPC + `push_arrow`（aocsa 已有原型 #1724，实测慢 NIXL 两个数量级，只够验证正确性）。

5. **这条路线的进度上限 = aocsa 的上游进度。** 四个引擎侧阻断项全握在他未合并的工作里：`build()` 修复（#1697）、Rust `Fragment`（#1702）、
   `push_packed`/`export_packed`（T5b，未开 PR）、非阻塞 `run()`/多 fragment 并发（#1590，无代码）。此外引擎本身仍是**单飞**（一个 Context 同时一个查询，#1303 刚合了第 1 个 PR）。

6. **工作量**：Doris 侧 ≈ 10–13k 行 Rust（含测试），其中 ≈ 3–4k 可从 `origin/doris` 和 SR 直接搬。
   MVP-A0 约 6–8 周（1–2 人，**必须有 GPU 机器**）；MVP-A 再 3–4 周；MVP-B 取决于引擎侧，自建过渡传输约 4–6 周。

7. **一个此前不知道的事实**：aocsa 在 9 月 4 日的 `demo/arrow-inprocess-io`（#1724，当天开当天关）里已经把 #1590 上提的 `push_arrow`
   **原样实现**了（签名不变，13 个 Catch2 用例，H2D 实测 10 GB/s），配套文档开头写着「For Morningman (Apache Doris…)」，
   并给出了线程契约的书面结论（先 store-and-forward，签名不变，之后放宽到 `run()` 期间任意线程可推）。只是没回帖到 #1590。

---

## 1. 参照物：`experimental/starrocks` 进展到哪了

### 1.1 三层视角

| 能力 | `dev` 已合并 | draft PR（#1693–#1717，09-02/03） | 只在 fork（`feat/pin-table-cn`、#1644） |
|---|---|---|---|
| 节点身份（自注册 / 心跳 / BackendService 桩 / FE report） | ✅ | — | — |
| FE→CN 分发（手写 PRPC 帧 + `exec_plan_fragment` / `exec_batch_plan_fragments`） | ✅ | — | — |
| `FILES()` schema 推断 | ✅ 单文件 | #1705 多 range | — |
| 翻译器：scan / filter / project / 一阶段 agg / sort / hash join / NL join | ✅ | #1704 `CLONE_EXPR` + 窄类型回 cast | — |
| 翻译器：`EXCHANGE_NODE` → stream read | ❌ 明确拒绝 | #1708 | — |
| 翻译器：两阶段聚合 / avg 拆分 / 列序 / 公共表达式 slot | ❌ | #1709 #1711 #1710 #1713 | — |
| 引擎：`Fragment` FFI（declare → build → relay_from → run） | ✅ #1481，但 `build()` 在 DuckDB 1.5.5 下必抛 | #1697 修复；#1702 Rust 绑定 | — |
| 引擎：staging arena / stream 基数 / 卡死 watchdog | ❌ | #1693 #1694 #1699 | — |
| 引擎：`export_packed` / `push_packed` / `push_arrow` | ❌ | ❌（T5b 未开） | ✅（#1644、#1724） |
| 引擎：非阻塞 `run()`、push/pull/wait FFI、多 fragment 并发 | ❌ | ❌（#1590 无代码） | ❌ |
| byte-range split 读 parquet | ❌ 只接受整文件切分（#1232） | #1696 #1700 #1717（第 3/4 步 #1638/#1639 已关未重开） | ✅ |
| CN：一 GPU 一进程、显存切分、就绪门 | ❌ | #1714 | ✅ |
| CN：中间 fragment 失败传播到结果 instance | ❌ | #1715 | ✅ |
| CN：多 fragment 调度（receiver-first、dispatch worker、Local/Remote 路由） | ❌ | ❌（T4b/T4c 未开） | ✅ |
| CN↔CN 传输：NIXL/`cuda_ipc`、三个私有 RPC、bRPC 客户端 | ❌ | #1706 参数注册表、#1707 proto patch（只有 proto） | ✅ |
| 分布式 TPC-H | ❌ | ❌ | ✅ 见 §1.5 |

### 1.2 `dev` 已合并：代码事实

`experimental/starrocks/` 共 14.5k 行（`wc -l`）：`src/` 5.6k（11 文件）、翻译器 3.9k + 测试 4.6k、构建脚本 0.4k。
历史：mbrobbel 2026-05-28 #816 建目录 → #941 分发 → #1008 首次回行 → #1021/#1022/#1024 GPU 执行 → #1109/#1110/#1111 表达式/聚合/join →
#1232–#1236（09-02 合并）scan 切分、公共 slot、anti join、decimal 降 FP64。

**协议壳**（`src/lib.rs` 1.8k、`prpc.rs` 0.5k、`brpc.rs` 0.3k、`build.rs` 0.3k）
- 用 MySQL 协议 `ALTER SYSTEM ADD COMPUTE NODE` 把自己注册进**未改动**的 FE；FE 配 `run_mode = shared_data`，CN 上报非零 `starlet_port` 才会被调度（#1004）。
- thrift `HeartbeatService` + `BackendService`（24 个 handler，15 个直接 `NOT_IMPLEMENTED`）；定期向 FE 发空 inventory report。
- **手写 baidu_std（PRPC）帧解析**（因为 StarRocks FE 用 baidu_std 调 CN）+ prost 生成的 Tower facade；`PInternalService` 只实现 4 个方法：
  `exec_plan_fragment`、`exec_batch_plan_fragments`、`fetch_data`、`get_file_schema`。
- 调试钩子（#1108）：`SIRIUS_CN_DUMP_FRAGMENTS` 落盘 thrift 参数和 Substrait；`SIRIUS_CN_TRANSLATE_ONLY` 只翻译不执行（采语料用）。

**翻译器**（`crates/starrocks-plan-translator/`）
- 扁平先序树重建 + `ensure_consumed` 不变式；结构化 `TranslateError`；`(tuple_id, slot_id)` 联合键（踩过两次坑，#1006/#1025）。
- 节点 8 种：`FILE_SCAN`（→ `local_files` parquet）、`HDFS_SCAN`（→ named table）、`SELECT`、`PROJECT`（公共 slot 先物化成隐藏 `ProjectRel`）、
  `AGGREGATION`（**仅一阶段**）、`SORT`（仅全局 top-N）、`HASH_JOIN`（inner/outer/left-semi；anti 用 outer+`is_null` 或 mark+`not`）、
  `NESTLOOP_JOIN`（常量键 inner/cross，#1234 把 cross 降成等值 join，因为引擎不支持 `CROSS_PRODUCT`）。
  节点 `conjuncts` → `FilterRel`，`limit` → `FetchRel`。**`EXCHANGE_NODE` 拒绝。**
- 表达式：`SLOT_REF`、各字面量、`BINARY_PRED`、`COMPOUND_PRED`、`CAST`、`IS_NULL`、`ARITHMETIC`（decimal 操作数降 **FP64**）、`IN`、`CASE`、
  `FUNCTION_CALL` 白名单（`like`、`if`、`substring/substr`、`length`、`char_length`、`year/month/day`）。
- 聚合：`sum/count/min/max/avg` + `multi_distinct_*`。类型：拒绝 `LARGEINT`、`DECIMAL256`、精度>38、复杂类型；`JSON/VARIANT` 当字符串；
  decimal 精度>18 映 FP64。**decimal 不精确**是文档明写的已知代价。

**执行与结果**（`engine.rs`、`fragment_executor.rs`、`compute_node_service.rs`、`result_*.rs`）
- `SiriusEngine` 一个专用线程持有 `!Send` 的 `SiriusContext`，mpsc 串行；`execute_substrait` 整计划进、整结果出（Arrow）。
- 只有 `RESULT_SINK` 的 fragment 会执行并缓冲；`DATA_STREAM_SINK` 的 fragment translate-only 直接返回 OK——所以 FE 一旦规划出 exchange，查询在 `fetch_data` 处失败。
- 结果编码：Arrow → MySQL text 行 → `TResultBatch`（TBinary）→ PRPC attachment；`fetch_data` 按 `packet_seq`/`eos` 分页。
- FE 侧只有一个 `fe.conf`：`shared_data`、`enable_load_volume_from_conf=false`、`default_replication_num=1`。

### 1.3 在途：20 个 draft PR

作者全部 aocsa，提交日期 09-02/03，每个 commit 都带 `Co-Authored-By: Claude`，CI 绿，**0 review、0 comment**（截至 09-09）。
来源都是 fork 分支 `feat/pin-table-cn`，按 #1644 里的 `PR-CLASSIFICATION.md` 切成 8 条 track。

| Track | 内容 | 已开 PR（stack 顺序） | 未开 |
|---|---|---|---|
| T1 修复 | `Fragment::build()` 事务作用域；卡死 watchdog；`CLONE_EXPR`；多 range `FILES()` schema | #1697、#1699、#1704、#1705 | — |
| T3 exchange-as-stream | `EXCHANGE_NODE` → `ReadRel(sirius_stream_<node_id>)`；merging exchange → `SortRel`；`output_partition_columns` | #1708 | — |
| T2 两阶段聚合 | `agg_phase::classify`（OneShot/Partial/Merge）、`partial_state` 线上类型（decimal sum 在线上是 DOUBLE）、count→sum、avg 拆 sum+count、列序、公共 slot | #1709 → #1710 → #1711 → #1713 | — |
| T5 arena + packed FFI | `exchange_staging_arena`（RMM 池外的 `cudaMalloc` 区，UCX `cuda_ipc` 不能导出 `cudaMallocAsync` 内存，否则慢 220×）；stream 基数声明 | #1693、#1694 | **T5b：`export_packed`/`push_packed`/`StagingArena` FFI + Rust** |
| T7 NIXL 构建管道 | 传输参数注册表；把 3 个私有 RPC（`exchange_nixl_md`、`request_staging_lease`、`transmit_packed`）patch 进 StarRocks `PInternalService` | #1706、#1707 | — |
| T8 多文件 FILES() | pinned parquet 表按文件子集提供 | #1717（栈在 #1700 上） | — |
| scan byte-range | 字节范围 → row-group 归属规则（对齐 StarRocks BE）；ingestible 按范围读 | #1696 → #1700 | 第 3/4 步（Substrait 携带 range、CN 发出部分 split）#1638/#1639 已关未重开 |
| T4 CN 多 fragment | 一 GPU 一 CN（`--gpu-device`、显存/内存切分、NUMA 亲和、心跳就绪门）；失败传播 | #1714 → #1715 | **T4b engine.rs Fragment seam、T4c receiver-first rendezvous + dispatch worker** |
| T6 NIXL 传输 | bRPC 客户端、NIXL 线程、warmup + 带宽金丝雀、接收 staged frame、drain fan-out | — | **全部未开（≈7k 行）** |

其它相关：#1644「Stream fragment execution」伞状 draft（+17.6k，`CONFLICTING`，说要关但没关）；
mbrobbel 的 #1237（merging exchange 输入排序）draft 无 review；#914 exchange 设计文档 draft 自 06-14 无动静；
#1242（物化 exchange 走 parquet 中转）09-02 被 aocsa 以「设计上被 #1708 取代」关闭。

### 1.4 只在 fork 上：真正的分布式执行

fork 分支携带上游没有的一整套：`nixl_transport.rs`、`local_exchange.rs`、`wire_type_parity.rs`、`bench/` 下 5 个机器目录的结果、
`benchmarks/{cluster8.sh, cn-2host.sh, tpch/bench.sh}`、`.claude/skills/{tpch-bench, cn-tuning, tpch-2host, tpch-cn-sweep}`、
设计文档 `ROADMAP-8CN-TPCH.md` / `MULTI-CN-PLAN.md` / `TWO-CN-NIXL-DEMO.md` / `OPEN-ISSUES.md` / `PLAN-01..09` / `PR-CLASSIFICATION.md` / `TPCH-SWEEP-RESULTS.md`。
这些都不在 `dev` 上。

### 1.5 TPC-H 成绩单

| 日期 / 机器 / 分支 | 结果 |
|---|---|
| deck（`deck-sirius-on-starrocks.pptx`）SF500，8×A100 80GB 单机 | **15 of 15**：q01 02 03 04 06 07 11 12 13 14 16 17 19 20 22；套件 23.02 s vs StarRocks 101.91 s = 4.43×；q01 1.14× 低于 break-even 1.50× 照放。**缺 q05 08 09 10 15 18 21**。SF1000：q07「fragment-exchange stall at 600 s」被拒 |
| 08-07 SF1 `demo-multi-cn` | 19/22 → 22/22（DuckDB 差分） |
| 08-09 4×GB200 SF100 | 18/22；q05/q10/q18 跨次运行退化到 wedge；q08 60 s RPC 超时；q09 拒绝；FE 自动拉黑 4 个 CN 中的 2 个 |
| 08-12 8×A100 SF500 scale-out | 10 条在 2/4/8 GPU 都过；2→4 GPU 3.31×（超线性、未解释），4→8 1.39×；q21 arena 耗尽；q02 8 GPU 负扩展；q05/08/09/10/18 未尝试 |
| 08-19 2×RTX PRO 6000 SF100 | 20/22 记录；改写 q08/q09 的 FROM 顺序后「全部 22 条行集正确」（FE 对 `FILES()` 无统计信息 → cross-join 计划） |
| 08-20 同机 SF300 / SF500 | 21/22 / 21/22；q09「每 fragment 内存墙」；q21 间歇 600 s 调度卡死；q07 每次泄漏 11.3 GiB parked output |
| **08-25 上游线 #1644 @4891c6bf，2 CN SF100** | **12/22 精确**（q02 04 06 11 12 13 16 17* 18 20 21 22，*需 `agg_stage=1`）；5 条只差 decimal→FP64 漂移（q03 05 10 15 19）；5 条阻断：q01 两阶段 avg → #1711；q07 300 s 卡死 → #1699；q08/q09 `o_year` SMALLINT vs BIGINT 线上类型 → #1704；q14 `CLONE_EXPR` → #1704/#1713 |
| 08-28 8×GB200（2 主机）| SF1000 **22/22**；SF3000 20/22（q09、q21 arena）；SF10000 14/22（`bad_alloc`/arena，「需要 copy-out-on-arrival」） |
| 09-04 2×RTX PRO 6000 SF1000 #1724 | NIXL warm：q01 6.5 s、q03 7.5 s、q07 9.7 s；Arrow-over-bRPC：q03 84 s、q04 OOM、q07 CN segfault |

系统性缺陷（aocsa 自己列的）：decimal→FP64 漂移（#1687/#1688，「decimal 原生 GPU 表达式路径才是真正的修法」）；
staging arena 耗尽/棘轮（`push_packed` 先拷进池再释放 lease，lease 要等整个 sender 集合关闭；copy-out-on-arrival 未实现）；
parked output 泄漏 + 没有真正的 `cancel_plan_fragment`（`run()` 内的 fragment 无法中止，harness 里 `RESTART_CMD` 是必需品）；
传输单线程 + 60 s RPC 超时；FE 对 `FILES()` 无统计信息导致 join 顺序错。

### 1.6 缺口清单（相对「分布式 TPC-H 22 条」）

**SR 集成层，未上游**：T6 跨节点传输、T4b/T4c 多 fragment 调度、T5b packed FFI、byte-range 第 3/4 步、bench harness。

**引擎**（详见 §2.4）：非阻塞 `run()` 与多 fragment 并发（#1590）；并发查询（#1303，仅 #1364 已合）；`cancel`；decimal 原生表达式；
背压（#1276 决定**不做**，靠 downgrade executor 溢写）；order-preserving exchange（#1237 draft）；host 可注入的 dynamic filter（不存在）。

**翻译器**：`count(DISTINCT)` 两阶段（partial state 是 `COLLECT_SET`，不可跨 exchange，q16 只能一阶段）；`like` 只接常量且无转义、`substring` 只接常量正参数；
29 个标量函数 / 8 个聚合的白名单（无 `upper/lower/trim/round/abs`）。

---

## 2. 社区在做什么、目标是什么

### 2.1 人与治理

- 19 位 maintainer（NVIDIA 14 / UW-Madison 3）。CODEOWNERS（#1367，08-12）：`/experimental/` 和 `/rust/crates/sirius*/` → `@sirius-db/sirius-integrations`；
  `src/**/exec/` → `sirius-core`；`**/*.rs` → `sirius-rust`。
- **aocsa**：69 个 PR，5 个合并（+9,024/−1,396），20 个 open（全 draft），44 个关闭未合并；最近 30 天开 34 个、合 4 个。
  这 30 天全花在「把 fork 工作 rebase 到 dev 并切成可 review 的片」上，没有新增能力。
- **mbrobbel**：SR 翻译器基础（#816–#1236）、#914 设计文档、#1052 StarRocks 兼容 CRC32 分区 hash GPU kernel（已合）；09-02 之后只做了 cudf nightly 修复。
- **wmalpica / felipeblazing**：并发线（#1364 于 09-08 合并；#1365/#1366/#1369 冲突待 rebase；#1583 +37k 行集成 draft 无 review）。
- 没有 milestone；roadmap 一句话（「multi-node, more operators, data types, accelerating more engines」）；README 正文「supports DuckDB and Starrocks (coming soon)」；
  `multi-gpu-architecture.md` 仍写「Multi-process / multi-node execution is out of scope」。
- **Doris**：#137（dataroaring 2026-01-03 开）在 **2026-06-10** 由 roaramburu 关闭：「we're deprioritizing Doris support for the foreseeable future.
  If you would like to push this forward, please re-open the issue and we'd be happy to collaborate.」`origin/doris` 自 06-03 冻结，落后 dev 441 个 commit。
- #1590 上的 `push_arrow` 提案（09-01）：mbrobbel、aocsa 各一个 ❤️，**无文字回复、无引用它的 PR/issue**。

### 2.2 aocsa 的目标架构（原话）

- 拓扑：「Two Sirius compute-node processes on one host, splitting the GPU… with cross-node transport with nixl as the final goal」（`MULTI-CN-PLAN.md`）；
  推广为 **one CN per GPU**（#1693、#1714）；「Never two engines in one process… `SiriusContext` is `!Send`/`!Sync` and explicitly one-per-process」。
- 引擎无感：「Sirius stays deliberately unaware it is being used for distributed execution」（deck）；
  「Sirius itself stays fragment-blind… pairing a leaf fragment's output id with a root fragment's input id — across sessions and nodes — is the wrapper's routing table, never the engine's」（`streaming-sessions.md`）。
- 身份：「the stream id *is* the exchange node id. Both sides read it out of the same plan」（#1398）。
- 喂 EXCHANGE 输入的三种方式，都只在 `build()` 与 `run()` 之间合法：`relay_from`（同进程，指针搬运）、`push_packed`（远端 CN，`cudf::unpack` staging lease 后深拷进池）、
  `push_arrow`（host Arrow C Data，H2D）；`close_input(stream, sender)` 是 EOS。
- 线格式：「`export_packed` into a staging lease (`cudf::chunked_pack` gathers directly into the lease…), nixl WRITE into the peer's lease, `transmit_packed` with the pack metadata」；
  只有控制帧走 bRPC；「Stock-BE interop — both exchange endpoints are our CN; `ChunkPB` layout compatibility is explicitly not attempted」。
- 两阶段聚合：FE 决定 phasing；「No StarRocks-specific merge operator: both ends are Sirius, so the partial state ships in Sirius' own format and NIXL routes opaque bytes by hash」（deck）。
- runtime filter：「the FE plans them and the CN ignores them safely」（`ROADMAP-8CN-TPCH.md` §5）。
- 线程契约：「the `Context` is single-threaded by contract」；`StagingArena` 是唯一任意线程可调的面；`push_*` 只在 build/run 之间；
  #1590 的 `start()/join()` 拆分与 push-during-run 只在 issue 里，没有代码。
- 里程碑门槛：「grouped `count(*)` over TPC-H lineitem, 2 CNs (one per GPU), shuffle over NIXL/`cuda_ipc`, matches the DuckDB oracle exactly」（#1644 @4891c6bf）。

### 2.3 落地顺序与现实速度

声明的顺序：T1 → T3 → T2 → T5 → T7 → T8 → T4 → T6。截至 09-09：T1/T3/T2/T7/T8 已开 PR（无 review），T5 只开了 arena（T5b 未开），T4 只开了 bring-up（T4b/T4c 未开），T6 全未开。
按 mbrobbel 在 09-02 一天合并 4 个 mbrobbel 自己的旧 PR、之后再无 review 活动来看，**这 20 个 PR 的合并节奏取决于 sirius-integrations 组是否有人 review**，外部无法预测。

### 2.4 引擎侧：已合并 / 阻断项

已合并（`dev`）：`STREAMING_SOURCE`（#1320）、`STREAMING_SINK` + hash/broadcast 分区（#1479）、`stream_session`（#1480）、`streaming_fragment` + `ffi::Fragment`（#1481）；
dynamic filter（IN-list/bloom/zone-map，仅 INT32/INT64 键，**仅单计划内**，无外部注入口）；hash join 9 种 + NLJ 7 种；`DELIM_JOIN`；`count(DISTINCT)`（`COLLECT_SET`）；
downgrade executor 三级溢写；单进程多 GPU。

阻断「宿主喂数据的分布式执行」的引擎缺口（按严重度）：

| # | 缺口 | 状态 |
|---|---|---|
| 1 | FFI 没有任何外部数据入口（`stream_session::push` 是 C++ 内部、收 `cucascade::data_batch`） | `push_packed`/`export_packed` 在 #1644/fork；`push_arrow` 在 #1724；都未上游 |
| 2 | `Fragment::run()` 阻塞；一个 Context 同时只允许一个 fragment 在 build/run 之间；无 push/pull/wait/cancel | #1590 无代码 |
| 3 | `dev` 上 `Fragment::build()` 在 DuckDB 1.5.5 下必抛 `ActiveTransaction called without active transaction` | #1697 draft |
| 4 | Rust 侧无 `Fragment` 绑定 | #1702 draft |
| 5 | 单飞：一个 `SiriusContext` 同时一个查询 | #1303，#1364 已合，后续冲突 |
| 6 | 无 C ABI、无可分发 libsirius（Rust 走 cxx 共编构建树） | — |
| 7 | 两阶段聚合的 partial state 不是引擎概念，宿主自己做代数（sum→sum、count→sum、avg→sum+count）；`count(DISTINCT)` 不可拆 | 翻译器侧解决（#1709/#1711） |
| 8 | `FileOrFiles.start/length` 被消费端忽略 → 大文件不能跨节点切 | #1696/#1700，第 3/4 步未开 |
| 9 | dynamic filter 仅 fragment 内、不可注入；`STREAMING_SOURCE` 不是消费者 | — |
| 10 | 分区 hash 是 cudf murmur3 + 键归一化（decimal→FP64）；只有 hash/broadcast，无 range、无保序 | 全 Sirius 节点时无对齐问题 |
| 11 | stream 输入线上类型严格相等（q08/q09 的 `o_year`） | #1704 |
| 12 | 无背压（#1276 设计决定） | — |
| 13 | DuckDB 会重新优化宿主的计划（join 顺序、build 侧），stream 输入在 #1694 之前基数视为 1 行 | #1694 draft |
| 14 | Substrait 消费端：`Root.names` 按位置套、`SetRel` ≤2 输入、无 Exchange/Expand、`local_files` 仅 parquet/无 glob、LIKE 无转义、`substring` 常量、29 标量/8 聚合 | — |
| 15 | 结果先整体物化再转 Arrow（4 次拷贝，1.1–1.2 GB/s；`to_arrow_host` 一次拷贝 4.1 GB/s 在 #1724 里） | — |

### 2.5 与 Doris 直接相关的三件事

**(1) #137 的态度**：降优先级但欢迎 re-open。加上 CODEOWNERS 里 `/experimental/` 有明确 owner 组，「在 sirius 仓库里建 `experimental/doris/`」在治理上是通的。

**(2) #1724 `demo/arrow-inprocess-io`（09-04）**：`docs/arrow-inprocess-io-demo.md` 开篇「For Morningman (Apache Doris, author of the `push_arrow` proposal on sirius-db/sirius#1590) and the Sirius/StarRocks team」。
- `push_arrow(stream_id, sender_id, array_addr, schema_addr)` 签名与提案一致；`cudf::from_arrow` H2D；不动 `stream_session`/`streaming_source`/cuCascade（与 study §4 的预测一致）。
- 与提案假设的 7 处差异都有结论：不做 reservation（与 `push_packed` 一致）、不引 nanoarrow（用 DuckDB 的 `arrow.hpp`）、string offset 只支持 INT32（`large_utf8` 按名拒绝）、`sender_id` 做成员校验、struct slice 修正。
- **线程契约结论（草稿）**：「`push_arrow` and `close_input` may be called from any thread once `build()` has returned, including while `run()` is blocking on another thread… There is no backpressure yet」；
  但今天的树里做不到（Rust `&mut self` + `!Send`），所以「Store-and-forward first (M1 to M3) with the final signature, so a Doris host can start today」。
- 实测：`push_arrow` 10.0–10.2 GB/s；今天的结果路径 1.15–1.23 GB/s（4 次拷贝）；M4 `to_arrow_host` 4.0–4.2 GB/s；NIXL 48–56 GB/s。
  文档自己的判断：「The gap… disappears only where the data already lives on the host: a CPU scan (an internal table on a Doris BE) pays the H2D leg instead of a GPU scan」。
- 这对本文题设（伪 BE）的意义：Arrow 入口不是本路线的主传输，但它是 **MVP-B 过渡传输**（Arrow IPC over gRPC → `push_arrow`）和 **MVP-A 混合验证**的现成积木。
  对进程内路线（ADR-010）它就是那 150 行。

**(3) `origin/doris` 先例**（mbrobbel，2026-02-12 → 06-03，160 个 commit 触及 `doris/`）
- 架构与 SR 同源（同一作者，SR 是清理后的第二版）：Rust 伪 BE 自注册、心跳、`PBackendService`（tonic gRPC + 嗅探 `PRPC` 魔数的 baidu_std 同端口）、翻译到 Substrait、`fetch_data` 回 MySQL 行。
- 比 SR 多做的：**多 fragment 全执行**（每个 FE fragment 独立跑，`EXCHANGE_NODE` 读 `__EXCH_*` 表）、PBlock 编解码（1.7k + 0.8k 行）、`transmit_block` 客户端/服务端、
  Doris 兼容 CRC32/CRC32C hash partitioner、nixl GPU 直传、GPU packed 表注册、UNION ALL、CTE multicast、SEMI/ANTI。
- 少做的：runtime filter 完全没实现（RPC 全桩）；只支持 `local()`（`hdfs()/s3()` 从未支持）；`OLAP_SCAN` 拒绝。
- 引擎耦合是**致命伤**：它靠 `duckdb` crate `LOAD` 两个扩展 + `libloading` 11 个 `sirius_*` C 符号 + `src/legacy/gpu_buffer_manager.cpp`（`-DENABLE_LEGACY_SIRIUS=ON`）。
  这些在 `dev` 上一个都没有（`gpu_execution_substrait`、`sirius_exchange_c_api`、`LastGPUBuffers`、`ExchangeSession` 全无）。**`sirius-ffi` crate 不可复用，必须换成 `rust/crates/sirius`。**
- TPC-H：02-26 FINDINGS 是 `--force-cpu`（Docker CDI 下 `cudaMemcpyBatchAsync` 失败）；03 月起原生环境 GPU 跑通，03-24 「Full GPU→GPU distributed GROUP BY with correct results」（2 GPU BE）；
  04-13「22/22 baseline」（模式/BE 数未记录）；06-03 单 BE GPU SF1 聚合/Q6 验证通过。nixl 可靠性从未有最终结论（04-07「checksums match but data corrupts later」）。
- 可直接搬的（纯 Rust、不耦合引擎）：thrift/proto 代码生成、`deserialize_params`（VERSION_3 共享字段合并）、心跳 `TBackendInfo`、`type_mapper`、表达式字面量/decimal 编码、join 类型映射、
  `fetch_table_schema` 解码 + `glob`、`fetch_data` 的 TBinary 编码、PBlock 编解码（如果将来要与原生 BE 互通）、`hash_partitioner`、`exchange_buffer`、`run-tpch.sh` + `validate_tpch_results.py`、FE conf 与端口方案。
- 文档是 2–3 月快照，代码是 4–6 月真相；`OVERVIEW.md` 仍说 hash 分区未实现，实际 03-18 就有了。

---

## 3. Doris 接入 MVP

### 3.1 定位与既有决策的关系

- 本文题设 = `meeting-2026-09-09-agenda.md` 议题 3 的**轨 1（快）**：Doris FE + Sirius 伪 BE，验证与 benchmark 载体，**不是 Doris 的正式集成路径**。
  正式路径仍是 ADR-010 的 BE 进程内子树卸载（轨 2），两条并行、不互相替代。
- 若采纳，需追加 **ADR-011**（不改写 ADR-001/007）：明确伪 BE 的定位、落点、维护承诺边界。ADR-007「不在 sirius 建 `experimental/doris`」针对的是进程内路线；伪 BE 路线对齐 SR 结构，落在 `experimental/doris/` 更合理（CODEOWNERS 已有 owner 组，`experimental.yml` CI 已有无 GPU 的 `cn-test-no-engine` 先例）。
- 两轨共享的资产：TPC-H fragment 语料（M0.2）、语义差异清单（`semantics-gaps.md`）、类型/表达式白名单、差分验证脚本。伪 BE 的翻译器（Rust）和进程内的翻译器（C++，ADR-003）逻辑同构、语言不同——这是轨 1 的一项永久税，要在 ADR-011 里写明接受。

### 3.2 Doris 协议面：最小 RPC 表

（Doris master @ 09-01；4.1.3/4.1.4 上完全相同；非 cloud 模式）

| RPC | 传输 / 端口 | 用途 | 难度 | 备注 |
|---|---|---|---|---|
| `HeartbeatService.heartbeat` | thrift binary（非 framed）/ heartbeat 端口 | 存活 | 低 | alive 仅取决于 `status=OK`；需 `be_port`、`http_port`、`brpc_port`、非零 `be_start_time`、`be_node_role="mix"`（`computation` 会被 TVF 调度排除）；FE **不比版本**；每 10 s 一次，失败 1 次即 dead |
| `BackendService.*`（`publish_topic_info` 30 s、`get_dictionary_status` 5 s、`get_tablet_stat` 60 s、`get_stream_load_record` 120 s） | thrift / `be_port` | 无（周期性，失败只 warn） | 低 | 返回 OK/空或 NOT_IMPLEMENTED 均可 |
| `FrontendService.report` / `reportExecStatus`（BE→FE） | thrift / FE `rpc_port` | SELECT 不需要 | 跳过 | 不上报 cores → `parallel_pipeline_task_num` 自动解析为 1，正合适 |
| `PBackendService.fetch_table_schema` | **gRPC h2c** / `brpc_port` | 分析期 schema 推断（三种 TVF 都会调） | 中 | 请求是 TBinary 的 `TFileScanRange`（首个非空文件）；回 `PTypeDesc`；`DESC FUNCTION` 也走它 |
| `PBackendService.glob` | gRPC | `local()` 列文件 | 低 | `PGlobRequest{pattern}` → `files[{file,size}]` |
| `exec_plan_fragment` / `_prepare` / `_start` | gRPC | 分发 | 高 | `PExecPlanFragmentRequest{request, compact=true, version=VERSION_3}`；`request` = **TCompact** 的 `TPipelineFragmentParamsList`，一个 BE 的全部 fragment 在一个 RPC 里、**顶层 fragment 在前**；只有首个带 `desc_tbl`/`file_scan_params`/`coord`，其余 `is_simplified_param`；>1 fragment 时两阶段 prepare/start |
| `cancel_plan_fragment` | gRPC | 每条查询都会收到（成功也发 `FINISHED`） | 低 | |
| `fetch_data` | gRPC | 结果 | 中 | key = `query_id`（`enable_parallel_result_sink=true` 默认）或顶层 instance id；`packet_seq` 从 0 严格 +1；`row_batch` = **TBinary** 的 `TResultBatch`（与请求的 compact 不对称）；MySQL text 行、NULL=`0xFB`；结果未就绪要**挂起不回**（真 BE 如此，FE 只等超时） |
| `transmit_block`（BE↔BE） | baidu_std / `brpc_port` | 原生 BE 的 exchange | — | **全 Sirius 节点时不需要**；FE 只把 `destinations{brpc_server}` 交给上游 fragment，BE 间协议 FE 不管 |
| RF 四件套 `send_filter_size`/`sync_filter_size`/`merge_filter`/`apply_filterv2` | gRPC / baidu_std | runtime filter | — | TVF 路径**从不产生**；catalog 路径 `runtime_filter_mode=OFF` 关掉。若将来实现，切勿对 `send_filter_size` 回 OK 却不发 `sync_filter_size`（对端 join build 会挂到超时） |
| 其余 ~46 个 | gRPC | 无 | 跳过 | tonic 生成 trait 全部 `unimplemented` |

**与 SR 的关键差异**：Doris FE 用 grpc-java 直连 `brpc_port`（真 BE 的 `brpc::Server` 同端口自动识别 h2 与 baidu_std），所以我们用 tonic 就够，
SR 那 490 行手写 PRPC 帧不需要；只有 BE↔BE 私有传输时才需要自定义协议（可以就是另一个 gRPC service 挂在同一端口）。

### 3.3 FE 参数：把计划形状收敛

MVP 建议的 session 变量（来源 `SessionVariable.java`，默认值括号内）：

| 变量 | 设置 | 作用 |
|---|---|---|
| `parallel_pipeline_task_num`（0=自动） | 1 | 每 BE 每 fragment 一个 instance；也抑制 `LOCAL_EXCHANGE_NODE` |
| `enable_local_shuffle_planner`（true） | false | FE 不再插 `LOCAL_EXCHANGE_NODE`（master 新节点类型 38） |
| `enable_cte_materialize`（true） | false | Q15 若写成 `WITH` 不走 `MULTI_CAST_DATA_STREAM_SINK` |
| `runtime_filter_mode`（GLOBAL） | OFF | catalog 路径不生成 RF；TVF 路径本来就没有 |
| `topn_lazy_materialization_threshold`（1024） | -1 | 不出现 `MATERIALIZATION_NODE` + lazy TVF scan（`origin/doris` 用 0） |
| `file_split_size`（0，默认 32/64 MB 切） | 1 TB | 每文件一个 split（引擎消费端忽略 byte range；#1696/#1700 落地前必须） |
| `enable_parallel_result_sink`（true） | false | 结果收敛到一个 gather fragment，`fetch_data` 单点 |
| `enable_fold_constant_by_be`（false）、`enable_profile`（false） | 保持 | 避免 `fold_constant_expr` RPC |
| `enable_sql_cache`（true） | catalog 路径设 false | TVF 路径无影响 |
| `query_timeout` | 大 | SF1000 级别需 3600 |

FE conf（沿用 `origin/doris`）：`enable_outfile_to_local=true`、`enable_access_file_without_broker=true`、`priority_networks`、`arrow_flight_sql_port=-1`。
数据入口首选 `local()` TVF（`shared_storage=true` + 目录 `glob` 让 FE 把文件分给多个 BE），其次 `s3()`/`hdfs()`（FE 自己列文件，无 `glob`）。

### 3.4 计划形状与翻译覆盖

**TPC-H over TVF 时 Nereids 会发出的节点**（`PhysicalPlanTranslator.java`）与 SR 对照：

| Doris `TPlanNodeType` | 出现场景 | SR 对应 / 状态 | Doris 翻译器要点 |
|---|---|---|---|
| `FILE_SCAN_NODE` | 所有叶子 | `FILE_SCAN_NODE` ✅ dev | 路径在 `local_params[].per_node_scan_ranges[node].ranges[].path`，参数在 `file_scan_params[node_id]`（首个 fragment）；`required_slots`/`column_idxs` 决定投影；`conjuncts` → `FilterRel`；`push_down_agg_type_opt` 的 `count(*)` 优化可忽略 |
| `EXCHANGE_NODE` | 每个 fragment 边界 | #1708 draft | → `ReadRel(sirius_stream_<node_id>)`；`sort_info` → `SortRel`（+`offset`）；sender 数 = `per_exch_num_senders[node_id]` |
| `HASH_JOIN_NODE` | Q2–Q22 | ✅ dev（anti 用 outer+is_null / mark+not） | Doris 的 `NULL_AWARE_LEFT_ANTI_JOIN`（Q16 `NOT IN`）→ mark join + `not`；`other_join_conjuncts` → 引擎 MIXED join（Q7/Q19/Q21）；`vintermediate_tuple_id_list`/`output_tuple_id` 决定输出布局 |
| `CROSS_JOIN_NODE`（NestedLoop） | Q11/Q15/Q22 标量子查询、Q16 | `NESTLOOP_JOIN_NODE` ✅（#1234 降成等值 join，因引擎无 `CROSS_PRODUCT`） | 同法；1 行侧来自 `ASSERT_NUM_ROWS_NODE` |
| `AGGREGATION_NODE` | 全部 | 一阶段 ✅ dev；两阶段 #1709 | `is_first_phase`/`need_finalize` → `agg_phase::classify`；`intermediate_tuple_id` 的 AGG_STATE 是 Doris 内部编码——**不翻译它**，两端都是 Sirius，partial state 用 Sirius 自己的格式（SR 同法） |
| `SORT_NODE` | order by / top-N | ✅ dev（全局 top-N） | `merge_by_exchange` 侧照常 `SortRel`+`FetchRel`；merging exchange 在接收侧重排 |
| `SELECT_NODE` | HAVING（Q11/Q22）、exchange 上的过滤 | ✅ dev | `FilterRel` |
| `ASSERT_NUM_ROWS_NODE` | 非相关标量子查询（Q11/Q15/Q22） | SR 未列（StarRocks 不同形） | 直通（信任 FE；TPC-H 的子查询都是聚合，恒 1 行） |
| `UNION_NODE`（常量一行关系） | 少见 | 引擎支持 `virtual_table`（`GPU_VALUES`） | → `VirtualTable`；多子 `SetRel` 拒绝（消费端 ≤2） |
| `MATERIALIZATION_NODE` / `LOCAL_EXCHANGE_NODE` | 由 §3.3 参数关掉 | — | 拒绝并报错指名 |
| `EMPTY_SET_NODE`、`ANALYTIC_EVAL`、`REPEAT`、`TABLE_FUNCTION`、`PARTITION_SORT`、`BUCKETED_AGGREGATION`、`REC_CTE_*` | TPC-H 不出现 | — | 拒绝 |
| 节点级 `projections` + `output_tuple_id` | Doris 没有 `PROJECT_NODE`，投影挂在节点上 | SR 的 `PROJECT_NODE`+`common_slot_map` | 每个节点翻译完追加 `ProjectRel`（`origin/doris` 的 `apply_node_projections`） |

**Sink**：`DATA_STREAM_SINK`（`UNPARTITIONED` 广播/汇聚、`HASH_PARTITIONED` shuffle、`RANDOM`）、`RESULT_SINK`（MySQL）。`BUCKET_SHFFULE_HASH_PARTITIONED` 只在内表出现（非目标）。

**表达式**（`TExprNodeType`）：`SLOT_REF`、`INT/FLOAT/DECIMAL/STRING/DATE/BOOL/NULL_LITERAL`、`BINARY_PRED`、`COMPOUND_PRED`、`ARITHMETIC_EXPR`、`FUNCTION_CALL`、`CAST_EXPR`、`CASE_EXPR`、`IN_PRED`、`IS_NULL_PRED`、`LIKE`（Doris 是 `FUNCTION_CALL` 名 `like`/`not like`）。
master 新增 `PREDICATE=43`、`LITERAL=44`（`Exprs.thrift:92-94`）——**要核实 Nereids 现在是否用它们代替旧枚举**。
TPC-H 用到的函数：比较/布尔/算术、`like`（Q2/9/13/14/16/20，含 `%x%y%` 多通配）、`substring`（Q22，常量参数）、`year`（Q7/8/9，`extract` 在 FE 已成 `year()`）、`case`、`in`、`between`（FE 已拆成 `>=`/`<=`）、日期字面量运算（FE 常量折叠）。
全部落在 Sirius 29 个函数内。

**类型**：TPC-H parquet 经 `fetch_table_schema` 推断为 `BIGINT/INT`、`DECIMAL(15,2)`（DECIMAL64）、`DATEV2`、`TEXT`——全部在 Sirius 支持范围。
拒绝表沿用 `semantics-gaps.md` G-01～G-18。

**Doris 4.0.3-rc03 → master 的 thrift 漂移**：29 文件 +2004/−298；核心契约（心跳、`PExecPlanFragmentRequest`、`TPipelineFragmentParamsList`、`fetch_data`、`TResultBatch`、`TPlanFragment`、`TScanRangeLocations`、`TFileScanNode`）**未变**；
新增 `LOCAL_EXCHANGE_NODE`(38)、`BUCKETED_AGGREGATION_NODE`(37)、`TExprNodeType.PREDICATE/LITERAL`、`THashJoinNode` ASOF、RF 只剩 `rid_to_target_paramv2`、`TQueryOptions` 176–232。
thrift 跳过未知字段，4.0.3 的解码器仍能读 master 的计划。**目标版本建议 4.1.3 / 4.1.4-rc04**（release 线，契约与 master 相同）。

### 3.5 分布式执行设计

三步递进，每一步的产物都是完整可验证的：

**MVP-A0 · 单节点、单计划（零引擎依赖）**
- 一个 BE 收到查询全部 fragment（一个 RPC，顶层在前）。翻译器把 fragment 树**拼回一棵 Substrait 树**：`EXCHANGE_NODE(node_id)` 处接入发送方 fragment 的 Rel（加一层 `ProjectRel` 对齐 exchange 的输出 tuple 布局）；
  两阶段聚合合并成一阶段 `AggregateRel`（`origin/doris` 的 `test_aggregation_two_phase_collapse` 就是这个）；merging exchange 变普通 `SortRel`；`DATA_STREAM_SINK` 消失。
- 走 `dev` 现成的 `Context::execute_substrait`，结果注册到 `RESULT_SINK` fragment 的 key 下供 `fetch_data`；其它 fragment instance 只需 ACK。
- 优点：不依赖 #1697/#1702/#1590，翻译器的每一个分支都被 22 条查询覆盖到；DuckDB 对整棵树自由优化（stream 基数为 1 行的问题不存在）。
- 代价：不验证 exchange/两阶段路径；`origin/doris` 曾因「slot 链跨 fragment 断裂」在 04-09 放弃 merge——但那是启发式翻译器；SR 式结构化翻译器（每个 Rel 记录 `row_tuples`/`output_width`）能正确做到。

**MVP-A · 单节点、真 fragment（store-and-forward）**
- 按 FE 拓扑执行：receiver-first 注册 exchange stream → 叶子 fragment `build()`+`run()` → 输出 parked → 上游 fragment `declare_input_*` + `relay_from` → `run()` → … → 结果 fragment `result_to_arrow`。
  这正是 aocsa T4b/T4c 的设计（`DestinationRoute::Local`），SR fork 里就是这么跑的。
- 两阶段聚合按 FE phasing 翻译（`agg_phase::classify` + `partial_state` 线上类型，照搬 #1709/#1711 的代数：count→sum、avg→sum+count、decimal sum 线上 DOUBLE）。
- merging exchange：接收侧 `SortRel` 重排（#1708 同法）；`per_exch_num_senders` → `declare_input_sender`；`close_input` 做 EOS。
- 依赖：#1697 + #1702（各 ≈100/900 行，可本地 patch）。仍是一个 Context、一次一个 fragment、`run()` 阻塞——对单节点正确性验证足够。

**MVP-B · 多节点、一 GPU 一 BE**
- 拓扑：同一主机多 BE（`127.0.0.n` 别名 + 端口偏移，`origin/doris` 的 `start-cluster.sh`）或多主机；每 BE 一个 GPU（`--gpu-device` + 显存/内存切分，#1714）。
- FE 把 `destinations{brpc_server}` 交给发送方 fragment；`brpc_server` 的 host:port 与自身相等 → Local（`relay_from`），否则 Remote。
- Remote 传输三选一：
  1. **复用 aocsa 链路**（首选）：`export_packed` → staging lease → NIXL WRITE → `transmit_packed`（三个私有 RPC）。Doris 侧不需要 patch `PBackendService`——BE↔BE 私有，直接在自己的 proto 里定义同样三个 RPC 挂在 `brpc_port`。前提：T5b/T6 上游（无时间表）或直接在 fork 上构建。
  2. **过渡**：Arrow IPC over gRPC → 接收侧 `push_arrow`（#1724 原型）。实测 0.28 GB/s vs NIXL 48–56 GB/s，只够 SF1–SF10 正确性。
  3. **不做**：Doris PBlock/`transmit_block` 互通——只有混合原生 BE 的集群才需要，非目标。
- 分区 hash：全 Sirius 节点 + TVF（无 bucket shuffle）→ 只要所有 sender 一致即可，用 sink 自带的 murmur3；**不需要**对齐 Doris 的 crc32/xxhash（`origin/doris` 的 `hash_partitioner.rs` 留着以备混合集群）。
- EOS/完成：`per_exch_num_senders` + 每 sender 一条 EOS 控制帧；卡死靠 #1699 watchdog。
- 已知会撞上的墙（SR fork 已撞过）：arena 耗尽（q09/q21 大 SF）、parked output 泄漏、无 cancel、传输单线程、stream 基数（#1694）。

### 3.6 runtime filter 处置

1. **事实**：Doris 只对 `canPushDownRuntimeFilter()==true` 的 scan 生成 RF；`PhysicalTVFRelation` 返回 false → **TVF 路径没有 RF**；Hive/Iceberg catalog 表有（`PhysicalCatalogRelation`）。
   `runtime_filter_mode=OFF` 让 `RuntimeFilterGenerator` 整个跳过（但 `runtime_filter_merge_addr` 仍会填，无害）。TopN filter 同样排除 TVF。
2. **MVP-A/A0/B**：不实现。TVF 路径零代价；catalog 路径 OFF 后损失的是 build 侧对 `lineitem`/`orders` probe 的裁剪（Q3/5/7/8/9/10/12/17/18/20/21 受益），是带宽/扫描成本，不是正确性。
   aocsa 的 CN 也是「FE 规划、CN 忽略」。
3. **引擎已有的等价物**：Sirius 的 dynamic filter（join build → 同计划内 parquet scan 的 IN-list/bloom/zone-map 裁剪）在 broadcast join 所在的 probe fragment 内自动生效
   ——但 producer 要求 build 侧「完整一批到达」，stream 输入是否触发**待 GPU 实测**。
4. **将来若要「支持 RF」**（catalog 路径性能对齐）：在我们的 BE 之间私有实现 merge（`send_filter_size`/`sync_filter_size`/`merge_filter`/`apply_filterv2` 语义），
   然后把合并结果**以静态谓词改写进消费方 fragment 的 Substrait**（IN-list → `in_list`，min-max → `BETWEEN` → cuDF row-group 裁剪；bloom 无对应，退化为 IN/min-max）——
   因为引擎没有可注入的 dynamic filter API。store-and-forward 下消费方 fragment 本来就在生产方之后 `build()`，RF 天然可用；到了流水线执行才需要 `runtime_filter_wait_time_ms` 语义。

### 3.7 复用矩阵

| 模块 | 来源 | 可复用度 | 估算（新写/改写行数） |
|---|---|---|---|
| thrift/proto 代码生成（Doris 4.1.x 全部 `.thrift` + `internal_service/data/descriptors/types.proto`） | `origin/doris` `doris-thrift/build.rs`、`doris-proto/build.rs` | 直接搬 | 0.2k |
| 心跳 thrift 服务、BackendService 桩、FE 自注册（MySQL）、可选 report | `origin/doris` `heartbeat_service.rs`/`backend_service.rs` + SR `lib.rs` | 搬 + 改 | 0.6–0.8k |
| gRPC `PBackendService`（tonic）：exec/prepare/start、cancel、fetch_data、fetch_table_schema、glob、其余 unimplemented | `origin/doris` `deserialize_params`、`fetch_table_schema`、`glob`；结构照 SR `compute_node_service.rs` | 部分搬 | 1.5–2k |
| 翻译器 crate `doris-plan-translator`：cursor/descriptor/type/expr/node/sink 提取/fragment 拼接（A0）/exchange-as-stream + 两阶段（A） | 结构照 SR（含 #1708–#1713 的 `agg_phase`/`partial_state`）；`type_mapper`、字面量、join 映射、`scan_translator`、节点投影搬 `origin/doris` | 逻辑可搬 ≈1.5k | 5–6k + 测试 3–4k |
| 引擎 seam：A0 用 SR `engine.rs`（专用线程 + `execute_substrait`）；A/B 用 `Fragment` 生命周期（T4b 设计） | SR dev；#1702 | A0 直接搬 | 0.4k + 1k |
| fragment 调度（receiver-first、dispatch worker、Local/Remote 路由） | 设计照 aocsa T4c（未开 PR，fork 有） | 需自写 | 1–1.5k |
| 结果：Arrow → MySQL 行 → `TResultBatch`(TBinary) → `PFetchDataResult`；`query_id` 键、挂起等待、`packet_seq` | SR `result_encoder.rs`/`result_store.rs` + #1715 失败传播 | 搬 + 改 | 0.5k |
| schema 推断：parquet footer → `PTypeDesc` | SR `file_schema.rs` + `origin/doris` 解码 `TFileScanRange` | 搬 + 改 | 0.4k |
| MVP-B 传输 | aocsa T5b/T6（fork ≈7k）或 Arrow-over-gRPC + `push_arrow` | 取决于上游 | 0（复用）/ 1k（过渡） |
| 测试与工具：TPC-H runner、DuckDB 差分验证、集群脚本、fragment dump / translate-only | `origin/doris` scripts（0.9k）、SR #1108 | 搬 | 0.5k |
| pixi 环境：Doris FE 构建（Maven + thrift 0.16）、GPU 环境 | `origin/doris` pixi.toml、SR pixi.toml | 搬 + 改 | 0.2k |
| **合计** | | | **≈10–13k（含测试），其中 ≈3–4k 直接搬** |

### 3.8 分期、验收与工作量

| 阶段 | 内容 | 验收 | 依赖 | 估算 |
|---|---|---|---|---|
| **P0 脚手架**（2 周） | `experimental/doris/` 工作区、codegen、心跳 + gRPC 壳、`fetch_table_schema`/`glob`、fragment dump + translate-only、FE 参数集 | FE 认 BE alive；`SELECT * FROM local(...)` 的 fragment 落盘；22 条 TPC-H 语料齐全（对应 `tasklist.md` M0.1/M0.2，两轨共享） | 无 GPU 也能做 | 1 人 |
| **P1 翻译器**（3–4 周） | 节点/表达式/类型/sink 提取 + 单测；fragment 拼接（A0） | 22 条查询全部翻出 Substrait，`substrait-explain` 人工核对；负向用例覆盖 G-01～G-18 | 无 GPU 也能做 | 1–2 人 |
| **MVP-A0**（2 周） | `execute_substrait` 端到端、`fetch_data`、差分验证 | **22/22 在 GPU 上与 Doris CPU 结果一致**（decimal 容差 1e-5；Q15 若因 FP64 等值不稳定要记录）；SF1 + SF10 | **GPU 机器**；`dev` 即可 | 1 人 |
| **MVP-A**（3–4 周） | `Fragment` 生命周期、store-and-forward 调度、exchange-as-stream、两阶段聚合、merging exchange | 22/22 按 FE 拓扑逐 fragment 执行，结果同上；对比 A0 的 per-query 时间 | #1697 + #1702（或本地 patch） | 1–2 人 |
| **MVP-B**（4–6 周 + 上游） | 多 BE、Remote 路由、传输（过渡 Arrow 或复用 packed/NIXL）、一 GPU 一 BE | SF100 在 2–4 GPU 上 22/22；有第一份可对外的数字（沿用对方 deck 的 break-even 框架） | T5b/T6 上游 或 fork | 1–2 人 |

总计到 MVP-A 约 3 个月（1–2 人 + 一台 GPU 机器）；MVP-B 的时间主要不在我们手里。

### 3.9 风险登记

| 风险 | 影响 | 缓解 |
|---|---|---|
| 引擎侧 4 个阻断项的合并节奏（#1697/#1702/T5b/#1590） | MVP-A/B 延期 | A0 不依赖；A 可本地 patch 两个小 PR；B 先做过渡传输 |
| decimal→FP64 漂移 | TPC-H 金额列末位不一致、Q15 等值不稳定、top-N 顺序抖动（SR 已发生） | 验证用容差；跟进 #1687/#1688；引擎透明路径 DECIMAL64/128 本身可用，翻译器后续改原生 decimal |
| `count(DISTINCT)`（Q16）的 FE phasing | 若 FE 用 `multi_distinct_*` 中间态则不可跨 exchange | A0 合并成一阶段；A/B 需确认 FE 能否规划成 group-by 形态（待核实 session 变量） |
| Doris 4.1 → master 新表达式枚举（`PREDICATE`/`LITERAL`）、`LOCAL_EXCHANGE_NODE` | 翻译器拒绝 | pin 4.1.x；参数关掉 local shuffle；语料先跑 translate-only |
| 单飞引擎：一个 Context 一次一个 fragment | 无查询并发；benchmark 只能串行 | 接受（对方 deck 也是串行）；#1303 线跟进 |
| 无 cancel、parked output 泄漏 | 长跑需重启 BE | harness 里 `RESTART_CMD`（SR 同法）；#1699 watchdog |
| GPU 机器（OQ-001） | A0 起所有验收都做不了 | 最高优先级确认 |
| 维护税：Doris 协议壳随版本漂移；两套翻译器（Rust/C++） | 长期成本 | ADR-011 写明定位是验证载体；共享语料与白名单 |
| 社区接纳：`experimental/doris/` 需要 sirius-integrations review | PR 长期 draft（aocsa 的 20 个就是先例） | 会上要 review 承诺；或先在 fork 迭代 |

### 3.10 未决问题

| 编号 | 问题 | 阻塞 | 处置建议 |
|---|---|---|---|
| OQ-001 | GPU 机器 | MVP-A0 起全部验收 | 会上索要或自购云机（对方 A100×8 $13.25/hr，开发用单卡即可） |
| OQ-006 | 落点：sirius `experimental/doris/` vs 独立仓库 | P0 | 倾向 `experimental/doris/`（对齐 SR、CODEOWNERS、CI 先例）；需 re-open #137 |
| OQ-007 | 是否等 T5b/T6 还是自建过渡传输 | MVP-B | 先做过渡（Arrow + `push_arrow`），拿到正确性；性能数字等 packed/NIXL |
| OQ-008 | Q16 的 FE phasing 与 `agg_phase` 语义 | MVP-A | P0 阶段用语料确认 |
| OQ-009 | Doris master 是否已用 `TExprNodeType.PREDICATE/LITERAL` | P1 | P0 阶段 translate-only 语料确认 |
| OQ-010 | 与 ADR-010 进程内路线的人力分配 | 两轨并行 | 会后定；P0 的语料与白名单两轨共用 |

---

## 附录 A · TPC-H 22 条逐条需求矩阵

「SR」列 = 对方 deck（SF500）/ 上游线 #1644（SF100，08-25）/ fork 最新；「Doris 要点」= 在 Doris 计划形状下需要额外注意的能力。

| Q | 计划要素（Doris Nereids over TVF） | 关键能力 | SR 记录 | Doris 要点 |
|---|---|---|---|---|
| 1 | 单表 scan + 过滤 + 两阶段 agg（sum/avg/count）+ sort | decimal 算术、两阶段 avg、日期字面量（FE 折叠） | deck 1.14×；上游线 ❌ 两阶段 avg → #1711 | A0 合并一阶段即过；A 需 avg 拆分 |
| 2 | 5 表 join + 相关标量子查询（min）→ join+agg；`like '%BRASS'`；top-N 100 | 多 join、like 后缀、merging exchange、字符串排序 | deck 7.38×；上游 ✅ | 无 |
| 3 | 3 表 join + agg + top-N 10 | decimal sum 排序 | deck 8.12×；上游漂移（top-N 顺序） | 容差验证 |
| 4 | `exists` → left semi join；count 分组 | semi join | deck 8.57×；上游 ✅ | 无 |
| 5 | 6 表 join + agg + sort | 多 join 内存 | deck 缺；上游漂移；SF10000 内存 | 无 |
| 6 | 单表 sum，between/decimal 过滤 | — | deck 2.68×；上游 ✅ | 无 |
| 7 | 6 表 join，OR 的 nation 对条件（非等值部分 → MIXED join / filter）；`year()`；agg；sort | MIXED join、year、stream 基数 | deck 2.75×，SF1000 卡死；上游 ❌ 300 s → #1699/#1694 | `year()` 返回 SMALLINT，线上类型对齐（#1704） |
| 8 | 8 表 join；`year()`；`case when`；sum/sum；sort | 同上 + FE 无统计 → join 顺序 | deck 缺；上游 ❌ `o_year` 类型 + arena；需改写 FROM 顺序 | Doris FE 对 TVF 同样无统计（待核实 `local()` 是否用文件大小估行数） |
| 9 | 6 表 join；`like '%green%'`；`year()`；agg；sort | like 中缀、每 fragment 内存 | deck 缺；上游 ❌；SF500 内存墙 | 同 8 |
| 10 | 4 表 join；7 列 group by；top-N 20 | — | deck 缺；上游漂移 | 容差 |
| 11 | 3 表 join + group by having (标量子查询) → `ASSERT_NUM_ROWS` + `CROSS_JOIN_NODE` + `SELECT_NODE`；sort | 标量子查询形态 | deck 9.79×；上游 ✅ | `ASSERT_NUM_ROWS` 直通；cross join 降等值 join |
| 12 | 2 表 join；`in` 列表；`case`；agg；sort | — | deck 6.47×；上游 ✅ | 无 |
| 13 | left outer join（ON 里 `not like '%special%requests%'`）；两级 agg；sort | outer join + 多通配 like | deck 4.50×；上游 ✅ | 无 |
| 14 | 2 表 join；`case when like 'PROMO%'`；sum/sum | 公共表达式 slot | deck 2.76×；上游 ❌ → #1704/#1713 | Doris 投影挂节点上，注意重复表达式 |
| 15 | CTE/视图 revenue0 用两次 + `= (select max)` → `ASSERT_NUM_ROWS` + join；sort | CTE 内联（关 materialize）、FP64 等值 | deck 缺；fork 1/3 概率空结果（FP64 等值） | 关 `enable_cte_materialize`；容差策略要定 |
| 16 | 2 表 join；`not in (subquery)` → null-aware left anti；`count(distinct)` 分组；`not like`、`in` | null-aware anti、count distinct phasing | deck 12.70×；上游 ✅ | **OQ-008**：FE 的 distinct phasing |
| 17 | 2 表 join + 相关标量子查询 avg → join+agg；sum/7 | 两阶段 avg | deck 5.05×；上游 ✅ 仅 `agg_stage=1` | 同 Q1 |
| 18 | 3 表 join + `in (group by having)` → semi join + agg；5 列 group by；top-N 100 | semi join over agg | deck 缺；上游 ✅（值相等）；SF100 跨次退化 | 无 |
| 19 | 2 表 join；3 组 OR 条件（等值 + 非等值/in/between） | MIXED join 复杂条件 | deck 3.13×；上游漂移 | 无 |
| 20 | 嵌套 `in` 子查询 + 相关标量 0.5*sum → semi join + join+agg；`like 'forest%'`；sort | 多层 semi | deck 3.67×；上游 ✅ | 无 |
| 21 | 4 表 join + `exists`（semi）+ `not exists`（anti）带 `l_suppkey <>` 非等值；count；top-N 100 | semi/anti MIXED join | deck 缺；上游 ✅；SF≥500 arena/600 s 卡死 | 无 |
| 22 | `substring(c_phone,1,2) in (...)`；标量子查询 avg → `ASSERT_NUM_ROWS`+cross；`not exists` → anti；agg；sort | substring 常量、anti join | deck 6.88×；上游 ✅ | 无 |

结论：**TPC-H 22 条在能力面上没有一条需要 Sirius 今天没有的算子**（无窗口、无集合运算、无 DISTINCT 投影）；难点集中在两阶段聚合代数、decimal 精度、线上类型对齐、大 SF 的内存/arena，
以及 Doris 特有的计划形状（`ASSERT_NUM_ROWS`、节点级投影、null-aware anti）。

## 附录 B · 引用清单

**sirius PR**：#816 #832 #852 #856 #914 #941 #960 #962 #1004 #1008 #1021 #1022 #1024 #1052 #1094 #1108 #1109 #1110 #1111 #1232 #1233 #1234 #1235 #1236 #1237 #1240 #1242
#1276 #1303 #1320 #1364 #1365 #1366 #1369 #1372 #1479 #1480 #1481 #1583 #1598 #1635 #1636–#1639 #1644 #1686 #1687–#1692 #1693 #1694 #1696 #1697 #1699 #1700 #1702 #1704 #1705 #1706 #1707
#1708 #1709 #1710 #1711 #1713 #1714 #1715 #1717 #1724。
**sirius issue**：#137 #826 #836–#841 #1276 #1303 #1590 #1635 #1687–#1692。
**fork 文档**（`github.com/aocsa/sirius`）：`feat/pin-table-cn`、`stream-fragment-execution`（`bench/PR-CLASSIFICATION.md`、`bench/TPCH-SWEEP-RESULTS.md`）、`demo-multi-cn`（`ROADMAP-8CN-TPCH.md`、`MULTI-CN-PLAN.md`、`TWO-CN-NIXL-DEMO.md`、`OPEN-ISSUES.md`）、
`demo/arrow-inprocess-io` @4b7f61f0（`docs/arrow-inprocess-io-demo.md`，本地副本在本次 session 的 scratchpad）。
**sirius 文件**：`src/include/sirius_ffi.hpp`、`src/sirius_ffi.cpp`、`src/planner/sirius_physical_plan_generator.cpp`、`src/expression/{function_id,aggregate_id}.cpp`、`src/include/cudf/cudf_utils.hpp`、
`docs/super-sirius/{streaming-sessions,streaming-fragments,dynamic-filters,multi-gpu-architecture}.md`、`experimental/starrocks/{src,crates}`、`substrait/src/from_substrait.cpp`。
**Doris 文件**（`wt-gpu` @ df36be5a）：`gensrc/thrift/{PaloInternalService,PlanNodes,DataSinks,HeartbeatService,BackendService,Exprs,Types}.thrift`、`gensrc/proto/{internal_service,data}.proto`、
`fe/.../system/{HeartbeatMgr,SystemInfoService,Backend}.java`、`fe/.../rpc/{BackendServiceClient,BackendServiceProxy}.java`、`fe/.../qe/runtime/{ThriftPlansBuilder,PipelineExecutionTaskBuilder}.java`、
`fe/.../qe/{ResultReceiver,SessionVariable}.java`、`fe/.../nereids/glue/translator/PhysicalPlanTranslator.java`、`fe/.../datasource/scan/{FileQueryScanNode,FederationBackendPolicy}.java`、
`fe/.../tablefunction/{ExternalFileTableValuedFunction,LocalTableValuedFunction}.java`、`fe/.../nereids/processor/post/RuntimeFilterPushDownVisitor.java`、`be/src/service/internal_service.cpp`、`be/src/runtime/fragment_mgr.cpp`、`be/src/core/block/block.cpp`。
**origin/doris**：`doris/{OVERVIEW,ARCHITECTURE,FINDINGS,BUILD_DEPLOY_TEST_GUIDE}.md`、`doris/crates/*`、`doris/scripts/*`、`doris/docker/*`。
