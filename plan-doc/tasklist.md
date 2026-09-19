# 任务分解

进度约定：`[ ]` 未开始 · `[~]` 进行中 · `[x]` 完成。完成时在条目后补一行 `→ 产出：<路径/commit>`。

**当前阶段（2026-09-19）：两条轨。**
- **轨 1 · 伪 BE（ADR-011，验证/benchmark 载体）**：P0 脚手架完成（2026-09-18）；P1 翻译器全部完成（2026-09-18）；MVP-A0 的 Mac 侧准备全部完成（2026-09-18 晚）；GPU 机（AWS `g4dn.2xlarge`）A0.4-0 Linux x64 三层验证通过（2026-09-19）；A0.4 引擎编成、引擎路径 BE 跑通（2026-09-19）；**A0.5 TPC-H 22/22 在 GPU 上与 DuckDB 基线一致 + A0.6 每条查询引擎时间已记录（2026-09-19，修了两处引擎问题 G-31/G-32）** → 下一步 **A0.7 上游落地**（含把引擎修复单独提 PR），之后 SF10 / MVP-A。
  **上游 PR / re-open #137 推迟到 A0 跑通后**（用户 09-18 拍板，ADR-011 D-1 修订）——此前全部在 fork `morningman/sirius` 的 `experimental-doris` 上迭代。
- **轨 2 · 进程内（ADR-010，产品路径）**：P0 可嵌入性调研已完成（2026-09-01，`embeddability-study.md`）；`push_arrow` 提案在 #1590 等回复；MVP-0 未开工、搁置。
  轨 2 的 M0.1/M0.2（fragment dump + 语料）已由轨 1 的 P0 实现（语料两轨共用：`experimental/doris/tests/fixtures/tpch/`）。

> 两条轨各有自己的 "P0"：下文「轨 1 · P0」= 脚手架，「P0 · Sirius 可嵌入运行时库可行性调研」= 轨 2。

---

## 轨 1 · 伪 BE（`experimental/doris/`，方案见 `doris-pseudo-be-plan.md` §3）

依赖链：`P0 → P1 → MVP-A0 → MVP-A → MVP-B`；GPU 从 MVP-A0 起才是硬需求。

### [x] 轨 1 P0 · 脚手架 ← **已完成 2026-09-18** → 产出：commit `17d8c086`（`fork/experimental-doris`，fork = `morningman/sirius`），`experimental/doris/`

验收（全部通过）：官方 FE 4.1.4 `SHOW BACKENDS` Alive；`local()` 可规划；22 条 TPC-H 语料落盘；OQ-008/009 有答案。

- [x] P0.1 落点与分支：`experimental-doris` ← `dev`；`experimental/doris/`；浅 submodule `doris/` 钉 **4.1.4** → 产出：`.gitmodules`、`experimental/doris/doris`
- [x] P0.2 骨架：SR 的 `main/engine/fragment_executor/result_encoder` 搬入并改名；`pixi.toml`（`fe`/`be`/`client`/`engine` 四环境，osx-arm64 可解）；`conf/fe.conf`；`.gitignore` → 产出：`experimental/doris/{Cargo.toml,pixi.toml,pixi.lock,conf/,src/}`
- [x] P0.3 codegen：`doris-thrift`（thrift 0.22 `--gen rs` + Default/命名 Debug 后处理）、`doris-proto`（tonic-prost-build，58 个 RPC）、`doris-plan-translator` 骨架 → 产出：`crates/*`；`cargo test --no-default-features` Mac 全绿
- [x] P0.4 节点身份：`node.rs`（心跳 handler、`ALTER SYSTEM ADD BACKEND` 幂等注册、thrift 服务循环、`BackendService` 26 个桩）→ 验收 `Alive: true`
- [x] P0.5 分析期 RPC：`file_schema.rs`（parquet footer → `PTypeDesc`，映射照 BE；`glob`）→ 验收 `DESC FUNCTION local(...)`、`EXPLAIN`
- [x] P0.6 执行期壳：`params.rs`（TCompact `TPipelineFragmentParamsList` + simplified 合并 + 落盘）、`backend_service.rs`（`exec_plan_fragment(_prepare/_start)`、`cancel`、挂起式 `fetch_data`）、`result_store.rs` → 验收 SELECT 走完 prepare/start/fetch/cancel
- [x] P0.7 FE 配置固化：`conf/fe.conf`、`sql/session.sql`（4.1.4 变量名）、`sql/tpch-views.sql`（`local()` + `shared_storage`，含 Q15 `revenue0`）、`sql/tpch/q01..q22.sql`（Doris `tools/tpch-tools` 4.1.4）、`scripts/{fetch-fe,fe,be}.sh`
- [x] P0.8 采语料：`scripts/run-tpch.sh --translate-only` → `tests/fixtures/tpch/qNN/`（`.tcompact` + summary + explain + SQL）+ `INDEX.md`（形状表 + 覆盖统计）+ `src/bin/dump-fragments.rs`；`tests/corpus.rs` 回放
- [x] P0.9 CI：`.github/workflows/experimental.yml` 加 `doris` job（fmt / clippy / test，浅拉 submodule）

### [x] 轨 1 P1 · 翻译器（≈3–4 周，Mac 可做）← **已完成 2026-09-18**（P1.1–P1.5 五个 commit 在 `fork/experimental-doris`）

验收：22 条语料全部翻出 Substrait，`substrait-explain` 输出人工核对；负向用例覆盖 `semantics-gaps.md` G-01～G-18。
语料实测需要的面（`tests/fixtures/tpch/INDEX.md`「Coverage」）：plan 节点 `EXCHANGE/FILE_SCAN/HASH_JOIN/AGGREGATION/SORT/CROSS_JOIN`；
表达式 `SLOT_REF, STRING/INT/DECIMAL/DATE/NULL_LITERAL, BINARY_PRED, COMPOUND_PRED, ARITHMETIC_EXPR, CAST_EXPR, FUNCTION_CALL, IN_PRED, AGG_EXPR`；
函数 `eq/ne/lt/le/gt/ge/add/subtract/multiply/divide/like/if/year/substring` + `sum/count/avg/min/max/multi_distinct_count`；
join `INNER/LEFT_SEMI/RIGHT_SEMI/RIGHT_ANTI/RIGHT_OUTER/NULL_AWARE_LEFT_ANTI`。

- [x] P1.1 描述符表 + 类型映射（`(tuple_id, slot_id)` 联合键；DECIMAL128I/DATEV2/DATETIMEV2/STRING 白名单；LARGEINT/DECIMAL256/复杂类型硬拒 + 负向用例）← **已完成 2026-09-18** → 产出：commit `6641c450`，`crates/doris-plan-translator/src/{type_mapper,descriptor_table}.rs`（30 单测，G-01/05/06/07/08/09/10/17/18 各有负向用例）；`tests/corpus.rs` 22 条 desc_tbl 全建、全部 SLOT_REF 可解析
- [x] P1.2 表达式翻译（上列 13 种节点 + 14 个标量函数；`AGG_EXPR`/`TAggregateExpr` 的 update/merge 两相）← **已完成 2026-09-18** → 产出：commit `37260bb9`，`crates/doris-plan-translator/src/expr_translator.rs`（30 单测：G-01/02/03/04/06/15/16 负向 + 畸形先序）；`tests/corpus.rs` 22 条语料 >1000 条标量表达式 + 77 个 AGG_EXPR 全部翻译
- [x] P1.3 节点翻译（六种；节点级 `projections`/`conjuncts`/`limit`；`EXCHANGE_NODE` 作为 fragment 边界的命名流；`MATERIALIZATION/UNION/...` 指名拒绝）← **已完成 2026-09-18** → 产出：commit `4e6f0921`，`node_translator.rs` + `scan_ranges.rs`（15 + 5 单测）；`translate_fragment` 出完整 Substrait `Plan`；`dump-fragments --translate`；语料 151 个 fragment 里 **102 个单独可翻译**，49 个含两阶段聚合的等 P1.4 拼接器
- [x] P1.4 A0 拼接器（多 fragment 拼回一棵树：两阶段聚合合并、Q16 `multi_distinct_count` → `count(distinct)`、merging exchange → SortRel、DATA_STREAM_SINK 消失）← **已完成 2026-09-18** → 产出：commit `ba470a4e`，`stitcher.rs`（3 单测，覆盖 8 条拒绝分支）、`PlanTranslator::translate_batch`、`dump-fragments --stitch`；**22 条语料全部拼成单棵 Substrait**（`tests/corpus.rs`）
- [x] P1.5 测试：`substrait-explain` 快照（22 条拼接后的 explain 文本进 `tests/snapshots/`，人工核对一遍）；BE 的 translate-only 路径改用 `translate_batch`；负向用例对照 `semantics-gaps.md` G-01～G-18 逐条勾 ← **已完成 2026-09-18** → 产出：
  - `explain.rs`：`substrait-explain` 0.9 画不出 `local_files` 读 / decimal 字面量 / `IN` 列表 / 聚合 `DISTINCT`，在**副本**上改写成可画的等价形式再渲染；22 条零警告
  - `tests/snapshots/`（22 条 TPC-H + 5 条 gaps）：拼接后的节点树 + 完整 explain 文本；`tests/corpus.rs::every_corpus_query_matches_its_snapshot`，`UPDATE_SNAPSHOTS=1` 重生成。**22 条逐条对着 SQL 核过列下标 / join 侧向 / 聚合对位 / 排序键，全部正确**
  - `backend_service.rs::dispatch` 整批 `translate_batch`；FE 实测 22/22 "all N fragments translated into one plan"；`run-tpch.sh` 每条打印翻译结论、新增 `--sql-dir`
  - `sql/gaps/` + `tests/fixtures/gaps/`（真 FE 派发的 G-11 窗口 / G-12 UNION×2 / G-13 DISTINCT×2）+ `gap_corpus_verdicts`；**发现并修了拼接器 bug**：零聚合函数的两阶段 group-by（`SELECT DISTINCT`）没被折叠
  - G-01～G-18 ↔ 负向单测对照表见 `handoff.md`「P1.5 负向用例对照」
- [x] （可选、无对外影响）fork 内部 PR `morningman/sirius: experimental-doris → dev`，只为让 `experimental.yml` 跑起来（它不在 push 上触发；fork 的 Actions 已 enabled）；本机全绿是 macOS，CI 是 linux-64。**09-18 晚用户决定不在 Mac 阶段做，并入 A0.4-0 的 Linux 验证** ← **09-19 由 A0.4-0 在 GPU 机（ubuntu 24.04 x86_64，与 CI 同 OS）上本地跑 CI 同款三项替代，全绿；fork 内部 PR 仍未开**

### [ ] 轨 1 MVP-A0 · 单节点、单计划

**Mac 可做的准备**（GPU 机买之前做完，让 GPU 那天只剩"跑 + 比"）← **全部完成 2026-09-18** → 产出：commit `22d161d9`（`fork/experimental-doris`）：
- [x] A0.1 **DuckDB CPU 差分** ← **已完成 2026-09-18** → 产出：`scripts/build-duckdb-substrait.sh`（upstream DuckDB `v1.5.5` = 扩展钉的 `d8cdaa33` + 仓库 `substrait/` submodule → 可加载扩展 + shell，`.duckdb-substrait/`，≈3 min）、
      `dump-fragments --stitch --write-plan FILE --rewrite-path OLD=NEW`、`scripts/cpu-diff.sh`（导出 22 个 plan → `validate_tpch_results.py consume`：`from_substrait()` + `sirius_ffi.cpp` 同一批 `disabled_optimizers`，落 `log/cpu-diff/qNN/{result.tsv,duckdb-plan.txt}`）。
      **22/22 逐行一致**（容差 1e-9 相对 / 半 ulp）；G-13 两条探针也一致；**G-25/G-26/G-28/G-29 在 22 条上均未触发**。
      社区版 substrait 扩展不能用：fork `duckdb-1.5.5` 分支比 upstream 多 `c1a9876f`（`local_files` 按 base_schema 列名投影 + 关 hive partitioning），我们的 plan 依赖它
- [x] A0.2 **基线 + 校验器** ← **已完成 2026-09-18** → 产出：`scripts/validate_tpch_results.py`（`expected` / `consume` / `validate` 三个子命令；比较规则：列名不分大小写、数值 `max(1e-9·量级, 半 ulp(较粗 scale))`——
      1e-5 相对在 `sum_qty` 3.7e7 上会漏掉 ±377，改成 1e-9；半 ulp 是为 Doris 把 `avg(DECIMAL)` 声明成 DECIMAL(38,4) 而 DuckDB 算 DOUBLE；顶层 ORDER BY 按序比、允许并列换序，无 ORDER BY 排序后比）、
      `tests/expected/tpch-sf1/`（22 份 + INDEX.md，Q11 27,604 行 / Q16 18,314 行 gz，共 376 KB）+ `tests/expected/gaps-sf1/`、`run-tpch.sh` 执行模式跑完自动 `validate`（`--expected DIR` / `--no-validate`，mismatch 使运行失败）、
      pixi `check` 特性（`python-duckdb=1.5.5`，`fe` 环境也带上）+ 任务 `duckdb-substrait-build / tpch-expected / tpch-cpu-diff`。负向自检：改值 / 反转行序 / 删行 / 改列名全部 MISMATCH
- [x] A0.3 拼接器省掉重复的 Sort ← **已完成 2026-09-18** → 产出：`stitcher.rs::already_sorted`（merging exchange 的发送方根已是同键同序同 limit/offset 的 `SORT_NODE` 时不再合成）+ `node_translator.rs::already_sorted_and_limited`（`SORT_NODE` 压在自带同样 `Fetch(Sort)` 的聚合 top-N 上时不再发）。
      **范围比预想大**：DuckDB 优化后计划证实 15/22 条有双层（Q2/Q3/Q10/Q21 双 `TOP_N`、Q18 三层、另外 10 条双 `ORDER_BY`），现在全部单层（Q18 `1 Sort+Fetch`）；快照 17 份更新；CPU 差分仍 22/22
- [x] （顺手）拼接器缺口：`SELECT DISTINCT ... ORDER BY 全部 key LIMIT n` 时 FE 把 top-N 同时压到 update 相（`limit` + `agg_sort_info_by_group_key`），原来指名拒绝 → `stitcher.rs::same_top_n_by_group_key`：两相 limit 相同且按同一批 group key 同向排序时折叠、只留 merge 相那份；
      探针 `g13-distinct-topn` 改成确定性 SQL（原来 `order by n_regionkey limit 3` 并列截断不确定）并重采 5 条 gaps 语料

**🔒 需要 GPU**（AWS **`g4dn.2xlarge`**，09-19 起在手：T4 16 GB / 8 vCPU / 30 GB / Ubuntu 24.04 / 驱动 580.178 CUDA 13.0；见 `environment.md`「GPU 机」）：
- [x] A0.4-0 **Linux x64 验证** ← **已完成 2026-09-19（GPU 机上的第一件事）** → 产出：三层全过——
      0a CI 同款三项：`pixi install -e be` 8 s、fmt ✅、clippy `-D warnings` ✅（thrift 0.22 / protoc 36.1 在 linux-64 重新 codegen，`build.rs` 后处理无需改）、test ✅ **96 + 49 + 10**；
      0b 无引擎全流程：官方 FE 4.1.4（`doris-4.1.4-rc04-ad35a140c7f`，与 submodule 同 commit）24 s 健康，translate-only BE `Alive: true`；`run-tpch.sh --translate-only` **22/22 "translated into one plan"**，`INDEX.md` 形状表与仓库**逐字一致**；gaps 5 条 captured（G-11/G-12×2 拒、G-13×2 翻出）`INDEX.md` 逐字一致；
      0c `duckdb-substrait-build`（cmake 4.4 + ninja + 系统 g++ 13.3，13 min）→ `tpch-cpu-diff` **22 ok**（仓库语料）+ **22 ok**（本机 FE 新采的语料）+ gaps G-13 2 ok × 2。
      **顺手修的三件事**：(1) 根 `.gitignore` 的 `*.tsv` 把 `tests/expected/` 的 20 份 TPC-H + 2 份 gaps `.tsv` 基线挡在 `22d161d9` 之外（只有 Q11/Q16 的 `.gz` 进了仓库；0c 第一次跑 20 条 SKIPPED 才发现）——`experimental/doris/.gitignore` 加 `!tests/expected/**/*.tsv`，基线在本机用 DuckDB 重生成（Q16 与 Mac 逐字节相同，Q11 仅并列换序）；
      (2) pixi `check` 特性补 `cmake/ninja/ccache`（Mac 靠 Homebrew 隐式提供，裸 Linux 没有）；(3) `fe.sh status` 改用 `mysql -E`（conda-forge mysql 9.7 客户端拒绝 `-e` 里的 `\G`）。
      **发现**：FE 每个进程内投影列序 / 聚合函数序可能不同（Q1/Q14 EXPLAIN 与 Mac 不同，FE 重启后再变），plan **形状**稳定；翻译器按 slot id 工作不受影响（本机语料 CPU 差分 22 ok 证明）
- [x] A0.4 引擎路径：根仓库 `pixi run make`（CUDA 13 + RAPIDS 环境 15–20 GB，`duckdb`/`cucascade`/`vcpkg` submodule 全拉）→ `pixi run be-build`（`sirius-engine` feature，`engine.rs` 已搬自 SR）；`SIRIUS_BE_TRANSLATE_ONLY=0`；BE 带 `--sirius-config`（host pin ≤ 12Gi，见 `doris-pseudo-be-plan.md` §4.2）；FE 官方二进制同机（0b 已起）← **已完成 2026-09-19** → 产出：
      引擎：`duckdb`/`cucascade` 浅拉（`release` 预设不用 vcpkg，没拉）、根 `pixi install` **26 s**（7.1 GB，AWS→conda-forge 很快）、`pixi run make TEST_BUILD_TARGET=` **45 min**（8 vCPU，1208 个目标，其中 `.cu` 按 8 种架构编的那段最慢）→ `build/release/extension/sirius/{sirius.duckdb_extension (114 MB), libsirius.so.0.0.0 (133 MB)}`——**这版 dev 已经产出独立的 `libsirius.so`**（RPATH 指向根 env `lib/`），`sirius-sys` 的软链 stopgap 不再走；
      BE：`experimental/doris` 的 default 环境（含 `engine` 特性）`pixi install` 11 s（5.2 GB，与根 env 共享包缓存）；`cargo build --release -p sirius-doris-be` **3 min**（直接跑 cargo，绕开 `be-build` 任务对 `engine-build` 的依赖——那会把 C++ 单测 target 也编一遍）；
      新文件 `conf/sirius.yaml`（`num_gpus: 1`、GPU 90%、**host `capacity_bytes: 12Gi`**、disk 100Gi → `log/sirius-spill`、Quent 遥测 → `log/telemetry`）；`scripts/be.sh start --engine` 补齐：`LD_LIBRARY_PATH`（build 树 + pixi env `lib/`）、缺省 `--sirius-config conf/sirius.yaml`、预建 spill/telemetry 目录；启动命令 **`pixi run bash scripts/be.sh start --engine`**（default 环境）。
      **验收**：引擎 bring-up ≈4 s（显存预留 13.5 GB，BE RSS 1.3 GB），`SHOW BACKENDS` Alive；`run-tpch.sh --data /tmp/tpch-sf1 --queries 6` → **Q6 在 GPU 上 221 ms 返回，`revenue = 123141078.2283` 与 DuckDB 基线一致（validate OK）**，`log/telemetry/<query>/` 有 Quent 输出
- [x] A0.5 22/22 与 DuckDB 基线逐行一致（`run-tpch.sh --data …` 自动校验；SF1 用仓库里的 `tests/expected/tpch-sf1`，SF10 先 `validate_tpch_results.py expected --data … --out …` 生成；容差默认 1e-9 相对 + 半 ulp，GPU 上 FP64 漂移就用 `--tolerance` 放宽并记录；Q15 记录）；
      G-13 零度量 grouped aggregate、`sum(TINYINT)` HUGEINT 路径、`avg(DECIMAL)` DOUBLE 路径重点看。CPU 差分已证明 plan 本身正确，GPU 上的差异只能来自 Sirius 的物理执行 ← **已完成 2026-09-19** → 产出：**SF1 22/22 OK + G-13 探针 2/2 OK**（T4，`log/tpch/summary.csv`）。第一轮 15/22：
      (1) **Q16 把 BE 进程搞崩**——引擎 `std::terminate`（MARK join 在定尺寸前被 task creator 轮询，`refresh_cross_schedule` throw；G-31）→ **引擎修复** `src/op/sirius_physical_hash_join.cpp::get_next_task_hint`（未定尺寸的 MARK join 返回等 build 生产者而不是 throw）；
      (2) **Q17/Q20 引擎报错** "failed to translate mixed join inequality conditions to cuDF AST predicate"（不等值 join 条件里的 DECIMAL cast / 乘法进不了 cuDF AST；G-32）→ **引擎修复** `src/planner/sirius_plan_comparison_join.cpp::materialize_expression_join_keys`（不等值侧的复杂表达式也物化成投影列）；
      (3) **Q1 `avg_*` 最后一位**：Sirius 的 `CAST(DOUBLE AS DECIMAL)` 截断、DuckDB 舍入（G-19 更新，7 个值差 1 ulp）→ 校验器新增 `--ulps`（默认 0.5，`run-tpch.sh` 执行模式传 1，结论里标出靠它过的值的个数）。Q15 无 FP64 等值问题（1 行一致）；`sum(TINYINT)`（Q12）、`count(DISTINCT)`（Q16）、零度量 group-by（G-13）都精确。
      两处引擎修复后**透明路径回归**：同一批 parquet 上 22 条 SQL 经 `build/release/duckdb` 全部 GPU 执行（`replaced with GPU operator`）且与基线一致；`cargo fmt/clippy/test` 96+49+10 仍绿
- [x] A0.6 每条查询 GPU 时间记录 ← **已完成 2026-09-19** → 产出：BE 每条查询打一行 `query executed on the engine query_id=… engine_ms=… rows=…`（`backend_service.rs::execute_timed`；日志改成无 ANSI 色码，脚本可 grep），`run-tpch.sh` 执行模式读回写 `--out/timings.csv`（query, rows, wall_ms, engine_ms, query_id）。
      **SF1 · T4 · 单 BE 进程**：冷启动第一轮引擎合计 3.06 s，热后 **2.67–2.81 s / 22 条**（单条 57–304 ms：Q21 ≈300、Q9/Q8/Q2 ≈180–200、Q4/Q6 ≈60）；mysql 端到端合计 ≈5.8–6.0 s（FE 规划 + RPC + 取数，单条 100–510 ms）。数字见 `handoff.md`「A0.6 计时」，不代表 L40S
- [ ] A0.7 **上游落地**（ADR-011 D-1 修订：A0 跑通后才做）：上游 Draft PR `sirius-db/sirius:dev ← morningman/sirius:experimental-doris`（CONTRIBUTING Self-contained 路径，按「PR reviewability」清单写，保持 Draft）+ re-open #137 贴链接与现状。
      **开 PR 前先把 `plan-doc/` 从分支拿掉**（09-18 晚起 plan-doc 随 `experimental-doris` 提交，只为两台机器同步；不属于上游）

### [~] 轨 1 · Doris vs Doris+Sirius 性能对比（T0 SF10 跑通 ✅，**T1 g6e.8xlarge SF100/SF10/SF1 主表已出 ✅**，T1′ CPU 机 ⏳）← 方案 `experiments/sf10-bench/plan.md`（2026-09-19 拍板：§12 Q1/Q2/Q3/Q5 按建议），结果 `experiments/sf10-bench/results.md`（T1 正文 + T0 附录）

- [x] B0 用户拍板 §12（Q1 挂 NVMe ✅ 已挂 `/mnt/nvme`；Q2 g6e.4xlarge；Q3 要 c7i.12xlarge 成本对齐；Q5 做参照 C；Q4 等主结论；Q6 1 冷 + 3 热）← **2026-09-19**
- [x] B1 数据：SF10 parquet 生成到 NVMe（24 s，3.6 GB，一表一文件 `part.0.parquet`）+ DuckDB 基线 `tests/expected/tpch-sf10/`（19 s，1.6 MB gz，进仓库）← **2026-09-19** → 产出：`/mnt/nvme/tpch_parquet_sf10`、`tests/expected/tpch-sf10/`
- [x] B2 原生 BE 落地：`scripts/fetch-be.sh`、`scripts/be-native.sh`、`conf/be.conf`（`user_files_secure_path = /`、端口 91xx、`priority_networks`）、`sql/session-native.sql` + `session-native-split.sql` ← **2026-09-19** → 产出：`.doris-be/be`（4.6 GB），`SHOW BACKENDS` 两个 BE
- [x] B3 跑通验证：原生 BE 外表路径 **SF1 22/22、SF10 22/22** 过校验（Q1 `avg` 同样差 1 ulp）← **2026-09-19** → 产出：`log/bench/sf1-native/`、`log/bench/sf10-native/`
- [x] B4 跑批工具：`scripts/bench.sh`（切 BE + DROPP 伪 BE + 等 Alive、会话变量、`evict-cache.py --drop-caches`、每轮 `run-tpch.sh` / `run-tpch-duckdb.sh` + 校验 + `fe-audit.py`、0.5 s 采样 RSS/read_bytes/CPU/GPU 显存 + `utilization.gpu/memory`、`env.txt`/`variables.txt`）、`scripts/bench-all.sh`、`scripts/bench-report.py`、`scripts/run-tpch-duckdb.sh`、`scripts/fe-audit.py`、`scripts/evict-cache.py`、`scripts/olap-load.sh`、`conf/sirius-bench.yaml`；`run-tpch.sh --session-sql/--db`、`tpch-views.sql` 改 OR REPLACE ← **2026-09-19** → 产出：`experimental/doris/scripts/*`，README「Benchmark」一节
- [x] B5～B8 T0 上 SF10 全部系统 4 轮：A `native`、A-split `native-split`、B `sirius`、B′ `sirius-buffered`、R1 `duckdb`、R2 `duckdb-gpu`、C `native-olap` ← **2026-09-19** → 产出：`log/bench/sf10-*/`（本机，不进仓库）
- [x] B9 报告：`bench-report.py report` → `experiments/sf10-bench/results.md`（T0 数字，标注 T4 下限）← **2026-09-19**
- [x] B10 **T1**：机器实际到手 **g6e.8xlarge**（用户说 4xlarge，metadata 是 8xlarge，拍板保留；$4.529/h）。同一根卷原地改型，引擎不用重编（`CUDAARCHS` 含 89）；两块实例盘 RAID0、`fe.sh clean` 重来、`tpchgen-cli` 重编；SF10 全套 8 系统 11 min、**SF100 7 系统 57 min、SF1 8 系统**，每轮 22 条全过校验 ← **2026-09-19** → 产出：`log/bench-t1/{sf1,sf10,sf100}-*/`（GPU 机，不进仓库）、`log/bench-t1/*-results.md`、`results.md` 重写为 T1；脚本：`bench-all.sh --expected/--host-capacity`、`olap-load.sh` FORCE、`be-native.sh` 300 s
  - 主表 SF100（A stock vs B′）：**几何平均 1.34×、总时间 1.56×**（98.6 s vs 154.8 s）；SF10（对 split）1.09× / 1.23×；GPU busy 中位数 22 %；GPU 池高水位 35.6 GiB 无降级；DuckDB 32 线程 39.0 s；Doris 内表 18.0 s；**B vs R2 = 1.42×（plan 形状代价，翻译器可修）**
- [ ] B10-b **翻译器折叠恒等 Project / 重复 Sort**（`results.md` §2.4）：改完只重跑 SF100 的 `sirius-buffered` + `duckdb-gpu` 看 1.42× 收回多少
- [ ] B10-c `duckdb-gpu-pinned` 的 SF100 版本（`SIRIUS_PIN_TIER=host`，bench.sh 加个 `--pin-tier`）
- [ ] B10-d **T1′**：c7i.24xlarge（配 8xlarge，$4.28/h）只装 `pixi install -e fe` + `fetch-fe/fetch-be`，跑 `native`/`native-split`/`native-olap` SF100，`bench-report.py report --runs <两台> --price native=4.28 --price sirius-buffered=4.529`
- [ ] B11 T2 可选加测（p5.4xlarge / g7e.2xlarge 只跑 Sirius 侧）——等 T1 主结论后由用户定（§12 Q4）

### [ ] 轨 1 MVP-A · 真 fragment（store-and-forward；依赖 #1791 + #1792 `891d41c3`）
### [ ] 轨 1 MVP-B · 多节点（Arrow-over-gRPC 先，NIXL 后；依赖 #1792 `d7f2a7e3`）

---

## P0 · Sirius 可嵌入运行时库可行性调研 ← **已完成 2026-09-01** → 产出：`embeddability-study.md`、`experiments/p0.4-symbol-isolation/`、ADR-010

**为什么先做这个**：核实后发现 Sirius 今天还不是一个可嵌入的库（`../reference/sirius-ffi.md`
的「三个阻断性缺口」），而 ADR-006（进程内 vs 边车）的结论建立在「能嵌入」这个假设上。
在信息不足时硬定 A/B 是错的，先把工作量和风险量化出来。

**产出**：`plan-doc/embeddability-study.md`，回答下列每一条，每项给**代码量量级估算**
（不要求精确，要求可用于决策）。

### [x] P0.1 · 产物现状盘点 → 产出：study §2（vcpkg 单文件 DSO 已存在；缺 target/头/版本/发布，≈200 行 CMake/YAML）
- 今天 libsirius 到底是什么？CMake 里哪个 target 产出？有没有 `install()` target？
- `rust/crates/sirius-sys` 是怎么链的（cxx.rs + `SIRIUS_BUILD_DIR` 指向 build tree）？
  这说明现有嵌入方式的前提是什么？
- 从「build tree 内共编」到「可分发 .so + headers」，缺哪些步骤

### [x] P0.2 · C ABI 改造面 → 产出：study §3（19 个入口，shim ≈800 行生产，不动内部；异常跨界实测必崩）
- 盘点 `sirius_ffi.hpp`：几个类、几个方法、跨界传了哪些 std 类型、哪些会抛异常
- 设计 C ABI 映射：不透明句柄 + 错误码 + 出参；异常在边界内捕获转错误码
- **估算**：shim 行数、Sirius 侧改动面、是否需要动内部实现

### [x] P0.3 · 输入口 `push_arrow` → 产出：study §4（FFI 胶水 ≈150 行 + 230 行测试，不动 cuCascade；H2D 拷贝必须）
- `stream_session::push` 收 `cucascade::data_batch`；Arrow C Data → `data_batch` 的转换
  应该做在哪一层？
- cuDF 有没有现成的 `from_arrow_host` / `from_arrow_device`？RAPIDS 的 Arrow interop 现状
- 内存所有权：外部 Arrow buffer 的生命周期怎么和 Sirius 的 tier 管理对上（能否零拷贝 pin，
  还是必须先拷进 GPU/host tier）
- **估算**：行数 + 是否触碰 cuCascade

### [x] P0.4 · 依赖闭包与符号冲突 → 产出：study §5 + `experiments/p0.4-symbol-isolation/`（真实产物 × 真实 BE 预加载实测 + 90 例合成矩阵；冲突面是 libstdc++，不是 protobuf/abseil）
- 列出 libsirius.so 的完整运行时依赖闭包
- 与 Doris BE 的重叠清单及版本差（已知：**protobuf — Doris 固定 21.11 vs conda libprotobuf**；
  **abseil** 两边都有；**arrow** — Doris `thirdparty/arrow-24.0.0`；openssl / curl / spdlog / sqlite）
- 同进程两份 protobuf + 两份 abseil 的具体后果（全局注册表、静态初始化顺序、inline 函数 ODR）
- 缓解手段调研 + **实测**：全静态链接 + `-fvisibility=hidden` + version script、
  `RTLD_LOCAL` / `RTLD_DEEPBIND`、符号版本化
- **结论必须明确**：进程内方案在依赖层面是否可行；如可行，代价是什么

### [x] P0.5 · 打包与分发 → 产出：study §6
- conda / tarball / 其它？版本与兼容性策略？
- Doris 的构建怎么拿到 headers（vendored / submodule / 包管理）

### [x] P0.6 · 边车方案的对照估算 → 产出：study §7（Doris 已有 Python UDF 的 Flight 边车先例；≈3.5–5k 行；MVP-1/2 传输放大 1.5–3×，MVP-3 归零）
- wire protocol 定义 + 共享内存 Arrow 传输 + worker 进程，各需多少工作量
- 数据面多一次拷贝的代价量化
- **这个 worker 不是 Doris 专属的** —— 协议是「Substrait 进、Arrow 出」，
  它是通用的「libsirius as a service」。按这个定位估算

### [x] P0.7 · 汇总与建议 → 产出：study §8（代码量表、风险表、A/B → ADR-010、诉求清单、本机可验证/不可验证）
- 代码量总表（Sirius 侧 / Doris 侧分开）
- 风险表
- **A/B 建议**，用于更新 ADR-006 / ADR-009
- **对 Sirius 的诉求清单**，直接作为英文提案的素材

**验收**：`embeddability-study.md` 能回答「把 Sirius 变成可嵌入运行时库需要做多少事、
风险在哪、值不值得」，且 P0.4 有实测结论而不只是文献调研。

---

## MVP-0 · 离线验证（零侵入）

> 不被 P0 阻塞：全程不涉及链接 libsirius。可与 P0 并行。

依赖链：`M0.1 → M0.2 → M0.3 → {M0.4, M0.5} → M0.6 → M0.7 → M0.8`

### [x] M0.1 · BE 侧 fragment dump 能力 ← **由轨 1 P0.6 替代完成（2026-09-18）** → 产出：`experimental/doris/src/params.rs::dump_batch`（伪 BE 侧落盘；真 BE 侧的 `dump_fragment_params_dir` 改进不再需要）
把 BE 收到的 `TPipelineFragmentParams` 落盘，作为翻译器的输入语料。

- **落点**：`wt-gpu`，BE config 新增 `dump_fragment_params_dir`（默认空 = 关闭）
- **挂载点**：`be/src/exec/pipeline/pipeline_fragment_context.cpp` 的 `prepare()`，
  或更早的 `FragmentMgr::exec_plan_fragment`。用 thrift 的 `TJSONProtocol` 序列化成人可读 JSON
- **注意**：dump 是调试能力，不能影响正常路径性能；config 为空时零开销
- **验收**：跑一条 `SELECT count(*) FROM lineitem`，`dump_fragment_params_dir` 下出现可读的
  JSON，能看到 `fragment.plan.nodes` 的扁平先序数组
- **附加价值**：这条本身就是给 Doris 提的改进建议之一（`design.md` §7.7），可以独立提 PR
- 规模：S（1–2 天）

### [x] M0.2 · 采集 TPC-H fragment 语料 ← **由轨 1 P0.8 完成（2026-09-18）** → 产出：`experimental/doris/tests/fixtures/tpch/`（22 条，`INDEX.md`；官方 FE 4.1.4，不需要编 Doris）
- **前置**：`environment.md` 的 wt-gpu 初始化 + `./build.sh --be --fe`
- **做法**：本地起单 FE + 单 BE（走 `doris-dev-deploy` skill），建 TPC-H SF1 表，
  跑完 22 条查询，收集全部 fragment dump
- **产出**：`plan-doc/corpus/tpch/q<N>-frag<M>.json` + 一份 `corpus/INDEX.md`，
  标注每个 fragment 的形状（根 sink 类型、算子序列、叶子类型）
- **为什么重要**：这份语料是后续所有单测和 golden 测试的输入。**不要用手写的假 fragment 做主要用例**，
  真实 plan 的形状（projection 展开、common subexpression、intermediate tuple）比想象的复杂
- **验收**：22 条查询语料齐全；INDEX.md 能回答「哪些 fragment 形状是 MVP-1 的目标」
- 规模：M（2–3 天，大头在起集群和造数）

### [ ] M0.3 · 翻译器骨架
- **落点**：`wt-gpu:be/src/exec/gpu_offload/translator/`（见 `decisions.md` ADR-003：直接写 C++，不用 Rust 中转）
- **内容**：
  - 扁平先序树重建：`PlanNodeCursor` / `ExprNodeCursor`，按 `num_children` 递归消费
  - **不变式**：消费完必须恰好用光整个 slice，多一个少一个都报 `MalformedPlan`。
    这条不变式是所有后续 translator 的前提，任何新增节点翻译都必须保持
  - 结构化错误类型：`UnsupportedPlanNode{node_id, node_type, reason}` 等，错误信息要指名道姓
- **参考**：`sirius/experimental/starrocks/crates/starrocks-plan-translator/src/lib.rs` 的 crate 文档
  写清了同一套不变式，值得先读一遍
- **验收**：能把 M0.2 的语料解析成树；构造 3 个畸形输入（子节点数错、有尾节点、欠消费）都被拒绝且报错清晰
- 规模：M（3–4 天）

### [ ] M0.4 · descriptor table 与 slot 全局索引
- **内容**：`TDescriptorTable` → `(tuple_id, slot_id)` → 关系的全局列索引
- **⚠️ 已知坑**：StarRocks 集成在这里连踩两次（`15e8f6b8` 按 (tuple_id, slot_id) 联合键、
  `1fd20963` 引入 SlotKey 类型）。**slot_id 在不同 tuple 间不唯一，必须用联合键。**
  多输入算子（join）的右侧 slot 索引 = 左侧宽度 + 右侧局部索引
- **验收**：单测覆盖——单 tuple、多 tuple、join 两侧 slot 解析、slot 不存在时报错
- 规模：S（2 天）

### [ ] M0.5 · 类型映射 + type gate
- **内容**：`TTypeDesc` → Substrait Type / DuckDB 类型名字符串；拒绝表见
  `reference/semantics-gaps.md`
- **必须拒绝且各有一个负向单测**：`LARGEINT`（Sirius 静默截断，最高优先级）、`DECIMAL256`、
  `DECIMAL(p≤4)`、`HLL`/`BITMAP`/`QUANTILE_STATE`/`AGG_STATE`、`JSONB`/`VARIANT`、
  `IPV4`/`IPV6`/`VARBINARY`/`TIMESTAMPTZ`、`ARRAY`/`MAP`/`STRUCT`、`DATE`/`DATETIME`(v1)、`DECIMALV2`
- **验收**：白名单类型全部有正向用例，拒绝表每条有负向用例
- 规模：S（2 天）

### [ ] M0.6 · 表达式翻译
- **范围**：`SLOT_REF`、各 `*_LITERAL`、`BINARY_PRED`、`COMPOUND_PRED`、`CAST_EXPR`、
  `IS_NULL_PRED`、`ARITHMETIC_EXPR`、`IN_PRED`、`CASE_EXPR`、`LIKE_PRED`、
  `FUNCTION_CALL`（仅白名单）
- **⚠️ 语义门**：`concat` 硬拒绝（NULL 语义不同）、`like` 仅接受常量且不含转义的模式、
  `substring` 仅接受常量正 start/len。理由和出处见 `reference/semantics-gaps.md`
- **验收**：每个表达式类型有正向单测；三条语义拒绝各有负向单测
- 规模：M（4–5 天）

### [ ] M0.7 · 算子翻译（最小集）+ 端到端出 Substrait
- **范围**：`AGGREGATION_NODE`（仅非 merge 阶段）→ `AggregateRel`；
  `SELECT_NODE` → `FilterRel`；叶子 → `ReadRel{NamedTable{"sirius_stream_<k>"}}`；
  节点 `conjuncts` → `FilterRel`；节点 `limit` → `FetchRel`
- **产出**：一个独立命令行工具 `doris_plan_to_substrait <fragment.json> -o <plan.substrait>`，
  同时能以文本形式打印（便于人读）
- **验收**：TPC-H Q1、Q6 的聚合 fragment 能翻出完整 Substrait，文本输出人工核对无误
- 规模：M（4–5 天）

### [ ] M0.8 · 在 GPU 机器上实跑验证 🔒需要 GPU
- **前置**：一台 Linux + NVIDIA GPU 机器，编出 Sirius
- **做法**：把 M0.7 的 Substrait 喂给 `sirius::ffi::Context::execute_substrait`，
  输入数据先用 parquet 版 lineitem（绕开 stream 输入，MVP-0 只验翻译正确性）
- **验收**：Q1 / Q6 的结果与 Doris CPU 逐行一致 → **MVP-0 完成**
- **产出**：`handoff.md` 记录 GPU 机器的访问方式与环境状态
- 规模：M（2–3 天，含环境搭建）

---

## MVP-1 · 端到端最小闭环（未展开）

卸载形状：单阶段 `AGGREGATION_NODE` over 任意叶子。默认关闭，`enable_gpu_execution` 打开。

- [ ] M1.1 · `Block::export_to_arrow_c()` 零拷贝导出（Doris 侧独立可合入改进）
- [ ] M1.2 · Arrow → Block 反向桥接
- [ ] M1.3 · `SiriusOffloadSource/SinkOperator`
- [ ] M1.4 · plan 重写挂载点 + 子树最大化算法 + L1/L2 回退
- [ ] M1.5 · `runtime/`：dlopen libsirius、槽位准入、in-flight 限流
- [ ] M1.6 · session var `enable_gpu_execution` + FE 透传
- [ ] M1.7 · 差分测试 suite 🔒需要 GPU
- **验收**：Q1/Q6 端到端跑通、结果一致、回退 100% 可靠。**不追求性能**

## MVP-2 · 覆盖率与第一份诚实数据（未展开）

- [ ] `HASH_JOIN_NODE`（inner / left outer / left semi / left anti）
- [ ] `SORT_NODE` top-n
- [ ] 两阶段聚合的 merge 阶段
- [ ] golden 契约测试（抓 Nereids plan 形状漂移）
- **验收**：TPC-H 22 条全跑通、结果全对；SF100 逐查询对比表，**含变慢的查询**

## MVP-3 · 消除 H2D 瓶颈（未展开）

- [ ] `FILE_SCAN_NODE` 叶子下沉为 Substrait `local_files`
- [ ] 参考 `sirius/experimental/starrocks/.../scan_paths.rs` 的 fail-closed 校验
- **验收**：第一次有资格谈「x 倍加速」

---

## 贯穿全程的规矩

1. **每个 fail-closed 拒绝分支都要有一个负向单测。** gate 是执行期不回退的唯一防线
   （`design.md` §4.5），漏判等于查询失败或错误结果。
2. **单测不许依赖 GPU。** 依赖了就说明代码放错了层（`environment.md`）。
3. **发现语义差异立刻记进 `reference/semantics-gaps.md`**，同一个 commit 里补上 gate 和负向用例。
4. **不要提前写 MVP-2 的算子。** 每一期的价值是消掉下一期依赖的不确定性，跳级只会把风险堆到后面。
