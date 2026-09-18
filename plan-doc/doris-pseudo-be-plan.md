# Doris 伪 BE 落地方案（参照 `experimental/starrocks`）

> **日期** 2026-09-18（第五次 session）
> **基线** sirius 本地 `dev` @ `e0080cd6`；`experimental/starrocks` 同一棵树（14.7k 行，其中测试 4.6k）；Sirius PR 现状 09-18 用 `gh` 逐个核实；
> Doris master @ `df36be5a`（`wt-gpu`），4.1.x 的 FE→BE 契约与 master 相同（`pseudo-be-feasibility.md` §3.4）。
> **与前文的关系** 本文是 `pseudo-be-feasibility.md`（09-09）的执行版：那份回答「可不可行、要多少事」，这份回答「怎么跑、改哪、在哪做、按什么顺序」。
> 可行性论证、Doris 最小 RPC 表（§3.2）、TPC-H 22 条矩阵（附录 A）不再重复，直接引用。
> **一句话** 不是把 Sirius 嵌进 `doris_be`，而是写一个 Rust 进程把 Sirius 包成一个 Doris BE 节点加入**原版** FE；Doris 代码零改动；
> Sirius 仓库新增 `experimental/doris/`；Mac 做协议壳和翻译器，AWS 一台单卡机做端到端。

---

## 0. 三个问题的直接回答

### 0.1 这个项目怎么跑：Sirius 是库，SR 的 CN 是「宿主进程 + 协议壳」

先澄清前提：**Sirius 不是一个能独立启动的服务。** 它的产物是一个 DuckDB 扩展 `sirius.duckdb_extension`（`rust/crates/sirius-sys/build.rs` 把它软链成
`libsirius.so` 来链接），对外只有一层很薄的 FFI：`SiriusContext::new()` / `from_config_file()` / `execute_substrait(&[u8]) -> Vec<RecordBatch>`
（`rust/crates/sirius/src/lib.rs:30-80`）。所以「把 siriusdb 启动后作为 BE 加入集群」这句话缺一个主语：**谁来启动它、谁来说 FE 的协议。**
`experimental/starrocks/` 就是这个主语——一个 Rust 二进制 `sirius-starrocks-cn`：

1. **在自己进程里链接 Sirius**（`src/engine.rs`）：一个专用线程持有 `!Send` 的 `SiriusContext`，其它线程通过 mpsc 把 Substrait 字节送进去、把 Arrow 批取出来。
2. **对 FE 伪装成一个 StarRocks Compute Node**：用 MySQL 协议 `ALTER SYSTEM ADD COMPUTE NODE "host:9050"` 自注册（`src/lib.rs:1188`）；
   thrift `HeartbeatService`（9050）回心跳；thrift `BackendService`（9060）24 个方法里 15 个直接 `NOT_IMPLEMENTED`；
   bRPC `PInternalService`（8060）只实现 4 个方法：`exec_plan_fragment`、`exec_batch_plan_fragments`、`fetch_data`、`get_file_schema`。
3. **收到 FE 的 thrift 计划后翻译成 Substrait**（`crates/starrocks-plan-translator`），交给引擎执行，Arrow 结果编成 MySQL 文本行塞进
   `TResultBatch`，等 FE `fetch_data` 拉走（`src/result_encoder.rs`、`src/result_store.rs`）。

FE 是**原版 StarRocks**（submodule 钉在 `branch-4.1.1`，从源码 build），只覆盖一份 `conf/fe.conf`：`run_mode = shared_data`、
`enable_load_volume_from_conf = false`、`default_replication_num = 1`、`priority_networks = 127.0.0.1/32`。集群里**没有原生 BE/CN**，全部节点都是这个 Rust 进程。

所以答案是：**第二种（作为 BE 节点加入），但「BE」是我们自己写的宿主进程；Sirius 作为库嵌在这个宿主进程里，而不是嵌进 Doris 自己的 `doris_be`。**
嵌进真 `doris_be` 是另一条路（`design.md` 轨 2 / ADR-010），`embeddability-study.md` 已证明它卡在 Sirius 侧没有可链接的 `libsirius`
（静态 libstdc++、C ABI、显存配额三件事），不在本文范围。

SR 现状的进程拓扑：

```
mysql client ─9030─▶ StarRocks FE（原版 Java，shared_data 模式）
                       │ thrift 心跳 9050 · thrift BackendService 9060（桩）
                       │ bRPC baidu_std 8060：exec_plan_fragment / exec_batch_plan_fragments / fetch_data / get_file_schema
                       ▼
             sirius-starrocks-cn（一个 Rust 进程）
               ├─ lib.rs                    自注册 · 心跳状态机（epoch/cluster_id/token 粘性）· 空 inventory report
               ├─ prpc.rs / brpc.rs         手写 PRPC 帧解析 + Tower 路由（build.rs 从 proto 生成 service facade）
               ├─ compute_node_service.rs   thrift attachment 反序列化 → 翻译 → 执行 → 缓冲；SIRIUS_CN_DUMP_FRAGMENTS / SIRIUS_CN_TRANSLATE_ONLY
               ├─ crates/starrocks-plan-translator   TPlanFragment（扁平先序）→ Substrait；(tuple_id, slot_id) 联合键
               ├─ engine.rs                 专用线程 + SiriusContext::execute_substrait（整计划进、整结果出）
               ├─ result_encoder.rs / result_store.rs   Arrow → MySQL 文本行（NULL=0xFB）→ TResultBatch（TBinary）→ packet_seq 0 → eos
               └─ file_schema.rs            parquet footer → PSlotDescriptor（FILES() 推断，单文件、仅本地路径）
                       │ cxx（rust/crates/sirius → sirius-sys → src/include/sirius_ffi.hpp）
                       ▼
             libsirius.so（= sirius.duckdb_extension）+ DuckDB 1.5.5 + cuDF/RMM   ← 同一进程
```

`dev` 上这个 CN 的能力边界（读码确认，不是看 deck）：

- 只执行带 `RESULT_SINK` 的 fragment；`DATA_STREAM_SINK` 的 fragment 翻译后直接丢（`compute_node_service.rs:277-291`）。
- 翻译器明确拒绝 `EXCHANGE_NODE`；聚合只收一阶段（FE 要 `SET new_planner_agg_stage = 1`）。
- 结果整体物化，`fetch_data` 一次交付（`result_store.rs` 是「单批、单轮询」模型，代码里自己写着 TODO）。
- 一个 Context 一次一个查询；`exec_plan_fragment` 在 `spawn_blocking` 上同步等引擎跑完才返回。

**即 `dev` 上是「单 fragment 查询」的 CN。** 分布式那一半在 aocsa 的在途 PR 里，见 §1.2——这决定了我们 MVP-A/B 的依赖。

### 0.2 两侧各改什么

| 侧 | 改动 | 量 |
|---|---|---|
| **Doris** | **代码零改动。** FE 用官方 4.1.x 二进制；一份 `fe.conf`；一组 session 变量把计划形状收敛（§2.2）；TPC-H 八张表用 `local()`/`s3()` TVF + `CREATE VIEW` 包装，TPC-H SQL 不改 | 配置 |
| **Sirius 仓库** | 新目录 `experimental/doris/`：Rust 伪 BE = 协议壳 + 翻译器 + 引擎 seam + 结果路径 + 脚本 + CI（§2.3） | ≈10–13k 行含测试；≈3–4k 直接从 `experimental/starrocks` 和 `origin/doris` 搬 |
| **Sirius 引擎** | MVP-A0：**零改动**（`dev` 的 `execute_substrait` 够用）。MVP-A/B：依赖 #1791（`Fragment` 重构）+ #1792 的 FFI 部分（`push_arrow/pull_arrow/close_input`、Rust `Fragment<'ctx>`），未合前可本地 patch（§2.4） | 0 / 跟上游 |

### 0.3 最小开发环境

- **Mac（现有，无 GPU）**：P0 协议壳、P1 翻译器、全部单测、FE 本地运行、22 条 TPC-H 的 fragment 语料——`--no-default-features` 不链接引擎，SR 的 CI 就是这么跑的。
- **AWS**：一台**单 GPU** 实例做 MVP-A0/A（推荐 `g6e.2xlarge`：L40S 48 GB；省钱 `g5.2xlarge`：A10G 24 GB）；MVP-B 换 `g6e.12xlarge`（4×L40S，4 个 BE 进程各占一卡）或两台单卡机跨主机。
  Ubuntu 22.04/24.04，NVIDIA 驱动 ≥ 580.65.06（否则用 `cuda12` 环境，驱动 ≥ 525.60.13），其余全由 pixi 装。Doris FE 用官方二进制，**不用编 Doris**。详见 §4。

---

## 1. `experimental/starrocks` 的实现要点与上游现状

### 1.1 值得照抄的设计（Doris 版全部沿用）

| 设计 | SR 的做法 | 为什么值得抄 |
|---|---|---|
| 引擎 seam | `FragmentExecutor` trait：`execute(&TranslatedPlan) -> FragmentResult{Vec<RecordBatch>}`；生产注入 `SiriusEngine`，测试注入 `StubExecutor`（造一行 `"stub"`） | 协议壳、翻译器、结果路径全部可以无 GPU 测；CI 只跑 `--no-default-features` |
| 引擎线程 | `SiriusContext` 只活在一个线程上，请求/响应走 `std::sync::mpsc`，`Drop` 先关 sender 再 join | `!Send`/`!Sync` 的 Context 与 tokio 多线程运行时并存的唯一正确姿势 |
| 翻译器结构 | 扁平先序 `TPlanNode` 列表用 cursor 重建树，`ensure_consumed` 不变式；每个 Rel 记录 `row_tuples`/`output_width`；结构化 `TranslateError` | Doris 的 `TPlan.nodes` 同样是扁平先序 + `num_children`，一模一样 |
| slot 键 | `(tuple_id, slot_id)` 联合键 | Doris 的 `slot_id` 同样只在 tuple 内唯一；SR 踩过两次（`15e8f6b8`、`1fd20963`） |
| 调试钩子 | `SIRIUS_CN_DUMP_FRAGMENTS`（thrift 参数 + Substrait 落盘）、`SIRIUS_CN_TRANSLATE_ONLY`（接受一切、只翻译不执行） | P0 采语料靠它；翻不出来的 fragment 也能让 FE 把整棵计划发完 |
| 结果编码 | Arrow → MySQL 文本行（length-encoded，NULL=`0xFB`）→ `TResultBatch` | Doris 的 `fetch_data` 就是同一套 MySQL 文本行，只是外层编码不同 |
| 构建/CI | pixi 三环境（`fe`/`cn`/`engine`），`engine-build` 复用仓库根 `pixi run make`；`experimental.yml` 只在 CPU runner 跑 fmt/clippy/test | 直接复制一份 `doris` job |

### 1.2 上游现状（09-18 核实，和 09-09 的判断不同）

09-09 那 20 个 draft PR（#1693–#1717）**已在 09-15 全部关闭、未合并**（#1697/#1702/#1708/#1709/#1711/#1714 …）。aocsa 改成三条**非 stacked** 的线，直接基于 `dev`：

| PR | 状态 | 内容 | 对我们的意义 |
|---|---|---|---|
| **#1791** `feat/fragment-refactor` | open，**非 draft**，+1018/−619 | `streaming_fragment` 自己拥有 query window（修了 `build()` 事务 bug，即原 #1697）；零 outputs = 结果 fragment（`take_result()`/`result_to_arrow()`），≥1 outputs = streaming sink（`pull()`/`relay_from()`）；「一次只能有一个 fragment 处于 build 与 run 之间」 | MVP-A 的引擎依赖从「#1697 + #1702」改为「#1791」 |
| **#1792** `feat/demo-transmit-chunk-arrow-shuffle` | open，draft，+13.3k | 完整的两 CN 分布式 demo：`sirius::ffi::Fragment::{pull_arrow, push_arrow, drained}` FFI + Rust `Fragment<'ctx>` 绑定；翻译器 `EXCHANGE_NODE → ReadRel(sirius_stream_<node_id>)` + 两阶段 `SUM` + `output_partition_columns`；`LocalExchange` rendezvous（同 CN `relay_from`，远端 Arrow IPC 走 `transmit_chunk`）；「先跑完所有本地叶子 → 交换 → 再 build/run 根」；2 个 MIG CN 上 `FILES() GROUP BY` 与 DuckDB 一致 | **这就是 09-09 说的「过渡传输」，现在成了 aocsa 自己的主线 demo**；对 Doris 伪 BE 是现成模板：Doris 版只需把 `transmit_chunk` 换成我们自己的 gRPC service |
| **#1794** `feat/group-by-nixl-shuffle` | open，非 draft（09-16） | 同一形状换成 NIXL + staging arena | MVP-B 的性能路径，等它合 |
| #1696 / #1700 / #1717 / #1704 | draft | byte-range 切分 ×3、`CLONE_EXPR` | 大文件跨节点切分要它们；MVP 期间用 `file_split_size` 绕开 |

三个仍然成立的约束：`Context` 单线程契约、`run()` 阻塞、一次一个 fragment。#1792 的 CN 用「重排执行顺序」（store-and-forward）绕过，我们也一样。

**`origin/doris`**（mbrobbel，2026-02 → 06-03，冻结）仍是最好的 Doris 侧素材库：它就是「Rust 伪 BE 加入原版 Doris 4.0.3-rc03 FE」，FE 侧的坑它踩过一遍。
但它的引擎耦合（`sirius-ffi` crate 走 legacy `gpu_buffer_manager` + 11 个 `sirius_*` 符号）在 `dev` 上一个都不存在，**只搬纯 Rust 部分**（§2.3 的「来源」列）。

---

## 2. Doris 版的目标形态

### 2.1 拓扑与 SR 的逐项差异

```
mysql client ─9030─▶ Doris FE 4.1.x（官方二进制，不改）
   │ thrift HeartbeatService（heartbeat_port）  → TBackendInfo{be_port, http_port, brpc_port, be_node_role="mix", be_start_time≠0}
   │ thrift BackendService（be_port）           → 周期 RPC 回 OK/空（get_tablet_stat 等）
   │ gRPC h2c PBackendService（brpc_port）      ← 与 SR 最大的差异：Doris FE 用 grpc-java，不用手写 PRPC，tonic 即可
   │     分析期：fetch_table_schema · glob        执行期：exec_plan_fragment(_prepare/_start) · cancel_plan_fragment · fetch_data
   ▼
sirius-doris-be × N（一 GPU 一进程）
   BE↔BE：私有 gRPC service 挂在同一 brpc_port（Arrow IPC 帧，语义照 #1792 的 transmit_chunk）；不做 PBlock/transmit_block 互通
```

| 项 | StarRocks CN（SR） | Doris BE（本方案） |
|---|---|---|
| 注册 | `ALTER SYSTEM ADD COMPUTE NODE "host:hb"`；FE 要 `shared_data` + 非零 `starlet_port` 才调度 | `ALTER SYSTEM ADD BACKEND "host:hb"`；普通模式；心跳 `be_node_role="mix"`（`computation` 会被 TVF 调度排除） |
| FE→BE 传输 | baidu_std（手写 490 行 PRPC 帧） | **gRPC h2c**（tonic，0 行框架代码） |
| 分发粒度 | 每 instance 一个 `TExecPlanFragmentParams`（TBinary attachment），或 batch | 一个 BE 的**全部** fragment 在一个 RPC：`PExecPlanFragmentRequest.request` = **TCompact** 的 `TPipelineFragmentParamsList`（VERSION_3，顶层 fragment 在前，只有首个带 `desc_tbl`/`file_scan_params`）；>1 fragment 时两阶段 `_prepare` + `_start` |
| 结果 key | `finst_id` | `enable_parallel_result_sink=false` 后是顶层 fragment 的 instance id；`packet_seq` 从 0 严格 +1 |
| 结果就绪 | 未就绪回错误 | **必须挂起不回**（真 BE 如此，FE 只等超时）；gRPC 无 attachment，行数据走 `PFetchDataResult.row_batch`（TBinary `TResultBatch`） |
| 表函数 | `FILES()` → `get_file_schema` | `local()`/`s3()`/`hdfs()` → `fetch_table_schema`（TBinary `TFileScanRange`）；`local()` 还会调 `glob`；**没有这两个 RPC，查询根本不会被规划** |
| runtime filter | FE 规划、CN 忽略 | TVF 路径 FE **根本不生成**（`PhysicalTVFRelation.canPushDownRuntimeFilter()==false`）；catalog 路径 `runtime_filter_mode=OFF` |
| 投影 | `PROJECT_NODE` + `common_slot_map` | 没有 `PROJECT_NODE`，投影挂在每个节点的 `projections` + `output_tuple_id` 上 → 每个节点翻译完追加 `ProjectRel` |
| 标量子查询 | — | `ASSERT_NUM_ROWS_NODE` + `CROSS_JOIN_NODE`（Q11/15/22）→ 直通 + 降等值 join |
| anti join | `outer + is_null` / `mark + not` | 多一种 `NULL_AWARE_LEFT_ANTI_JOIN`（Q16 `NOT IN`）→ mark join + `not` |
| 两阶段聚合 | `is_first_phase`/agg stage | `is_first_phase` + `need_finalize`；`intermediate_tuple_id` 的 AGG_STATE 是 Doris 内部编码，**不翻译它**，两端都是 Sirius 用自己的 partial state（SR 同法） |

### 2.2 Doris 侧：代码零改动，只有配置

**FE conf**（沿用 `origin/doris` 的 `docker/fe-custom.conf`，P0 时逐项确认哪些真的必需）：

```
priority_networks = <本机网段>
arrow_flight_sql_port = -1
enable_outfile_to_local = true
enable_access_file_without_broker = true
```

**Session 变量**（来源 `SessionVariable.java`，固化成 `sql/session.sql`，每个连接先执行）：

| 变量 | 值 | 作用 |
|---|---|---|
| `parallel_pipeline_task_num` | 1 | 每 BE 每 fragment 一个 instance；也抑制 `LOCAL_EXCHANGE_NODE` |
| `enable_local_shuffle_planner` | false | FE 不插 `LOCAL_EXCHANGE_NODE`（master 新增节点类型 38） |
| `enable_parallel_result_sink` | false | 结果收敛到一个 gather fragment，`fetch_data` 单点 |
| `runtime_filter_mode` | OFF | 兜底（TVF 路径本来就没有） |
| `file_split_size` | 1 TB 量级 | 每文件一个 split（引擎消费端忽略 byte range，#1696/#1700 未合） |
| `topn_lazy_materialization_threshold` | -1 | 不出现 `MATERIALIZATION_NODE` |
| `enable_cte_materialize` | false | Q15 的 `WITH` 不走 `MULTI_CAST_DATA_STREAM_SINK` |
| `enable_fold_constant_by_be` / `enable_profile` | 保持 false | 避免 `fold_constant_expr` RPC |
| `query_timeout` | 3600 | 大 SF |

**数据入口**（**已决 D-4 → ADR-011**）：`local()` + `shared_storage=true`：FE 通过一个 BE 的 `glob` 列文件并把文件分给多个 BE
（`LocalTableValuedFunction.java:52-87`），所以 `glob` RPC 必做；`s3()`/`hdfs()` 不在 MVP 范围。注意 `local()` 要求每个 BE 在**同一路径**
看到同一批 parquet：同机多 BE 天然满足；MVP-B 跨主机时优先每机一份（Sirius 要求 parquet 所在文件系统支持 `O_DIRECT`，网络盘要先验证）。
TPC-H 表用视图包装，22 条 SQL 一字不改：

```sql
CREATE VIEW tpch.lineitem AS SELECT * FROM local(
  "file_path" = "tpch/sf1/lineitem/*.parquet", "format" = "parquet", "shared_storage" = "true");
```

**将来可选的 Doris 上游改进**（不阻塞任何 MVP，属于轨 2 / 长期）：FE 对 TVF 的行数估计（避免 Q8/Q9 的 cross-join 计划）；
BE tag / resource group 让 GPU BE 与原生 BE 混部；可注入的 runtime filter 接口。

### 2.3 Sirius 仓库侧：`experimental/doris/` 的模块清单

目录对齐 SR（CODEOWNERS 里 `/experimental/` 已有 `sirius-integrations` 组，`experimental.yml` 有无 GPU 的 CI 先例）：

```
experimental/doris/
├── Cargo.toml / build.rs / pixi.toml / conf/fe.conf / sql/{session.sql,tpch-views.sql}
├── doris/                          ← 浅 submodule，apache/doris @ 4.1.x tag（只用 gensrc/thrift + gensrc/proto）
├── crates/doris-thrift/            ← thrift --gen rs
├── crates/doris-proto/             ← prost + tonic-build（PBackendService + 我们的私有 exchange service）
├── crates/doris-plan-translator/   ← TPipelineFragmentParams → Substrait
├── src/{main,lib,node,backend_service,params,engine,fragment_executor,result_encoder,result_store,file_schema}.rs
├── src/{local_exchange,arrow_exchange,parked_registry}.rs   ← MVP-B（照 #1792）
├── scripts/{start-cluster.sh,run-tpch.sh,validate_tpch_results.py}
└── tests/fixtures/tpch/qNN/{fragment-*.txt,plan-*.substrait,explain.txt}   ← P0 语料
```

| 模块 | 职责 | 来源 / 复用度 | 估算 |
|---|---|---|---|
| `doris-thrift` `build.rs` | Doris 全部 `.thrift` → Rust（thrift 0.24 crate） | `origin/doris:doris/crates/doris-thrift/build.rs` 直接搬（与 SR 的 `starrocks-thrift/build.rs` 同构） | 0.2k |
| `doris-proto` `build.rs` | `internal_service/types/descriptors/data.proto` → prost；`PBackendService` → tonic server trait；私有 `SiriusExchange` service | `origin/doris:doris/crates/doris-proto/build.rs` 搬；**不需要** SR 的 `BrpcServiceGenerator`（那是替代 tonic 的） | 0.2k |
| `src/node.rs` | `ALTER SYSTEM ADD BACKEND` 自注册 + 重试；`HeartbeatService` handler（`TBackendInfo`）；`BackendService` 桩 | SR `lib.rs` 的结构（注册重试、心跳状态、优雅关停）+ `origin/doris` `heartbeat_service.rs`/`backend_service.rs` 的 Doris 字段 | 0.6–0.8k |
| `src/backend_service.rs` | tonic `PBackendService`：`fetch_table_schema`、`glob`、`exec_plan_fragment(_prepare/_start)`、`cancel_plan_fragment`、`fetch_data`；其余 ~46 个 `unimplemented` | 结构照 SR `compute_node_service.rs`；`fetch_table_schema`/`glob` 搬 `origin/doris` `grpc_service.rs` | 1.5–2k |
| `src/params.rs` | `PExecPlanFragmentRequest.request` → TCompact `TPipelineFragmentParamsList`；VERSION_3 共享字段（`desc_tbl`/`file_scan_params`/`coord`）合并到每个 fragment；prepare/start 状态机；dump + translate-only 钩子 | `origin/doris` `deserialize_params` + SR 的 `SIRIUS_CN_*` 钩子 | 0.4k |
| `doris-plan-translator` | 描述符表 / 类型 / 表达式 / 节点 / sink 提取；A0 的 fragment 拼接；A 的 exchange-as-stream + 两阶段聚合 | 结构照 SR（含 #1792 的 `agg_phase.rs`、`sirius_stream_<node_id>`）；`type_mapper`、字面量/decimal 编码、join 映射、`scan_translator`、节点级投影搬 `origin/doris` `plan-translator` | 5–6k + 测试 3–4k |
| `src/engine.rs` + `fragment_executor.rs` | A0：SR 原样（专用线程 + `execute_substrait`）；A/B：`Fragment` 生命周期（declare inputs/outputs → build → 填输入 → run → drain） | SR verbatim；A/B 照 #1791/#1792 的 FFI | 0.4k + 1k |
| `src/result_*.rs` | Arrow → MySQL 文本行 → `TResultBatch`（TBinary）→ `PFetchDataResult.row_batch`；**挂起等待**；`packet_seq`；失败传播到结果 instance | SR verbatim + 改外层编码 + 加 `tokio::sync::Notify` 等待 | 0.5k |
| `src/file_schema.rs` | parquet footer → `PTypeDesc` 列表；`glob` | SR `file_schema.rs`（Doris 版还要 `TFileScanRange` 解码；多文件取首个非空） | 0.4k |
| `src/{local_exchange,arrow_exchange,parked_registry}.rs` | MVP-B：receiver-first rendezvous、Local（`relay_from`）/ Remote（Arrow IPC over 私有 gRPC）路由、EOS 计数 | #1792 三个文件改 RPC 壳 | 1–1.5k |
| `scripts/` + `tests/` | 集群起停（`127.0.0.n` 别名 + 端口偏移）、TPC-H runner、DuckDB 差分 | `origin/doris:doris/scripts/*`（0.9k）搬 | 0.5k |
| `pixi.toml` + CI | `fe`（**下载官方 tarball**，不编 Doris）/ `be` / `engine` 三环境；`experimental.yml` 加 `doris` job（`--no-default-features`） | SR `pixi.toml` 改（注意 SR 的 `engine` feature 钉 `libcudf 26.06.*`，仓库根已是 `26.08.01`，以根为准） | 0.2k |
| **合计** | | | **≈10–13k 含测试** |

### 2.4 Sirius 引擎侧：分阶段的依赖

| 阶段 | 引擎侧需要什么 | 现状（09-18） | 未合时的处置 |
|---|---|---|---|
| **MVP-A0** | `Context::execute_substrait`（整计划）| `dev` 已有 | 无依赖 |
| **MVP-A** | `ffi::Fragment`：`declare_input_stream/sender` → `build()` → `relay_from` → `run()` → `take_result`；Rust 绑定 | #1791（非 draft，可 review）；Rust `Fragment<'ctx>` 在 #1792 的 commit `891d41c3` | 本地 cherry-pick 这两块（≈1k 行） |
| **MVP-B** | 外部数据入口 `push_arrow/pull_arrow/close_input(stream, sender)` | #1792 的 commit `d7f2a7e3`；性能路径 #1794（NIXL） | 先 cherry-pick Arrow 路径拿正确性；NIXL 等上游 |
| 长期 | 并发 Context（#1303）、非阻塞 `run()`（#1590）、`cancel`、decimal 原生表达式（#1687/#1688）、背压（#1276 决定不做） | 均未合 | 不阻塞 MVP；harness 里保留 `RESTART_CMD` |

引擎侧不需要我们改代码，但需要三个**社区动作**：re-open #137（06-10 关闭时明说欢迎 re-open）；`experimental/doris/` 的 PR 找 `sirius-integrations` 要 review 承诺；
在 #1590 回帖说明 Doris 伪 BE 会以 #1791/#1792 的 FFI 为契约。

---

## 3. 分期与步骤

原则：**每一步的产物都能单独验收；GPU 只在 MVP-A0 之后才是硬需求。** 到 MVP-A 约 3 个月（1–2 人）；MVP-B 的时间主要取决于 #1792/#1794 的合并节奏。

### 3.0 MVP-A0 与 MVP-A 的区别：「拼回一棵树」vs「真 fragment」

FE 不会把一条 SQL 当成一棵树发给 BE。Nereids 先把物理计划切成若干 **plan fragment**：每个 fragment 是一段不跨网络的子树，
fragment 之间用 exchange 连接，即下游 fragment 的 `DATA_STREAM_SINK`（hash / broadcast / 汇聚）把行送到上游 fragment 的 `EXCHANGE_NODE`。
切在哪、怎么分区、聚合拆不拆成两阶段、哪个 BE 跑哪个 fragment instance，都是 FE 定的。BE 收到的是「本机要跑的那几个 fragment」。

以 `SELECT l_returnflag, sum(l_quantity) FROM lineitem GROUP BY l_returnflag` 为例，FE 通常切成两到三个 fragment
（#1792 在 2 CN 上实测是三个：leaf / merge / gather；Doris 的确切形状 P0 采语料时确认）：

```
F2 leaf    FILE_SCAN(lineitem) → AGG 第一阶段 [partial sum]        → DATA_STREAM_SINK hash(l_returnflag) ──▶ EXCHANGE 3
F1 merge   EXCHANGE_NODE 3 → AGG 第二阶段 [merge, finalize]        → DATA_STREAM_SINK unpartitioned    ──▶ EXCHANGE 5
F0 gather  EXCHANGE_NODE 5 → RESULT_SINK
```

**MVP-A0 把 FE 的 fragment 只当翻译输入。** 单节点时三个 fragment 都落在同一个 BE 的同一个 RPC 里，翻译器从 F0 的 `RESULT_SINK` 往下走，
遇到 `EXCHANGE 5` 就接入 F1 的子树，遇到 `EXCHANGE 3` 就接入 F2 的子树，两层 AGG 合成一层，`DATA_STREAM_SINK` 消失，merging exchange 变普通 `SortRel`，
最后得到**一棵** Substrait：`Read(lineitem) → Aggregate(sum by l_returnflag) → Root`。执行走 `dev` 现成的 `SiriusContext::execute_substrait`，
和今天 SR 的 CN 一模一样；结果登记在 F0 的 instance id 下，F1/F2 的 instance 只回 OK。FE 以为自己派了三个 fragment，实际引擎跑的是一条融合后的查询。

**MVP-A 把 FE 的 fragment 当执行单元，这就是「真 fragment」。** 每个 FE fragment 对应引擎里一个 `ffi::Fragment`（#1791 之后即 `streaming_fragment`）：
有自己声明的输入流 / 输出流、自己的 build/run 生命周期、自己的输出缓冲；`EXCHANGE_NODE` 翻成对命名流 `sirius_stream_<node_id>` 的 `ReadRel`
（引擎里是 `STREAMING_SOURCE`），`DATA_STREAM_SINK` 翻成声明的输出流（`STREAMING_SINK` + hash/broadcast 分区）。BE 端维护一张
「输出流 id ↔ 输入流 id」的路由表，引擎本身不知道集群存在。因为引擎一次只能有一个 fragment 处于 build 与 run 之间、且 `run()` 阻塞，
同一 BE 上按依赖顺序串行执行（store-and-forward）：

```
F2: Read(lineitem) → Aggregate(partial sum)     outputs: stream 3 (hash by l_returnflag)
    build() → run() → 输出批 parked 在引擎里
F1: Read(sirius_stream_3) → Aggregate(merge)    inputs: stream 3（1 个 sender）  outputs: stream 5
    declare_input_stream(3, senders=1) → build() → relay_from(F2 的输出，同进程指针搬运) → close_input → run() → parked
F0: Read(sirius_stream_5) → Root                inputs: stream 5  outputs: 无 → 结果 fragment
    build() → relay_from(F1 的输出) → run() → take_result() → Arrow → fetch_data
```

两阶段聚合按 FE 的 phasing 翻译：第一阶段吐 partial state（sum→sum、count→sum、avg→sum+count、decimal sum 线上是 DOUBLE），第二阶段 merge；
两端都是 Sirius，partial state 用 Sirius 自己的线上类型，不碰 Doris 的 AGG_STATE 编码。

| | MVP-A0 | MVP-A |
|---|---|---|
| FE 的 fragment 是什么 | 翻译输入，拼回一棵树 | 执行单元，一比一对应引擎 `Fragment` |
| 引擎 API | `execute_substrait`（`dev` 已有） | `Fragment`：declare → build → relay_from/push → run → take_result（#1791 + #1792 的 Rust 绑定） |
| 引擎依赖 | **无** | #1791 未合则 cherry-pick |
| 验证了什么 | 翻译器对 22 条的节点/表达式/类型覆盖、协议壳、结果路径、引擎能不能跑这些形状 | 额外验证：exchange-as-stream、线上类型对齐（SR 的 `o_year` SMALLINT/BIGINT）、两阶段聚合代数、merging exchange、每 fragment 内存、stream 基数对优化器的影响（#1694）、失败传播 |
| 验证不了什么 | 任何与 fragment/exchange/分布式有关的东西 | 并行（同 BE 内串行）、流水线、网络（都是 B 或更后） |
| 能否多节点 | 不能：一条查询的 fragment 分散在多个 BE 时无法拼 | 能扩展：B = A + Remote 路由（parked 输出 → Arrow IPC → 对端 `push_arrow`） |
| 可丢弃的代码 | 拼接器 ≈ 0.5–1k 行 | 无 |

**为什么先做 A0 再做 A，而不是直接做 A**：A 的引擎依赖还没合并（#1791 非 draft 但 open；Rust 绑定只在 study PR #1792 里），而翻译器是整个项目最大、
风险最集中的一块（5–6k 行）。A0 让翻译器风险和引擎变动解耦，用零依赖的路径最快拿到「22/22 在 GPU 上正确」。A0 的产物之后也不废：
它是 A 的调试工具（任何一条查询都能退回单计划复现）和性能上界（一条融合计划由 DuckDB 全局优化 vs 按 FE 切分 store-and-forward，差值就是 FE 切分的代价，
benchmark 叙事要用）。拼接器里最难的一点是把第二阶段聚合引用的中间 slot 映射回第一阶段的输入列，`origin/doris` 的
`test_aggregation_two_phase_collapse` 是先例。**A 不能跳过**：B 只是在 A 的路由表上加一个 Remote 分支，调度器（receiver-first、EOS 计数、parked 登记、失败传播）全在 A 里无网络地建好。

### P0 · 脚手架（≈2 周，Mac 可做）← **已完成 2026-09-18（一个 session）**

验收：官方 FE `SHOW BACKENDS` 里我们的 BE `Alive=true` 持续 ≥ 10 分钟；`SELECT * FROM local(...) LIMIT 1` 能被规划并把 fragment 发到我们这里；
22 条 TPC-H（SF1 parquet）的 fragment + Substrait 全部落盘成语料；OQ-008（Q16 `count(distinct)` phasing）、OQ-009（master 是否已用 `TExprNodeType.PREDICATE/LITERAL`）有答案。

> **09-18 实测结果**：全部通过（Substrait 一项顺延到 P1——P0 的翻译器是骨架，语料是 FE 原始派发 `.tcompact`）。Doris pin 到 **4.1.4**（09-07 发布）。
> 与下面步骤描述的差异：(a) 语料只进仓库 `.tcompact` + summary + explain（Debug 文本每条几 MB，`dump-fragments` 工具按需还原）；
> (b) 4.1.4 的 `TPipelineFragmentParamsList` 顶层只有 `runtime_filter_info`，共享字段在首个 fragment（`params.rs` 合并两处）；
> (c) 4.1.4 变量名是 `enable_local_shuffle`，没有 `LOCAL_EXCHANGE_NODE`；(d) FE ≥3 个 fragment 走 prepare/start 两阶段；
> (e) SR 的 `report_to_frontend` 不需要（Doris SELECT 路径不要 report）；(f) 结果 store 同时按 query_id 和 instance id 登记。
> 各步的产出见 `tasklist.md`「轨 1 P0」；坑见 `handoff.md`「轨 1 P0 实测」。

1. **落点与分支**：在自己的 fork 开 `experimental-doris` 分支（基于 `dev`），目录 `experimental/doris/`。先在 fork 迭代，~~P1 结束、CI 绿后再 re-open #137 并提 draft PR~~
   **09-18 修订：MVP-A0 跑通后**再 re-open #137 并提上游 draft PR（ADR-011 D-1 修订）。
2. **骨架**：从 SR 复制非协议部分，从 `origin/doris` 取纯 Rust 文件（不 checkout 整个分支）：
   ```bash
   cd /Users/morningman/workspace/git/sirius && git checkout -b experimental-doris dev
   mkdir -p experimental/doris/{crates,scripts,sql,conf,tests/fixtures/tpch} && cd experimental/doris
   cp -r ../starrocks/{Cargo.toml,pixi.toml,.gitignore,src} .          # 之后删 prpc.rs/brpc.rs/proto.rs，改名 crate
   git show origin/doris:doris/crates/doris-thrift/build.rs  > crates/doris-thrift/build.rs
   git show origin/doris:doris/crates/doris-proto/build.rs   > crates/doris-proto/build.rs
   git show origin/doris:doris/docker/fe-custom.conf         > conf/fe.conf
   for f in run-tpch.sh validate_tpch_results.py start-cluster.sh; do git show origin/doris:doris/scripts/$f > scripts/$f; done
   git submodule add --depth=1 https://github.com/apache/doris experimental/doris/doris   # 再 checkout 到 4.1.x tag
   ```
3. **codegen**：`doris-thrift`（thrift 0.24 crate，`thrift --gen rs`，把 `#![...]` 改成 `#[...]`，SR/`origin/doris` 都有这段后处理）；
   `doris-proto`（prost + tonic-build 生成 `PBackendService` server trait；SR 的 `BrpcServiceGenerator` 不要）。`cargo test --no-default-features` 在 Mac 上过。
4. **节点身份**：`node.rs`——`ALTER SYSTEM ADD BACKEND`（指数退避重试，照 SR `RegistrationConfig`）、心跳 handler（`be_node_role="mix"`、`be_start_time`、三个端口）、
   `BackendService` 桩（`get_tablet_stat` 等回 OK/空）。验收 `SHOW BACKENDS`。
5. **分析期 RPC**：`fetch_table_schema`（解 TBinary `TFileScanRange` → 首个非空文件 → parquet footer → `PTypeDesc`）+ `glob`。
   验收 `DESC FUNCTION local(...)`、`EXPLAIN SELECT ... FROM local(...)`。
6. **执行期壳**：`exec_plan_fragment(_prepare/_start)` 解 TCompact `TPipelineFragmentParamsList` + VERSION_3 合并 + dump；`cancel_plan_fragment` 回 OK；
   `fetch_data` 先挂起再回 INTERNAL_ERROR（让 FE 正常收尾）。默认 `SIRIUS_BE_TRANSLATE_ONLY=1`。
7. **FE 配置固化**：`conf/fe.conf`、`sql/session.sql`、`sql/tpch-views.sql`；pixi `fe` 任务改为下载官方 tarball 并只用 `fe/`（JDK 17 由 pixi 装）。
8. **采语料**：`scripts/run-tpch.sh --translate-only` 把 22 条的 fragment 落进 `tests/fixtures/tpch/qNN/`（含 `EXPLAIN` 输出）。这份语料**两轨共用**（`tasklist.md` M0.1/M0.2）。
9. **CI**：`experimental.yml` 加 `doris` job（浅拉 submodule → `pixi -e be` → fmt / clippy / `cargo test --no-default-features`）。

### P1 · 翻译器（≈3–4 周，Mac 可做）

验收：22 条语料全部翻出 Substrait，`substrait-explain` 输出人工核对一遍；负向用例覆盖 `semantics-gaps.md` G-01～G-18（`LARGEINT`、`DECIMAL256`、复杂类型、未白名单函数等硬拒绝）。

1. 描述符表 / 类型映射（`type_mapper`：`DECIMAL64/128 → decimal`、`DATEV2 → date`、`TEXT → string`；精度 > 38 拒绝）。
2. 表达式：`SLOT_REF`、各字面量、`BINARY_PRED`、`COMPOUND_PRED`、`ARITHMETIC_EXPR`、`CAST_EXPR`、`CASE_EXPR`、`IN_PRED`、`IS_NULL_PRED`、`FUNCTION_CALL` 白名单（`like`/`not like`、`substring`、`year`、`if`、`length`）。
   OQ-009 若为真，多加 `PREDICATE`/`LITERAL` 两个分支。
3. 节点：`FILE_SCAN_NODE`（路径来自 `local_params[].per_node_scan_ranges`，参数来自首个 fragment 的 `file_scan_params[node_id]`，`required_slots` 决定投影）、`HASH_JOIN_NODE`（含 `other_join_conjuncts` → MIXED join、null-aware anti → mark+not、`vintermediate_tuple_id_list`/`output_tuple_id` 布局）、
   `CROSS_JOIN_NODE`（降等值 join，SR #1234 同法）、`AGGREGATION_NODE`、`SORT_NODE`、`SELECT_NODE`、`ASSERT_NUM_ROWS_NODE`（直通）、`UNION_NODE`（常量一行 → `VirtualTable`）；节点级 `projections` → 追加 `ProjectRel`；`conjuncts` → `FilterRel`；`limit` → `FetchRel`。
   `MATERIALIZATION_NODE`/`LOCAL_EXCHANGE_NODE`/其它一律拒绝并指名。
4. **A0 拼接器**：`EXCHANGE_NODE(node_id)` 处接入发送方 fragment 的 Rel（加一层 `ProjectRel` 对齐 exchange 的输出 tuple 布局）；两阶段聚合合并成一阶段 `AggregateRel`；merging exchange 变普通 `SortRel`；`DATA_STREAM_SINK` 消失。
   `origin/doris` 的 `test_aggregation_two_phase_collapse` 是这个的先例。
5. 测试：语料回放 + `substrait-explain` 快照（照 SR `tests/translate.rs` 4.6k 行的写法）。

> **09-18 实测结果：P1 全部完成**（commit `6641c450` / `37260bb9` / `4e6f0921` / `ba470a4e` / `9cfc92fa`，`fork/experimental-doris`）。22 条全部翻出单棵 Substrait，快照（`tests/snapshots/`）人工核对无误；
> FE 4.1.4 实测 22/22 "translated into one plan"；G-01～G-18 每条有负向单测（对照表在 `handoff.md`）。与上面预想的差别：语料里没有 `SELECT_NODE`/`ASSERT_NUM_ROWS_NODE`/`CASE_EXPR`/`IS_NULL_PRED`，都没做；
> `UNION_NODE` 一律拒绝而不是转 `VirtualTable`；`SELECT DISTINCT` 是零函数两阶段 group-by，拼接器折叠后放行（G-13 改判）；`substrait-explain` 0.9 有四处盲区，用 `explain.rs` 的显示改写补齐。
> 拼接器 ≈1k 行、快照 27 份，比 SR 的 4.6k 行快照测试轻——快照是整棵 plan 的 explain 文本而不是逐 Rel 断言。

### MVP-A0 · 单节点、单计划（≈2 周，**需要 GPU**）

验收：**22/22 在 GPU 上与 DuckDB 基线逐行一致**（decimal 容差 1e-5；Q15 若因 FP64 等值不稳定要记录），SF1 + SF10；每条查询的 GPU 时间有记录。

1. `engine.rs` 从 SR 原样搬；`fetch_data` 改成挂起等待（`Notify`）+ 分批交付；结果编码搬 SR。
2. `scripts/run-tpch.sh` + `validate_tpch_results.py`（`origin/doris` 现成，DuckDB 读同一批 parquet 做 oracle）。
3. 有余力再起一套原生 Doris（官方 BE 二进制，同机不同端口）做第二基线，顺便拿 CPU 对照时间。

### MVP-A · 单节点、真 fragment（≈3–4 周，GPU）

验收：22/22 按 FE 的 fragment 拓扑逐个执行（store-and-forward），结果同 A0；有 A0 vs A 的 per-query 时间对比。

1. 引擎 seam 换成 `Fragment` 生命周期（#1791 + #1792 的 Rust 绑定，未合就 cherry-pick）：receiver-first 注册 stream → 叶子 `build()`+`run()` → 输出 parked → 上游 `declare_input_*` + `relay_from` → `run()` → … → 结果 fragment `take_result`。
2. 翻译器切到 exchange-as-stream：`EXCHANGE_NODE → ReadRel(sirius_stream_<node_id>)`，`per_exch_num_senders → declare_input_sender`，merging exchange 在接收侧 `SortRel`；
   两阶段聚合按 FE phasing（`agg_phase::classify`：sum→sum、count→sum、avg→sum+count、decimal sum 线上 DOUBLE）。
3. 失败传播：中间 fragment 失败 → 结果 instance 的 `fetch_data` 回错误（SR `stacked/cn-result-store-failure-propagation` 的做法）。

### MVP-B · 多节点、一 GPU 一 BE（≈4–6 周 + 上游）

验收：SF100 在 2–4 张卡上 22/22；有第一份可对外的数字（沿用对方 deck 的 break-even 框架，逐条列 GPU vs CPU）。

**A 验证成功不等于 B 就绪。** A 交付的是 B 的「脑子」：调度器、exchange 翻译、两阶段聚合、失败传播，B 原样复用。
B 的增量全是 A 从未触碰的面：

| A 里的样子 | B 里变成什么 | 证据 / 预期 |
|---|---|---|
| fragment 间交接 = `relay_from`（同进程 GPU 指针搬运，零拷贝） | parked 输出 → `pull_arrow`（D2H）→ Arrow IPC → gRPC → 对端 `push_arrow`（H2D）→ `close_input`。Arrow 路径实测 0.28 GB/s，NIXL 48–56 GB/s | 正确性 4–6 周可到（SF1–SF10）；性能等 #1794 |
| 每个流恰好 1 个 sender | `per_exch_num_senders` > 1；hash sink 对 N 个目的地各一条输出流；EOS 要数齐所有 sender；sender 可能早于对端 receiver 注册 → 接收侧按 `(finst_id, node_id, sender_id)` 停放 | #1792 的 `LocalExchange` / `SenderSlot` |
| 一个进程独占 GPU | 一 GPU 一进程；Sirius 默认独占 95% 显存 + 每 NUMA 90% 内存做 pinned，多进程**必须**显式 `capacity_bytes`；staging arena 耗尽（SR fork q09/q21）、parked 输出泄漏、无 cancel | `embeddability-study.md`；SR fork `OPEN-ISSUES.md` |
| FE 只有一个 BE 可选，计划形状固定 | FE 按（不存在的）统计选 broadcast 还是 shuffle；文件按 `local()` 分给多个 BE；引擎不支持 byte-range 切分（#1696/#1700 未合）→ 表要预先切成多个 parquet，否则倾斜 | `FederationBackendPolicy`；§2.2 |
| 单进程内无超时 | 跨节点 RPC 超时（SR 是 60 s）、FE 一次心跳失败即 dead、FE 会拉黑失败的 BE（08-09 4 个 CN 拉黑 2 个）、exchange 600 s 卡死 | `pseudo-be-feasibility.md` §1.5 |
| 单机部署 | 每台机器：驱动 + pixi 环境 + libsirius + parquet 一份；`priority_networks`、advertise host、端口方案 | `start-cluster.sh` |

降风险的做法：B 的前半段（Remote 路由、Arrow 传输、多 sender EOS）在 A 的那台**单卡机上用两个 BE 进程分显存**先做通，跨主机只是最后把 `127.0.0.2` 换成真 IP。
预期管理看 SR 的轨迹：上游可合并线 2 CN SF100 只有 12/22 精确；fork 的 22/22 @ SF1000 是 NIXL + 几十个修复之后的事。

1. 一 GPU 一进程：`--gpu-device`、显存/pinned 内存切分（Sirius 默认独占 95% 显存 + 每 NUMA 90% 内存做 pinned，多进程**必须**显式配 `capacity_bytes`）、`127.0.0.n` 别名 + 端口偏移（`start-cluster.sh` 现成）。
2. Remote 路由：FE 把 `destinations{brpc_server}` 交给发送方 fragment；`brpc_server == 自己` → Local（`relay_from`），否则 → 私有 gRPC `SiriusExchange.transmit_arrow`（Arrow IPC 帧 + `finst_id/node_id/sender_id/sequence/eos`，语义照 #1792）→ 接收侧 `push_arrow` + `close_input`。
3. 分区 hash：全 Sirius 节点 + TVF 路径无 bucket shuffle → 只要所有 sender 一致，用 sink 自带的 murmur3，**不需要**对齐 Doris 的 crc32。
4. 性能路径：等 #1794 合并后把 Arrow 帧换成 NIXL/staging arena（Arrow 路径实测 0.28 GB/s vs NIXL 48–56 GB/s，只够验证正确性）。

---

## 4. 开发环境

### 4.1 分工：哪台机器做什么

| 环节 | Mac（现有） | AWS GPU 机 |
|---|---|---|
| P0 协议壳 + P1 翻译器 + 全部单测 | ✅ `cargo test --no-default-features`（SR 的 CI 就是这样） | 不需要 |
| Doris FE（官方二进制，JDK 17）+ 语料采集 | ✅ 本地起 FE（`doris-dev-deploy` skill 的端口约定避开主仓库集群） | 也可以 |
| 编译 Sirius / 任何 GPU 代码 / 端到端 / 差分 / 性能 | ⛔ | ✅ |

> `environment.md` 的铁律仍然成立：**测试必须有 GPU 才能跑的代码，就是放错了层。** 翻译器和协议壳的每一个分支都要在 Mac 上有单测。

### 4.2 AWS 规格

硬性要求（`docs/README.md`）：Linux amd64/arm64，glibc ≥ 2.28；NVIDIA 计算能力 ≥ 7.5（Turing+）；CUDA 13.x（驱动 ≥ 580.65.06）或 CUDA 12.x（驱动 ≥ 525.60.13）；
`io_uring` 可用（`kernel.io_uring_disabled=0`；容器要放行 `io_uring_setup/enter/register`）；parquet 所在文件系统支持 `O_DIRECT`。

| 阶段 | 推荐实例 | 理由 | 备注 |
|---|---|---|---|
| MVP-A0 / MVP-A（单节点） | **`g6e.2xlarge`**（1×L40S 48 GB，8 vCPU，64 GB）；预算紧用 `g5.2xlarge`（1×A10G 24 GB，CC 8.6） | 一张卡 + 足够 pinned 内存；SF1/SF10 24 GB 显存够，SF100 要 48 GB 更稳 | 首次 `pixi run make` 编译 Sirius 吃 CPU，可临时换 `g6e.4xlarge`（16 vCPU）编一次再降配，或直接 `gh run download` CI 产物（每次 `dev` push 都有，327 MB/变体，90 天） |
| MVP-B（多节点） | **`g6e.12xlarge`**（4×L40S，48 vCPU，384 GB）跑 4 个 BE 进程；或 2×`g6e.2xlarge` 跨主机 | 同机多进程先验证路由和 EOS；跨主机才验证真实网络 | 多 GPU 实例配额通常要先申请 |
| 存储 | gp3 EBS ≥ 500 GB（或实例 NVMe） | build 树 + pixi cache ≈ 50 GB；TPC-H parquet SF100 ≈ 30 GB；SF1000 ≈ 300 GB | EBS 支持 `O_DIRECT`；NVMe 实例存储更快但重启即丢 |
| 系统 | Ubuntu 22.04 / 24.04（glibc 2.35 / 2.39） | `io_uring` 默认开 | Amazon Linux 2 的 glibc 2.26 **不满足** |
| 驱动 | ≥ 580.65.06 | 对应 CUDA 13 的 pixi 环境（`cuda-version 13.2`、`libcudf 26.08.01`） | AMI 自带驱动若低于 580 而高于 525，改用 `pixi run -e cuda12` |

费用量级：单卡按需每小时个位数美元，4 卡两位数；用 spot + 不用就停 + EBS 快照保留环境。以 AWS 定价页为准。

**09-18 晚实际选型：`g4dn.2xlarge`**（1×T4 16 GB，CC 7.5 = Sirius 支持的下限，8 vCPU，32 GB，225 GB NVMe 实例盘，≈$0.75/h）。够 MVP-A0 验正确性（SF1/SF10），性能数字不代表 L40S。配套决定：
- **OS**：Ubuntu Server **24.04 LTS x86_64**（Canonical 官方 AMI，glibc 2.39，io_uring 默认开，与 CI 的 ubuntu-24.04 一致）；驱动自己装 NVIDIA apt 源的 **580**（`nvidia-driver-580-open`，T4 支持 open 内核模块），`nvidia-smi` 要显示 `CUDA Version: 13.x`。
  不要 Amazon Linux 2（glibc 2.26）；DLAMI 自带驱动可能 < 580，`experimental/doris` 的 `engine` 环境只有 CUDA 13 一档（根仓库才有 `cuda12`），所以驱动 ≥ 580 是硬要求。
- **盘**：根卷 gp3 **300 GB**（吞吐提到 250 MB/s）；估算 OS 10 + 根 pixi 环境（CUDA 13 + RAPIDS + clang）15–20 + Sirius build 树 + sccache 20–30 + `experimental/doris`（target 10 + `.duckdb-substrait` 3 + FE 1.2）15 + TPC-H SF1/SF10 3 ≈ 70–90 GB；要跑 SF100（parquet ≈30 GB + 落盘 spill）再扩到 500 GB（EBS 在线扩容，`growpart` + `resize2fs`）。
  225 GB NVMe 实例盘停机即清空，只当 scratch：Sirius 的 `memory.disk.downgrade_root_dirs` 和 parquet 副本可以放那里，别放 build 树。
- **32 GB 内存是最大的坑**：Sirius 默认把每个 NUMA 节点 **90% 内存 pin 成 host tier**（28.8 GB），FE 4 GB heap + BE + DuckDB 就没地方了。BE 启动必须带 `--sirius-config` 指向一个 YAML，例如
  `sirius: { topology: { num_gpus: 1 }, memory: { gpu: { usage_limit_fraction: 0.9 }, host: { capacity_bytes: 12Gi }, disk: { disk_id: 0, capacity_bytes: 100Gi, downgrade_root_dirs: "/mnt/nvme/sirius_spill" } } }`
  （键名见 `docs/super-sirius/configuration.md`；SF10 在 16 GB 显存上要靠 host/disk 降级，disk 段别省）。

### 4.3 GPU 机搭建步骤（一次性）

```bash
# 0. 检查
nvidia-smi                                   # 驱动版本 ≥ 580.65.06（否则走 cuda12 环境）
cat /proc/sys/kernel/io_uring_disabled       # 期望 0
curl -fsSL https://pixi.sh/install.sh | bash

# 1. Sirius 引擎（一次 20–40 分钟）
git clone --branch dev https://github.com/sirius-db/sirius && cd sirius
git submodule update --init --depth=1 --jobs 3 duckdb substrait cucascade
pixi run make                                # → build/release/extension/sirius/sirius.duckdb_extension
#    替代：gh run download <run-id> 取 CI 产物，放到同一路径

# 2. Doris FE（官方二进制，不编译）
#    从 doris.apache.org 下载 apache-doris-4.1.x-bin-x64.tar.gz，只用 fe/；JDK 17 由 experimental/doris 的 pixi fe 环境提供
#    cp experimental/doris/conf/fe.conf <fe>/conf/fe.conf && <fe>/bin/start_fe.sh --daemon

# 3. 伪 BE
cd experimental/doris
pixi run be-build                            # cargo build --release（默认 feature 链接 build/release）
pixi run be-run -- --fe-host 127.0.0.1 --advertise-host <本机 IP> --gpu-device 0
#    验收：mysql -h127.0.0.1 -P9030 -uroot -e 'SHOW BACKENDS\G' 里 Alive: true

# 4. 数据
#    TPC-H parquet：仓库自带 dataset-manager skill（DuckDB tpch 扩展生成，指定 SF 与输出目录）
#    然后 mysql < sql/session.sql; mysql < sql/tpch-views.sql; scripts/run-tpch.sh --sf 1
```

Docker 也可以（`--gpus all` + 自定义 seccomp 放行 io_uring），但裸机更省事；`origin/doris` 的 FINDINGS 里 Docker CDI 下 `cudaMemcpyBatchAsync` 失败过一次，能不用就不用。

---

## 5. 需要拍板的事与风险

### 5.1 已拍板（2026-09-18 → `decisions.md` ADR-011）

| 编号 | 事项 | 决定 | 后果 |
|---|---|---|---|
| D-1 | 落点 | fork 上的 `experimental/doris/` 起步，**MVP-A0 跑通后**（09-18 修订，原为 P1 结束）re-open #137 提 draft PR | 对齐 SR 结构、复用 CODEOWNERS 与 `experimental.yml` |
| D-2 | Doris 版本 pin | 4.1.x 最新 release（09-09 时是 4.1.3 / 4.1.4-rc04；**09-18 落地为 4.1.4**，09-07 发布）；FE 二进制与 codegen IDL 用**同一个 tag**，不追 master | 翻译器枚举面固定；OQ-009 已在该 tag 上核实（FE 不用 PREDICATE/LITERAL） |
| D-3 | GPU 机 | 按 §4.2 自购 AWS；P1 结束前不买 | MVP-A0 起所有验收 |
| D-4 | 数据入口 | **`local()`** + `shared_storage=true`；`s3()`/`hdfs()` 不做 | `glob` RPC 必做；跨主机时 parquet 每机一份 |
| D-5 | 是否现在公开说明 | **暂不**；等 re-open #137 时一并说 | 上游暂不知道我们在做；A/B 阶段的 cherry-pick 自己维护 |

### 5.2 风险（相对 09-09 的更新）

| 风险 | 变化 | 缓解 |
|---|---|---|
| 引擎依赖的合并节奏 | 20 个 draft 关了，换成 3 条更大的线（#1791 非 draft 有希望；#1792 是「study PR」，可能不直接合） | A0 零依赖；A/B 本地 cherry-pick 指定 commit（`891d41c3`、`d7f2a7e3`），不追整条分支 |
| decimal → FP64 漂移 | 不变（#1687/#1688 未合） | 差分用容差；Q15 记录；后续翻译器改原生 decimal |
| Q16 `count(distinct)` 的 FE phasing（OQ-008） | **已定**（09-18 语料）：两阶段 `multi_distinct_count`，不是嵌套 group-by | A0 合并成单阶段 `count(distinct)`；A 阶段 partial state 自定 |
| 单飞引擎、无 cancel、parked output 泄漏 | 不变 | harness 保留 `RESTART_CMD`；benchmark 串行 |
| Doris FE 对 TVF 无统计 → Q8/Q9 join 顺序 | 不变 | 先改写 FROM 顺序（SR 同法），再考虑 FE 侧行数估计 |
| 两套翻译器（轨 1 Rust / 轨 2 C++）的维护税 | 不变 | ADR-011 写明伪 BE 是验证/benchmark 载体；语料与白名单共用 |

---

## 附录 · SR 文件 → Doris 版的逐文件处置

| SR 文件 | 行数 | Doris 版处置 |
|---|---|---|
| `build.rs`（`BrpcServiceGenerator`） | 269 | **删**：换 tonic-build |
| `crates/starrocks-thrift/build.rs` | 150 | **搬**（或用 `origin/doris` 的同构版本），路径改 `doris/gensrc/thrift` |
| `src/prpc.rs` / `src/brpc.rs` | 490 / 328 | **删**：Doris FE→BE 是 gRPC h2c |
| `src/proto.rs` | 17 | 改：include prost + tonic 生成物 |
| `src/lib.rs`（注册/心跳/BackendService 桩/report/thrift server） | 1834 | **改**：注册 SQL、`TBackendInfo` 字段、Doris 的 `BackendService` 方法集；thrift server 循环与优雅关停原样 |
| `src/main.rs` | 401 | **搬**：`Args`/`RegistrationConfig`/`EngineConfig`/关停编排原样；bRPC runtime 换 tonic `Server::serve_with_incoming_shutdown` |
| `src/compute_node_service.rs` | 1156 | **改**：方法集换成 Doris 六个；attachment 换 `request` 字段（TCompact）；descriptor cache 逻辑不需要（Doris 每次带 `desc_tbl`）；dump/translate-only 钩子原样 |
| `src/engine.rs` | 397 | **搬**（A0 原样；A/B 换 `Fragment`） |
| `src/fragment_executor.rs` | 110 | **搬** |
| `src/result_encoder.rs` | 288 | **搬**：`TResultBatch` 换 Doris 的（同为 MySQL 文本行 + TBinary） |
| `src/result_store.rs` | 169 | **改**：挂起等待、多批、`query_id`/instance 双键、cancel 驱逐 |
| `src/file_schema.rs` | 370 | **改**：输入换 `TFileScanRange`，输出换 `PTypeDesc` 列表；多文件取首个非空 |
| `crates/starrocks-plan-translator/*` | 3.9k + 4.6k 测试 | **参照重写**：结构、错误类型、cursor、slot 键照抄；节点/表达式枚举换 Doris 的；加节点级投影、`ASSERT_NUM_ROWS`、null-aware anti、A0 拼接器 |
| `pixi.toml` / `conf/fe.conf` / `.github/workflows/experimental.yml` | 178 / — / — | **改**：FE 任务改下载 tarball；`engine` 依赖以仓库根为准；CI 加 `doris` job |
