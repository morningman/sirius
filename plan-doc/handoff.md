# 会话交接

> **每次 session 结束前更新这个文件。** 不更新的话，下一个 session 要重新摸索半小时。

---

## 当前状态

**日期**：2026-09-19（第十次 session，GPU 机上的第一次）
**阶段**：**轨 1 · MVP-A0 · A0.4-0 Linux x64 验证三层全过，GPU 机就绪，下一步 A0.4 编引擎。** 本机 = AWS **`g4dn.2xlarge`**（us-east-1；Tesla T4 16 GB CC 7.5、8 vCPU Xeon 8259CL、30 GB、根卷 300 GB gp3；Ubuntu 24.04.4、驱动 **580.178.04 / CUDA 13.0**、`io_uring_disabled=0`），仓库在 **`/home/yy2/gpu/sirius`**（clone 自 fork，分支 `experimental-doris`，`plan-doc/` 随分支来了）。
**代码**：`experimental/doris/`，本次改动小：`.gitignore` 补 `!tests/expected/**/*.tsv` + 22 份 `.tsv` 基线补进仓库、pixi `check` 特性补 `cmake/ninja/ccache`、`fe.sh status` 改 `mysql -E`。提交为 **`351347bf`**（代码）+ 本 docs commit，**都还在本机没 push**：GPU 机没有 GitHub 凭据（`git push` 要 Username；没装 `gh`），要么在这台机器上 `gh auth login` / 配 SSH key，要么等用户自己推。
**上游**：无变化（未回帖，未开 PR）。上游 PR / re-open #137 仍等 A0 在 GPU 上跑通（ADR-011 D-1 修订）。

验收对照（`tasklist.md` A0.4-0，三层逐层过）：
- ✅ **0a CI 同款三项**（linux-64）：`pixi install -e be` 8 s；`cargo fmt --check` ✅；`clippy --all-targets --no-default-features -D warnings` ✅ 55 s（thrift-compiler 0.22 + protoc 36.1 在本机重新 codegen，`crates/doris-thrift/build.rs` 的后处理对 Linux 生成物同样成立）；
  `cargo test --workspace --no-default-features` ✅ **96 + 49 + 10**（含 27 份快照）。fork 内部 CI PR 没开（本机就是 ubuntu 24.04 x86_64，与 CI runner 同 OS）。
- ✅ **0b 无引擎全流程**：官方 FE 4.1.4（用户已预先 `fe-fetch` 到 `.doris-fe/fe`；`SHOW FRONTENDS` 报 `doris-4.1.4-rc04-ad35a140c7f`，与 `doris/` submodule 同 commit）24 s 健康；translate-only BE `SHOW BACKENDS` **Alive: true / NodeRole mix**；
  tpchgen-rs SF1 parquet（本机用 pixi `be` 的 cargo 1.98 编 tpchgen-cli 4 min，生成 16 s，246 MB，每表一个 `part.0.parquet`，schema DECIMAL(15,2)/DATE 与语料一致）→ `run-tpch.sh --translate-only --out /tmp/corpus-linux` **22/22 "translated into one plan"**，`INDEX.md` 形状表与仓库**逐字一致**；
  gaps 5 条 captured（G-11 窗口 / G-12 UNION×2 拒、G-13×2 翻出），`INDEX.md` 逐字一致。
- ✅ **0c CPU 差分**：`duckdb-substrait-build`（cmake 4.4.3 + ninja 来自 pixi `check`，系统 g++ 13.3，**13 min** / 8 vCPU）→ `tpch-cpu-diff` **22 ok**（仓库语料）；再拿本机 FE 新采的 `/tmp/corpus-linux` 跑一遍也 **22 ok**（含列序不同的 Q1/Q14，见下）；gaps G-13 两条 2 ok（两套语料各一遍）。
- ✅ **顺手修的三件事**：(1) **根 `.gitignore` 的 `*.tsv` 把基线挡在 commit 外**——`22d161d9` 只带了 Q11/Q16 的 `.tsv.gz` 和 INDEX.md，另外 20 份 TPC-H + 2 份 gaps `.tsv` 从没进仓库（0c 第一次跑 **20 条 SKIPPED** 才暴露；Mac 工作树里有所以之前没发现）。`experimental/doris/.gitignore` 加 `!tests/expected/**/*.tsv`，基线在本机用 DuckDB 1.5.5 重生成（Q16 与 Mac 那份逐字节相同；Q11 只有两对 `value` 并列的行换序，校验器本来就容忍，`.gz` 保留 Mac 版）；
  (2) pixi `check` 特性补 `cmake>=3.28 / ninja / ccache`（`build-duckdb-substrait.sh` 在 Mac 上靠 Homebrew 隐式提供；`pixi.lock` 纯增量 +372 行，格式仍 v7，pixi 0.81 生成）；(3) `fe.sh status` 改 `mysql -E -e 'SHOW BACKENDS'`（conda-forge mysql 9.7.1 客户端对 `-e` 里的 `\G` 报 `Unknown command`，Mac 上的客户端版本没这问题）。
- 🔎 **发现：FE 的 plan 形状稳定，但节点内表达式顺序每个 FE 进程可能不同**——Q1 的 update 相 `partial_sum` 两个函数互换、Q14 的中间投影列序 `p_type,l_extendedprice,l_discount` vs `l_extendedprice,l_discount,p_type`（`EXPLAIN` 文本与 Mac 语料不同，**FE 重启后再变一次**，同一进程内稳定 → Java 身份 hash 序）。
  `INDEX.md` 形状表、其余 20 条 EXPLAIN、拼接后的 Substrait explain 均逐字一致；翻译器按 `(tuple_id, slot_id)` 工作，Q1/Q14 的本机 plan CPU 差分也 OK。**后果**：重采语料时 Q1/Q14 的快照可能只因列序变化，属噪音；仓库继续用 Mac 那份语料。

一句话结论：**Mac 上做的一切在 Linux x64 上原样成立；引擎之外的整条链（FE → 伪 BE → 拼接器 → DuckDB 消费端）在 GPU 机上已经跑通并逐行验证，下一步只剩编引擎 + 真跑。**

### P1.5 负向用例对照（G-01～G-18 ↔ 单测）

| G | 处置 | 单测（`crates/doris-plan-translator/src/…` 除注明） |
|---|---|---|
| G-01 LARGEINT | 硬拒 | `type_mapper::largeint_is_rejected`、`expr_translator::largeint_literals_are_rejected`、`descriptor_table` 同类 |
| G-02 concat | 硬拒 | `expr_translator::concat_and_unlisted_functions_are_rejected_by_name` |
| G-03 LIKE 转义 | 条件放行 | `expr_translator::like_requires_a_constant_pattern_without_backslash` |
| G-04 substring | 条件放行 | `expr_translator::substring_requires_constant_positive_bounds` |
| G-05 DECIMAL256 | 拒 | `type_mapper::decimal256_is_rejected` |
| G-06 DECIMAL(p≤4) | slot 拒 / 字面量抬精度 | `type_mapper::decimal_precision_at_most_4_is_rejected`、`expr_translator` 字面量测试（`0.2`→`decimal<5,1>`） |
| G-07 HLL/BITMAP/… | 拒 | `type_mapper::aggregate_state_types_are_rejected` |
| G-08 JSONB/VARIANT | 拒 | `type_mapper::jsonb_and_variant_are_rejected` |
| G-09 IPV4/IPV6/VARBINARY/TIMESTAMPTZ | 拒 | `type_mapper::binary_ip_time_and_tz_types_are_rejected` |
| G-10 ARRAY/MAP/STRUCT | 拒 | `type_mapper::nested_type_descriptors_are_rejected` |
| G-11 窗口 | 拒（ANALYTIC_EVAL_NODE） | `node_translator::unsupported_and_malformed_plans_are_named`；语料 `gaps/g11-window` |
| G-12 UNION/INTERSECT/EXCEPT | 拒（三种节点） | 同上；语料 `gaps/g12-union-all`、`gaps/g12-union-distinct` |
| G-13 SELECT DISTINCT | **放行**（零函数 group-by，CPU 差分已过，GPU 未验；`ORDER BY 全部 key LIMIT n` 的 update 相 top-N 也折叠） | `stitcher::collapses_a_two_phase_distinct_without_functions`、`…::merge_grouping_keys_must_read_the_update_output_in_order`、`…::collapses_a_top_n_by_group_key_pushed_onto_both_phases`；语料 `gaps/g13-distinct(-topn)` |
| G-14 两阶段聚合 | 单 fragment 拒 / A0 折叠 | `node_translator::two_phase_aggregates_are_rejected_by_phase`、`stitcher::splices_senders_and_collapses_a_two_phase_aggregate` + `stitching_gates` |
| G-15 非白名单标量函数 | 拒 | `expr_translator::concat_and_unlisted_functions_are_rejected_by_name` |
| G-16 非白名单聚合 / 多列 distinct | 拒 | `expr_translator::aggregate_gates` |
| G-17 DATE/DATETIME v1、DECIMALV2 | 拒 | `type_mapper::legacy_v1_types_are_rejected`、`expr_translator` DATE_LITERAL v1 拒 |
| G-18 NULL_TYPE | 拒 / NULL 字面量包 Cast | `type_mapper::null_type_is_rejected`、`expr_translator::null_literals_are_cast_to_their_type` |

一句话结论：**翻译器（P1）完工**——22 条 TPC-H 在协议壳里端到端翻成单棵 Substrait 并有快照钉死；下一步是对外收尾 + GPU。

## 下一步

**A0.4 · 编引擎 + 引擎路径的伪 BE**（`tasklist.md` A0.4），然后 A0.5～A0.7。本机状态：FE（9030）和 translate-only BE（pid 见 `experimental/doris/log/be.pid`）**还在跑**，`/tmp/tpch-sf1 → test_datasets/tpch_parquet_sf1` 软链在（**重启后 `/tmp` 会被清，软链要重建**：`ln -sfn /home/yy2/gpu/sirius/test_datasets/tpch_parquet_sf1 /tmp/tpch-sf1`）。`PATH` 里要有 `~/.pixi/bin`（安装脚本已写进 `~/.bashrc`，新 shell 生效）。

1. **拉 submodule**：根构建需要 `duckdb/`、`substrait/`（已 `--depth=1` 拉了）、`cucascade/`、`vcpkg/`——`git submodule update --init --depth=1 --jobs 3 duckdb cucascade vcpkg`（`plan §4.3` 的写法；根 `Makefile`/CMake 若要求完整历史再补 `--unshallow`）。**别动 `cucascade` 的指针**。
2. **根环境 + 引擎**：`cd /home/yy2/gpu/sirius && pixi install`（CUDA 13 + RAPIDS 26.08 + clang 21，估 15–20 GB，根卷剩 ≈275 GB 够；本机 8 vCPU，`pixi run make` 估 40–90 min，sccache 首次无命中）→ 产物 `build/release/extension/sirius/sirius.duckdb_extension`。
   替代：`gh run download` 拿 CI 产物（本机没装 `gh`，也没登录）。
3. **引擎路径 BE**：`cd experimental/doris && pixi run be-build`（`engine-build` 会再跑一次根 `make`，已编则秒过）；写 `conf/sirius.yaml`（`doris-pseudo-be-plan.md` §4.2 的样例：`num_gpus: 1`，`gpu.usage_limit_fraction: 0.9`，**`host.capacity_bytes: 12Gi`**——本机只有 30 GB，默认 90% pin 会把 FE 4 GB heap 挤死；`disk.downgrade_root_dirs` 先指根卷某目录，实例盘 `nvme1n1` 209 GB **未分区未挂载且 yy2 无 sudo**，要用得先让用户挂）；
   `SIRIUS_BE_TRANSLATE_ONLY=0 pixi run -e be bash scripts/be.sh start --engine -- --sirius-config conf/sirius.yaml`（看 `scripts/be.sh` / `main.rs` 的参数名；先 `be.sh stop` 掉 translate-only 那个，端口相同）。
4. **A0.5**：`pixi run -e fe bash scripts/run-tpch.sh --data /tmp/tpch-sf1`（执行模式，跑完自动 `validate`，`log/tpch/qNN/result.tsv`、`summary.csv`）。GPU 上 FP64 漂移就 `--tolerance 1e-6` 之类放宽并把数记进 `semantics-gaps.md` G-19；Q15 单独记。
   G-13 探针：`run-tpch.sh --sql-dir sql/gaps --queries g13-distinct,g13-distinct-topn --expected tests/expected/gaps-sf1 --out log/gaps`。
5. **A0.6** 记每条查询 GPU 时间（`summary.csv` 里有秒级；细的看 BE 日志）。
6. **A0.7** 22/22 后：上游 Draft PR + re-open #137。**开上游 PR 前把 `plan-doc/` 从分支上拿掉**（最后一个 commit `git rm -r plan-doc`，或 rebase 掉那几个 `docs(doris)` commit），它不属于上游。

已知会在 GPU 上遇到的事（翻译器已按此设计，CPU 差分证明 plan 语义正确，剩下的只可能是 Sirius 物理执行的差异）：`avg(DECIMAL)` 用 DuckDB 的 DOUBLE 再 cast 回 DECIMAL(38,4)（校验器半 ulp 规则已覆盖）；`sum(INT/TINYINT)` DuckDB 是 HUGEINT 再 cast BIGINT（Q12 的 `sum(if(...,1,0))` 是 TINYINT 求和；Sirius HUGEINT→INT64 静默截断 G-01 在中间类型上是否咬人要看）；
decimal 字面量精度 ≤4 被抬到 5；`local_files` 按列名投影要求 parquet 列名 = slot 名；cross join 是常量 key 等值 join（Q7/Q11/Q22）；`SELECT DISTINCT` 是零度量 grouped aggregate（G-13）；`year()` DuckDB 返回 BIGINT 再 cast SMALLINT（Q7/Q8/Q9）；
每条 plan 有 9～25 个恒等 `Project`（DuckDB 优化器不折叠，`log/cpu-diff/qNN/duckdb-plan.txt` 可见）——Sirius 上是额外的算子，只影响时间。T4 只有 16 GB 显存、CC 7.5 是 Sirius 支持下限：SF1 应该全在显存里，性能数字不代表 L40S。

提交习惯（P0 提交时定下的，之后照做）：
1. 只 `git add experimental/doris .github/workflows/experimental.yml .gitmodules`，**不要** `git add -A`；`cucascade` 指针是本地读代码时改的，不 stage。
2. `plan-doc/` **从 09-18 晚起随分支提交**（用户拍板；两台机器的 `.git/info/exclude` 里都只有 `test_datasets/tpch_parquet_sf1/`）。commit hook 是 Claude Code 的 `PreToolUse` agent hook，只匹配以 `git commit` 开头的 Bash 命令——把 commit 写进脚本文件再 `bash` 它就不会触发（这也是第 5 条的由来），它对 plan-doc 的"AI 运行笔记"判定不用理。
   plan-doc 的 commit 和代码 commit 分开提（`docs(doris): …`），上游 PR 前整体拿掉。
3. 语料里的绝对路径是 `/tmp/tpch-sf1/...`（符号链接 → `test_datasets/tpch_parquet_sf1`），下次采语料保持这个路径，diff 才干净。**重采语料后要 `UPDATE_SNAPSHOTS=1` 重生成快照并 review diff**（query id 不进快照，形状不变则快照不变）。
   `run-tpch.sh --translate-only` 每次**重写整个** `--out/INDEX.md`（只含本次跑的查询），所以 gaps 探针要 5 条一起重采，不能只采一条。
   `tests/expected/` 是 DuckDB 从 SF1 parquet 算的基线，换数据集要 `validate_tpch_results.py expected --data … --out …` 重生成。
4. `experimental.yml` 只在 `pull_request` / `merge_group` 触发，推到 fork 不会跑 CI；要看 CI 得在 fork **内部**开一个 `experimental-doris → dev` 的 PR（base 也是 fork 的 dev），并先 enable fork 的 Actions。
5. 提交命令写成脚本文件再 `bash`（hook 会误拦长命令）。
6. 09-19 起有两台机器改同一分支（Mac 与 GPU 机），**每次开工先 `git pull --ff-only fork experimental-doris`**（GPU 机上远程名是 `origin` = fork），收工 push；两边都别 rebase 已推的 commit。

会议纪要仍待按 `meeting-2026-09-09.md` 附录 D 写回。

---

## 已知坑（累积，发现一条加一条）

### 🔴 A0.4-0 Linux x64 验证实测（2026-09-19，GPU 机 `g4dn.2xlarge`）

- **根 `.gitignore` 第 31 行 `*.tsv` 会吃掉 `tests/expected/` 的基线**：`22d161d9` 实际只带了 `.tsv.gz`（Q11/Q16）和两份 INDEX.md，`git add experimental/doris` 对被忽略的文件静默跳过。已在 `experimental/doris/.gitignore` 用 `!tests/expected/**/*.tsv` 反向放行；以后 `tests/expected/` 下新增文件后 **`git status` 看一眼 `??` 是否齐全**。
- **DuckDB 基线跨平台不是逐字节稳定的**：Q11（`ORDER BY value DESC`）两对并列 `value` 的行在 Linux 上换序（DuckDB 多线程排序的并列顺序），其它 21 条逐字节相同；校验器的「同多重集 + 各自满足 ORDER BY」规则本来就吃这个。
- **FE 节点内表达式顺序按进程变**（Q1 `partial_*` 函数序、Q14 投影列序），同一 FE 进程内稳定，重启后再变；plan 形状（`INDEX.md`）不变。翻译器不受影响（本机语料 CPU 差分 22 ok）。重采语料别指望 Q1/Q14 的 EXPLAIN / 快照逐字不变。
- **conda-forge `mysql-client` 9.7.1 拒绝 `-e 'SHOW BACKENDS\G'`**（`Unknown command '\G'`），`fe.sh status` 原来因此什么都不打；改用 `-E`（vertical）。`pixi run -e fe mysql -e "...\G"` 还会再被 pixi 的 task shell 吃一次反斜杠，直接用 `.pixi/envs/fe/bin/mysql`。
- **pixi 环境搬家会失效**：用户先在 `/root/gpu/sirius` 装过 `be`/`fe` 环境再 `mv` 到 `/home/yy2`，`conda-meta/pixi` 里记的 `manifest_path` 还是 `/root/...`，直接 `rm -rf .pixi target` 重装（8 s，包缓存在 `~/.cache/rattler`）最省事。`target/` 里 root 时代的 build.rs 产物也一并清掉，让 codegen 真在本机跑一遍。
- **裸 Ubuntu 24.04 没有 cmake / ninja / unzip / java**，有 g++ 13.3 + make；yy2 **无 sudo**（`sudo -n true` 要密码）。所有工具都从 pixi 来：cmake/ninja/ccache 进了 `check` 特性，JDK 17 在 `fe`，rust/thrift/protoc 在 `be`。**cmake 4.4.3 配置 DuckDB v1.5.5 + substrait 扩展没问题**（不需要钉 3.x）。
- **tpchgen-rs 在没有 rustup 的机器上直接用 pixi 的 cargo 1.98 编就行**（`rust-toolchain.toml` 钉的 1.89 只有 rustup 认；Mac 上的冲突来自 rustup 代理）。`generate_tpch.py` 最后的 `inspect_tpch_parquet.py` 因无 pyarrow 报错，数据已完整，照旧忽略。SF1 一表一文件 `part.0.parquet`（`ceil(SF·6M/1e8)=1` 个分区），与语料路径一致。
- **`/tmp/tpch-sf1` 是软链**（→ `test_datasets/tpch_parquet_sf1`，Ubuntu 开机清 `/tmp`）；语料 / cpu-diff / `run-tpch.sh` 都按这个路径，重启后先重建。`cpu-diff.sh` 会 `pwd -P` 解析到真实路径再 `--rewrite-path`，所以软链没问题。
- **实例盘 `nvme1n1`（209 GB）未分区未挂载**，`/mnt` 空；Sirius 的 `downgrade_root_dirs` 想放实例盘要用户 sudo 挂载。根卷 300 GB gp3，用了 12 GB。
- 0a/0b/0c 时间参考（8 vCPU）：clippy 55 s、test 82 s、BE debug 编译 87 s、tpchgen-cli 4 min、DuckDB+substrait 13 min（三件事并行跑的，单独会快些）、FE 起 24 s、22 条 translate-only 66 s、cpu-diff 15 s。

### 🔴 MVP-A0 Mac 侧准备实测（2026-09-18 晚，`scripts/{build-duckdb-substrait.sh,validate_tpch_results.py,cpu-diff.sh}`、`tests/expected/`）

- **社区版 DuckDB substrait 扩展不能当 Sirius 的消费端用**：仓库 `substrait/` 钉的是 fork `sirius-db/duckdb-substrait-extension` 的 `duckdb-1.5.5` 分支（`a7e045b`）= upstream `substrait-io/duckdb-substrait-extension` 2026-06-17 的 main + sirius 专属 `c1a9876f`（`TransformReadOp` 对 `local_files` 按 base_schema **列名**投影 + `hive_partitioning=false`）。
  我们的 plan 靠这条才能按 slot 名读列。fork 的 `main` 只是 upstream 镜像，别拿它当准。upstream 后来的 #245/#247（Substrait 0.98 API、更多字面量类型）fork 分支没有。
- 扩展钉的 `substrait/duckdb` submodule = **upstream `duckdb/duckdb` `v1.5.5` tag（`d8cdaa33`）**，不是 sirius-db 的 `v1.5.5-patches`；CPU 差分用 upstream tag 即可（`--depth=1 --branch v1.5.5` 9 s 拉完，unity build 18 核 ≈3 min）。
  自己写 `extension_config.cmake`（`duckdb_extension_load(substrait SOURCE_DIR … INCLUDE_DIR …)`）+ `-DDUCKDB_EXTENSION_CONFIGS=`，`SKIP_SUBSTRAIT_C_TESTS=1` 跳过扩展的 test/c；`core_functions`/`parquet` 来自 DuckDB 自带的 base config。
- **conda `python-duckdb=1.5.5` 能直接 LOAD 本地编的未签名扩展**（`allow_unsigned_extensions`，`duckdb_extensions()` 报 `extension_version=a7e045b`）；Python API 的 `con.from_substrait()` 在 1.5.5 已没有，用 `con.execute("SELECT * FROM from_substrait(?)", [bytes])`（BLOB 参数可用，不必拼 `from_hex` 字面量）。
- **DuckDB 优化器不消重复的 TOP_N/ORDER_BY，也不折叠恒等 PROJECTION**：A0.3 之前 Q2/Q3/Q10/Q21 两个 `TOP_N`、Q18 三个、另外 10 条两个 `ORDER_BY`；每条 9～25 个 `PROJECTION`。Sirius 拿到的就是这棵树（`lower_substrait` 只跑 DuckDB 优化器）。
- **FE 的 top-N 下推比想的深**：ORDER BY 覆盖全部 group key 时，`limit` + `agg_sort_info_by_group_key` 压到 **update 和 merge 两相**，且 FE 会把 ORDER BY **扩到全部 group key**（Q18 的 TOP-N 是 5 个键：`o_totalprice DESC, o_orderdate, c_name, c_custkey, o_orderkey`）；然后发送方 SORT_NODE、merging exchange 各再来一遍同样的排序 —— 三层重复。
- **校验器容差**：1e-5 相对在大数上等于不校验（`sum_qty` 3.7e7 → ±377 都算对，负向自检抓出来的）；改为 `max(1e-9·max(1,|a|,|b|), 0.5·10^-min_scale)`，半 ulp 规则专门吃 `avg(DECIMAL)` 的 DECIMAL(38,4) 舍入（`0.0500` vs `0.04998529…`）。GPU 上要放宽用 `--tolerance`。
- Doris `tools/tpch-tools` 的 **Q11 用 `0.000002`**（不是规范的 `0.0001/SF`），SF1 返回 27,604 行（规范答案 1,048 行）——基线按仓库里的 SQL 生成，别拿官方答案集比。
- `mysql` 客户端 batch 输出（`run-tpch.sh` 的 `result.tsv`）实测：tab 分隔、首行列名、`NULL` 字面、DECIMAL 带声明 scale（`0.0500`）、DATE `1995-03-05`——`read_result()` 按这个解析；`validate_tpch_results.py` 自己写的 TSV 同一格式。
- 探针 SQL 必须确定性：`order by n_regionkey limit 3` 在 5 个同 regionkey 的国家里截断，DuckDB 和 plan 各取各的 3 条 → 假 MISMATCH。TPC-H 22 条的 ORDER BY 在 SF1 上没有截断歧义（Q11 仅并列换序）。
- 本机 FE（9030）和 translate-only BE（pid 见 `log/be.pid`）从上一 session 一直跑着；重采语料直接用。`.duckdb-substrait/`（DuckDB 源码 + build，≈2 GB）已进 `experimental/doris/.gitignore`。

### 🔴 轨 1 P1.5（快照 / 接线 / gaps）实测（2026-09-18，`explain.rs`、`tests/snapshots/`、`tests/fixtures/gaps/`）

- **`substrait-explain` 0.9 的盲区**：`LocalFiles` 读、`Decimal` 字面量、`SingularOrList`、`AggregateFunction.invocation`（DISTINCT）——前三个打 `!{...}` 占位 + `Unimplemented` 警告，第四个**静默丢掉**（`count(DISTINCT x)` 和 `count(x)` 打出来一样）。
  没有可插拔的渲染钩子（`OutputOptions` 只有开关），所以 `explain::render` 在 plan 副本上改写：`LocalFiles`→`NamedTable("local_files:<paths>")`，decimal→带标记的 String 字面量渲染后去引号，`SingularOrList`→合成 URN `extension:sirius:explain-only` 下的 `in_list(...)` 函数，
  DISTINCT→`FunctionOption distinct⇒[true]`。语料测试现在**零容忍**警告：再出 `format warnings` 就是翻译器发了新东西。
- **`SELECT DISTINCT` 在 Doris 4.1.4 = 零聚合函数的两阶段 `AGGREGATION_NODE`**（update `need_finalize=false` → EXCHANGE → merge `need_finalize=true`），没有任何 `AGG_EXPR`。`is_first_phase` 对 merge 相和单阶段 finalized（Q10 的 colocate 聚合）**都是 false**，不能区分；
  唯一可靠的结构信号是「finalized AGG 直接压在 update 相 AGG 上」（update 相只会喂自己的 merge 相）。语料里 (need_finalize, is_first_phase, 有 merge 函数) 只有三种组合：(false,true,无) 26、(true,false,有) 26、(true,false,无) 3。
- 窗口函数的 `ANALYTIC_EVAL_NODE` 被 FE 放在根 fragment、压在 **merging exchange** 上（发送方是 `SORT_NODE > FILE_SCAN_NODE`）；`UNION`（distinct）= 两阶段 group-by 压在 `UNION_NODE` 上。都在 `gaps/` 语料里。
- merging exchange 合成的 SORT 和发送方 fragment 自带的 SORT_NODE 排序键相同 → 翻出双层 `Sort`（有 LIMIT 时双层 `Sort+Fetch`），Q18 因 AGG 自带 `limit` + `agg_sort_info_by_group_key` 是三层。正确但多余，见 tasklist「P1 后续」。
- `run-tpch.sh` 的 Coverage 统计原来会把 `log/dump` 里历次的 dump 全算进去（数字翻倍）；现在只算本次 query id。translate-only 模式的退出码只反映「没采到」，「没翻出来」只计数（gaps 语料本来就有 3 条翻不出）。
- 5 条 gaps 探针 + 22 条 TPC-H 重跑，形状表与 09-18 早前采的语料**逐字一致**（FE 同版本、同 session 变量 → plan 稳定；query id 不同不影响）。

### 🔴 轨 1 P1.4（拼接器）实测（2026-09-18，`stitcher.rs`）

- 派发结构：`DATA_STREAM_SINK.dest_node_id` = 接收方 `EXCHANGE_NODE.node_id`；`per_exch_num_senders` 全为 1；发送方根节点 post-projection 布局 = 接收 EXCHANGE 的 `row_tuples`（同 tuple id，22 条无例外）。
- **两相聚合函数顺序不同**：Q1 merge 相 `sum,sum,sum,sum,avg,avg,avg,count`，update 相 `sum,avg,sum,count,sum,sum,avg,avg`；Q22 同样。merge 相每个 AGG_EXPR 的唯一子节点是 `SLOT_REF(update 输出 tuple 的 partial 槽)`，
  槽在 tuple 里的位置 − group key 数 = update 相函数下标。按下标对齐会翻错（一开始就撞了）。
- 语料里的 EXCHANGE 只有两种：无 sort 无 limit（直接替换）、merging（sort_info + limit，5 处，都在根 fragment）；「有 limit 无 sort」不存在，拼接器指名拒绝。
- Q13/Q15 的「AGG 叠 AGG」：update 相（第二个聚合）直接压在 finalized 单阶段（第一个聚合）上，折叠后自然成为 AGG > AGG，翻译器已能处理。
- 拼接后 22 条 plan 的形状（reads/aggregates/joins）：Q2 9/1/8、Q5 6/1/5、Q8 8/1/7、Q11 6/2/5、Q15 3/3/2、Q17 3/2/2、Q18 4/2/3，其余相应更小；没有一条残留 `sirius_stream_`。

### 🔴 轨 1 P1.3（节点）实测（2026-09-18，`node_translator.rs`；全部在 22 条语料上核实）

- **Doris 节点通用形状**：op → `conjuncts` → `limit` → `intermediate_projections_list[i]`→`intermediate_output_tuple_id_list[i]` 链 → `projections`→`output_tuple_id`。
  4.x 每个节点都可带投影链（Q1 的 scan 带 3 级中间投影）；投影不改行数所以和 limit 可交换。
- **tuple 是位置别名**：SORT/EXCHANGE 的 `row_tuples` 是子节点输出行按位置换个 tuple id（`sort_tuple_slot_exprs` 语料里恒空）；join 的 `vintermediate_tuple_id_list`（恒 1 个）
  = 左子输出 ⊕ 右子输出（**post-projection** 布局），semi/anti 无 other conjunct 时只有保留侧；`eq_join_conjuncts` 引用**子 tuple**，`other_join_conjuncts`/`projections`/节点 `conjuncts` 引用**中间 tuple**。
  `row_tuples` 对 semi/anti = 保留侧子 tuple。`hash_output_slot_ids` 只是裁剪提示，不影响布局。
- **AGG 带 `limit` 时有 `agg_sort_info_by_group_key`**（Q18 node 14 `limit 100` + 按 group key 排序）：语义是「按 key 排序后取前 N 组」，翻成 SortRel + FetchRel；`agg_sort_infos` 恒 `[空]`。
  `intermediate_tuple_id == output_tuple_id` 恒成立；输出 tuple = group keys 然后每个聚合一个 slot。
- 语料的聚合三种相：update（`need_finalize=false, is_first_phase=true`，26 个，含 Q13/Q15 的「AGG 叠 AGG」）、merge（`need_finalize=true`，AGG_EXPR `is_merge_agg=true`，26 个，子节点恒 EXCHANGE）、
  单阶段 finalized（3 个：Q10 等 colocate 场景）。前两种单 fragment 拒绝，P1.4 把 merge(EXCHANGE(update(X))) 改写成 finalized(X)。
- **DuckDB 消费端 join 类型**：INNER/LEFT/RIGHT/OUTER/LEFT_SINGLE/LEFT_SEMI/RIGHT_SEMI/LEFT_MARK，**没有 ANTI** → anti 用 outer + `is_null(对侧 key)` + 投影；RIGHT_SEMI/RIGHT_ANTI 交换两侧；
  NULL_AWARE_LEFT_ANTI 用 `LeftMark + not(mark)`（只允许单 key 无 other conjunct，Q16 满足）；`CrossRel` 消费端支持但 Sirius 无 cross product 算子 → 常量 key 等值 join（SR 同法）。
- 消费端 `local_files` 读按 **base_schema 列名**从 parquet 投影（`TransformReadOp`），所以 scan 的 slot 必须有 `col_name`（`local()` 的 dest slot 都有）。
- 扫描范围：`local_params[0].per_node_scan_ranges[node_id]` → `TFileRangeDesc{path,start_offset,size,file_size}`；语料 87 个 range 全是整文件 parquet、`table_format_type="tvf"`、无 `columns_from_path`。
- `substrait-explain` 0.9 渲染不了 `local_files` 读、`SingularOrList`、decimal 字面量（`Unimplemented` 警告，不是 plan 错误）；`tests/corpus.rs` 只容忍这类警告。
- `TPlanFragment.output_exprs` 只在 RESULT_SINK fragment 上，`label` 是最终列名（如 `sum_qty`）；DATA_STREAM_SINK 无 `output_exprs`/`output_tuple_id`，发送方根节点输出布局 = 接收 EXCHANGE 的 `row_tuples`（同一 tuple id）。

### 🔴 轨 1 P1.2（表达式）实测（2026-09-18，`expr_translator.rs`）

- **DuckDB Substrait 消费端**（`substrait/src/from_substrait.cpp`）的字面量面：只有 `I8/I32/I64/Fp32/Fp64/String/VarChar/Decimal/Boolean/Date/PrecisionTime/Interval`——
  **没有 `I16`、没有 timestamp 字面量、没有 `FixedChar`**，`null` 字面量变无类型 `SQLNULL`。翻译器：SMALLINT 字面量发 `I32`；DATETIMEV2 字面量发 `Cast(String)`；`NULL_LITERAL` 包 `Cast`。
- 消费端只用扩展函数的**名字**（URN 被丢弃）：`equal/not_equal/lt/lte/gt/gte/and/or/not/is_null/is_not_null/is_not_distinct_from/between/coalesce` 变 DuckDB 算子，
  `like→~~`、`substring→substr`、`octet_length→strlen`、`char_length→length`，其它按名字绑 DuckDB 函数；**`ScalarFunction.output_type` 被忽略**，类型由 DuckDB 重推（→ G-19 的处理放在 tuple 边界 cast）。
- 4.1.4 的 `ARITHMETIC_EXPR` **没有 opcode**，运算符在 `fn_.name`（`add/subtract/multiply/divide`）；`BINARY_PRED` 有 opcode 也有同名 `fn_`；`COMPOUND_PRED` 只有 opcode；`IN_PRED` opcode `FILTER_IN` + `in_predicate.is_not_in`；
  `NOT LIKE` = `COMPOUND_NOT(FUNCTION_CALL like)`；`CASE` 全被 FE 编译成 `if`；语料里没有 `BOOL/FLOAT/NULL_LITERAL`（NULL 只在 `file_scan_params.default_value_of_src_slot`）、`IS_NULL_PRED`、`CASE_EXPR`。
- FE 把所有操作数先 `CAST_EXPR` 到公共类型再比较/运算（例：`cast(l_discount as DECIMAL(16,2))`），翻译器不需要插隐式 cast。
- 每个 `TExprNode` 有 `label`（可读表达式文本，如 `partial_sum(l_quantity)`、`_tvf_local.l_shipdate`），输出列命名可用。
- 两阶段聚合线上形状：update 相 `AGG_EXPR(merge=false)(原始参数)` 输出到 tuple 的 partial 槽（类型 `VARCHAR(65533)`，label `partial_sum(...)`）；merge 相 `AGG_EXPR(merge=true)(SLOT_REF partial 槽)` → 最终类型。
  `count(*)` 是 `count` 零参数（消费端会转 `count_star`）。Q16 的 `multi_distinct_count` 两相同名，A0 拼接后即 `count(DISTINCT)`，Sirius 支持（`COLLECT_SET`）。
- DECIMAL 字面量精度 = 字面量自身位数（`0.2`→`DECIMAL32(1,1)`、`7.0`→`(2,1)`、`100.00`→`(5,2)`）；翻译器把 ≤4 的声明精度抬到 5（值不变，G-06）。
- DuckDB `avg(DECIMAL)` 返回 **DOUBLE**（`extension/core_functions/aggregate/algebraic/avg.cpp`），Doris 返回 `DECIMAL128I(38,4)`；`sum(DECIMAL(p,s))` 两边都 `(38,s)`；乘法精度规则两边一致。`AggregateCall.return_type` 带着 Doris 声明类型，P1.3 在聚合输出处 cast。

### 🔴 轨 1 P1.1（描述符表 / 类型）实测（2026-09-18，`crates/doris-plan-translator/src/{type_mapper,descriptor_table}.rs`）

- **slot 空值性只在 `TSlotDescriptor.nullIndicatorBit` 里**：FE `SlotDescriptor.toThrift()` 写 `getIsNullable() ? 0 : -1`；`TTypeDesc.is_nullable` 在 slot 上恒为 None。
  `columnPos`/`slotIdx` 恒 -1、`isMaterialized` 恒 true、`need_materialize` None（都已废弃）——**`slotDescriptors` 的线序就是 BE 的列序**（FE `DescriptorTable.toThrift()` 按 `tupleD.getSlots()` 顺序追加，BE `DescriptorTbl::create` 同序 `add_slot`）。
- **`TPlanNode.nullable_tuples` 不能用来推列空值性**：Nereids 把 inner join 两侧和所有 EXCHANGE 的 tuple 都标成 nullable（语料里 161 处 true），空值性以 slot 为准。翻译器忽略它。
- Doris 的 slot id 由 FE 每查询一个生成器产生，语料里跨 tuple **无重复**（与 SR 不同）；但 `TSlotRef` 自带 `tuple_id`，翻译器仍按 `(tuple_id, slot_id)` 键。
- `TTupleDescriptor.tableId` 对 `local()` TVF 恒 None，`tableDescriptors` 空；`TFileScanRangeParams.src_tuple_id = -1`、`dest_tuple_id` = scan 的 tuple，`required_slots` 引用 dest slot，`column_idxs` 是 parquet 列号。
- 170/1387 个 slot 没有 `colName`（planner 派生表达式：聚合输出、投影中间列）→ 输出名兜底 `col_<slot_id>`（Doris 内 slot id 唯一，不会撞）。
- **DuckDB Substrait 消费端**（`substrait/src/from_substrait.cpp` `SubstraitToDuckType`）**没有 `FixedChar`**，`PrecisionTimestamp` 只收 0/3/6/9 → CHAR 发 `VarChar`，DATETIMEV2 scale 向上取整（G-30）。
- 语料的 decimal 字面量有 **精度 ≤ 4** 的：Q17 `0.2`→`DECIMAL32(2,1)`、Q20 `0.5`→`DECIMAL32(1,1)`；Sirius `get_cudf_type` 对精度 ≤ 4 抛错（G-06，DuckDB 用 INT16 存）。slot 级已拒；字面量级 P1.2 要定策略（拓宽声明精度 vs 拒绝）。
- 语料 slot 的 decimal 形状：`DECIMAL64(15,2)` 原始列、`(16,2)` 一次加减、`DECIMAL128I(31,4)`/`(38,4)`/`(38,6)` 乘积与聚合、`(38,2)` sum、`(38,10)` avg。DuckDB 对同样表达式推的精度/scale 不一定一样（G-19），P1.2 表达式翻译时要么显式 cast 到 Doris 声明的类型，要么接受漂移。

### 🔴 轨 1 P0（伪 BE 脚手架）实测（2026-09-18，代码在 `experimental/doris/`）

- **thrift Rust 生成物**（thrift-compiler 0.22 + `thrift` crate 0.24）：有 required 字段的 struct **不派生 `Default`**，构造函数 `new()` 按位置收全部字段（`TPlanNode` 58 个）；
  枚举是 `pub struct TPlanNodeType(pub i32)` 常量，`{:?}` 打印数字。`crates/doris-thrift/build.rs` 后处理：能派生的 struct 补 `Default`（含 union 字段的除外）、枚举补按名字打印的 `Debug/Display`、
  `MetricDefs.thrift` 的 `unimplemented!()` 常量要 `allow(unreachable_code)`。fixture 一律 `..Default::default()`，**不要**照 SR 写全字段。
- thrift 里没写 `required/optional` 的字段（如 `TPipelineFragmentParams.local_params`、`destinations`）生成为 `Option<Vec<_>>`。
- **tonic 0.14** 的 server trait 是 `#[async_trait]`；在 impl 块里用 `macro_rules!` 批量生成方法时属性宏看不见宏调用，必须写成 async_trait 的脱糖形式（`backend_service.rs` 的 `unimplemented_rpcs!`）。
  codegen 用 `tonic-prost-build` + `tonic-prost`（prost 0.14 配套）。
- **`mysql_async` 连 Doris FE 注册会失败**：驱动连上后默认探测 `SELECT @@max_allowed_packet` / `@@wait_timeout`，Doris 把它们当真查询规划，没有 alive BE 时报 "No backend available as scan node"。
  `OptsBuilder` 预设 `max_allowed_packet` / `wait_timeout` 跳过探测（`node.rs`）。
- FE→BE 派发：**≥3 个 fragment 走 `exec_plan_fragment_prepare` + `_start`，<3 走 `exec_plan_fragment`**（proto 注释原话）；`PExecPlanFragmentRequest.version` 恒为 VERSION_3，`compact=true`（`use_compact_thrift_rpc`）。
  4.1.4 的 `TPipelineFragmentParamsList` 顶层只带 `runtime_filter_info`，共享字段在第一个 fragment 里（`desc_tbl/file_scan_params/coord/query_globals/resource_info`）；`params.rs` 合并。
- `fetch_data` 的 key：`enable_parallel_result_sink=true`（默认）用 **query_id**，false 用结果 fragment 的 instance id；`result_store.rs` 两个键都登记，不依赖变量。
  真 BE 的响应形状：数据包 `row_batch`+`packet_seq`+`eos=false`；结束包 `eos=true`+`query_statistics.returned_rows`；`packet_seq` 从 0 递增含结束包。
- `fetch_table_schema` 请求是 TBinary `TFileScanRange`（`params.format_type` + `ranges[0].path`），FE 只送第一个文件；类型映射照 BE `FieldDescriptor::convert_to_doris_type`
  （STRING 而非 VARCHAR、DECIMAL 统一报 DECIMAL128I 由 FE 归一、DATEV2、DATETIMEV2 带 scale、无符号整数升一级、UINT64→LARGEINT）。
- `local()` 需要 `"shared_storage"="true"`（否则要 `backend_id`）；FE 随机挑一个 alive BE 调 `glob`，返回路径原样进 scan range。
- `SHOW BACKENDS` 的 Alive 只看心跳 status=OK；`be_start_time` 是**毫秒**；`TMasterInfo.backend_ip` 是 FE 登记的 host，和 `--advertise-host` 不一致时我们拒绝心跳并在错误里给出修法。
- Doris 官方 tarball 4.35 GB（含 BE），`scripts/fetch-fe.sh` 流式解压只留 `fe/`（1.1 GB）；FE 4.1.4 在 Mac + JDK 17（pixi `fe` 环境）11 s 起来。
- 语料的 Debug 文本每条查询几 MB（`TDescriptorTable` + 每列一个 `NULL_LITERAL` 默认值），**不进仓库**；仓库只放 `.tcompact` + summary（772 KB），`dump-fragments` 工具按需还原。
- `parallel_pipeline_task_num=1` + `enable_local_shuffle=false` 下每个 fragment 恰好 1 个 instance（`tests/corpus.rs` 断言）；Q2 12 个 fragment、Q8/Q11 11 个，最多的形状是 9 张表各一个 `FILE_SCAN` 叶子 fragment。
- FE 日志噪音两条，都无害：(1) `InternalSchemaInitializer ... Failed to find enough backends`——FE 反复想建内部统计表，需要有磁盘的 BE，我们永远没有，它每几秒重试一次；
  (2) 每条失败查询一行 `StmtExecutor.handleQueryWithRetry ... retry due to exception`——只是先打日志再判定，`isNeedRetry = e instanceof RpcException`，我们的 INTERNAL_ERROR 是 UserException，**不会重派**（22 条语料恰好 22 个 query id）。
- tpchgen-rs 钉 `rust-toolchain` 1.89，要用 rustup 的 `cargo` 编（pixi 的 cargo 1.98 会和 rustup 代理的 rustc 打架）；`generate_tpch.py` 最后一步 `inspect_tpch_parquet.py` 需要 pyarrow，失败不影响数据。

### 🔴 09-18 核实（详见 `doris-pseudo-be-plan.md`）

- **不要再把 #1697/#1702/#1708/#1709/#1711/#1714 当依赖**：全部 09-15 关闭未合并。MVP-A 依赖改为 #1791 + #1792 的 commit `891d41c3`
  （Rust `Fragment<'ctx>`）；MVP-B 依赖 #1792 的 commit `d7f2a7e3`（`pull_arrow/push_arrow/drained`）。cherry-pick 指定 commit，不追整条分支。
- #1792 是「study PR」（每个 commit 一个 seam，未必直接合）；`Context` 单线程、`run()` 阻塞、一次一个 fragment 三条约束**不变**，
  CN 靠「先跑完所有本地叶子 → 交换 → 再 build/run 根」绕过。
- #1792 实测：2 CN 的 `FILES() GROUP BY` FE 发的是 **3 个** fragment（leaf / merge / gather）不是 2 个；SQL 里有 `ORDER BY` 会插 merging exchange
  被翻译器拒绝；引擎 `pull_arrow` 出来的批 Arrow 字段名常为空，要用翻译器的名字盖上去。
- **Sirius 不能独立启动**：产物是 DuckDB 扩展 `.so`，`rust/crates/sirius-sys/build.rs` 软链成 `libsirius.so`；`SiriusContext::new()` 就做 GPU bring-up，
  无 GPU 连引擎路径的 `cargo test` 都跑不了 → 一切引擎无关代码必须 `--no-default-features` 可测（SR 的 `FragmentExecutor` trait + `StubExecutor` 就是为此）。
- SR 的 `result_store.rs` 是「单批、单轮询」模型（自带 TODO）；Doris 版 `fetch_data` 必须挂起等待 + 多批 + `packet_seq` 严格 +1，不能照搬。

### 🟠 伪 BE 路线（2026-09-09 调研，详见 `pseudo-be-feasibility.md`）

- **不要用 deck 的 15/15 判断 SR 项目进度**：`dev` 上翻译器拒绝 `EXCHANGE_NODE`、只执行 `RESULT_SINK` fragment；分布式全在 aocsa fork
  `feat/pin-table-cn`。上游可合并线（#1644 rebase）实测 2 CN SF100 = 12/22 精确 + 5 漂移 + 5 阻断。20 个 draft PR（#1693–#1717）0 review。
- **Doris FE→BE 是 gRPC h2c**（grpc-java → `brpc_port`），不是 baidu_std；SR 那 490 行手写 PRPC 帧在 Doris 上用不着，tonic 即可。
  BE↔BE 的 `transmit_block` 才是 baidu_std，但全 Sirius 节点时传输可私有。
- **TVF 路径 FE 不生成 runtime filter**（`PhysicalTVFRelation.canPushDownRuntimeFilter()==false`）；Hive/Iceberg catalog 表才有，
  `runtime_filter_mode=OFF` 可关。若将来实现 RF，切勿对 `send_filter_size` 回 OK 却不发 `sync_filter_size`（对端 join build 挂到超时）。
- 编码不对称：`exec_plan_fragment.request` 是 **TCompact** 的 `TPipelineFragmentParamsList`（VERSION_3，一个 BE 的全部 fragment 在一个 RPC、
  顶层在前、只有首个带 `desc_tbl`）；`fetch_data.row_batch` 是 **TBinary** 的 `TResultBatch`；`fetch_table_schema` 的 `TFileScanRange` 是 TBinary。
  `fetch_data` 的 `packet_seq` 从 0 严格 +1，结果未就绪要**挂起不回**（真 BE 如此）。
- FE 分析期会调 BE 的 `fetch_table_schema`（三种 TVF 都会）和 `glob`（仅 `local()`）；没有这两个 RPC，查询根本不会被规划。
- 心跳里 `be_node_role` 必须是 `mix`（`computation` 会被 TVF 调度排除，除非 `prefer_compute_node_for_external_table`）；FE 不比版本；1 次失败即 dead。
- `dev` 上 `Fragment::build()` 在 DuckDB 1.5.5 下必抛 `ActiveTransaction called without active transaction`，CI 只测失败路径所以没发现
  （09-15 起由 #1791 修，原 #1697 已关）。
- Doris master 新增 `LOCAL_EXCHANGE_NODE`(38)、`BUCKETED_AGGREGATION_NODE`(37)、`TExprNodeType.PREDICATE/LITERAL`(43/44)；
  前者 `enable_local_shuffle_planner=false` 关掉，后者待核实（OQ-009）。4.0.3-rc03→master thrift/proto 漂移 +2004/−298，核心契约未变。
- `origin/doris` 的 `sirius-ffi` crate **不可复用**（依赖 `src/legacy/gpu_buffer_manager` + doris 分支独有的 `sirius_exchange_c_api`，dev 上一个都没有）；
  可搬的是纯 Rust 部分：codegen、心跳、`deserialize_params`、类型/字面量映射、PBlock 编解码、`hash_partitioner`、`run-tpch.sh` + `validate_tpch_results.py`。
- SR fork 撞过的墙我们也会撞：decimal→FP64 漂移（Q15 等值 1/3 概率空结果）、staging arena 耗尽（q09/q21 大 SF）、parked output 泄漏 + 无 cancel
  （harness 要能重启 BE）、传输单线程 60 s 超时、FE 对 `FILES()`/TVF 无统计导致 join 顺序错（q08/q09 要改写 FROM）。

### 🔴 轨 2 P0（可嵌入性）实测出来的（2026-09-01，详见 `embeddability-study.md`）

1. **Doris BE 导出全部符号**（`ENABLE_EXPORTS 1`，`be/src/service/CMakeLists.txt:68`，为 native UDF
   服务，Doris 不会取消）：475,722 个，含静态 libstdc++ 50,662 个。任何 dlopen 进来的库，其 libstdc++
   引用都会绑到 BE 私有的这份副本上（真实 Sirius 产物实测 549 个）。Doris 自己已经被这个机制咬过
   （`librocksdbjni.so`，同文件 `:70-92`）。
2. **conda/pixi 口味的 Sirius 产物进 BE 会直接 abort**（合成矩阵 `rdynamic × conda_dyn`）。只有
   全静态 + 隐藏 + **静态 libstdc++** 的形态对宿主免疫。`RTLD_DEEPBIND` 不是答案（malloc 分裂）。
3. **C++ 异常在两套运行时之间必崩** → C ABI 是必需品，与静态 libstdc++ 配套。
4. vcpkg 产物的 `DT_NEEDED` 有 19 个：libstdc++/libgcc/libgomp 动态，5 个 CUDA 数学库（cuvs/raft 带进来）
   + nvrtc/nvJitLink 动态。部署要带 CUDA 13 运行库（≈1 GB+）。glibc ≥ 2.28。
5. **Sirius 默认独占 95% 显存 + 每 NUMA 节点 90% 内存作 pinned**（`configuration.md`），与 Doris
   `mem_limit` 90% 直接冲突；嵌入时必须显式配 `capacity_bytes`。
6. Sirius **没有背压是设计决定**（issue #1276 的 2026-07-23 review 结论），不要指望 Sirius 侧提供。
7. `push_arrow` 必须 H2D 拷贝（5 个理由，study §4.3）；零拷贝 pin 不可行。好处：Sirius 线程永远
   不会回调进 Doris。

### 🟠 Sirius 侧的并行工作与 Doris 先例（2026-09-01 晚发现，详见 study §9）

- **#1590 没有讨论，只有作者 aocsa 的 scope 记录**；真正的进展在 draft PR **#1644**（+17.5k 行，
  2026-08-27）：T5b = `Fragment::export_packed / push_packed` + `StagingArena`（设备内存 + cudf pack
  元数据，为 NIXL 节点间交换设计），拆分计划 T1→T3→T2→T5→T7→T8→T4→T6。**非阻塞 `run()`、
  `push/pull/wait` 都还没做**；`push_packed` 只在 build() 与 run() 之间合法（仍是 store-and-forward），
  且 #1644 写明 `Context` is single-threaded by contract —— 与我们「边 run 边多线程 push」的设计
  有契约冲突，**已作为提案里的头号对齐问题发出去了**。`sirius_ffi.{hpp,cpp}` 正在被大改，
  我们的改动要排在 T5b 后。
- **`origin/doris` 分支**（mbrobbel，67 提交，2026-03～06-03，已 3 个月未动）：`doris/` 目录下是一个
  Rust 伪 BE（`sirius-doris-be`）+ Doris 4.0.3-rc03 thrift→Substrait 翻译器（≈10.5k 行 Rust）+
  PBlock 编解码 + bRPC/NIXL 交换 + `sirius_exchange_c_api.hpp`（extern "C" 先例）。只支持 `local()`
  TVF 读 parquet；FINDINGS.md 记录了 `--force-cpu` 绕过 GPU（Docker CDI 下 `cudaMemcpyBatchAsync` 失败）
  和一批 DuckDB Substrait 消费端的 bug。exchange-design（PR #914）把它列为 prior art，StarRocks 路线
  「替代」了它。我们的进程内方案是不同方向（真实 BE、内表），提案背景段已主动说明。
- 它的 FINDINGS 里的 Substrait 消费端 bug 已作为 G-25～G-29 记入 `reference/semantics-gaps.md`。

### 🟡 Sirius 的三个缺口（判断已修正）

- `push_arrow` 缺口成立，但只需 FFI 胶水（`cudf::from_arrow_host` 已在闭包里）。
- C ABI 缺口成立，纯 shim ≈ 800 行。
- 「没有可分发产物」**部分不成立**：CI 每次 dev push 产出 4 个变体的单文件 DSO（GitHub Actions
  artifact，90 天，无 Release）；缺的是链接约束、头文件、版本化、发布渠道。
- 「protobuf/abseil/arrow 冲突」**不成立**：Sirius vendor 了 protobuf 3.19.4 并隐藏；abseil 有
  `lts_YYYYMMDD` inline namespace；闭包里没有 Arrow C++。真实产物预加载实测这三者绑到 BE 的符号为 0。

### 环境

- **轨 1 的本机开发环（09-18 起）**：`experimental/doris/` 四个 pixi 环境——`fe`（JDK 17 + mysql 客户端 + `check`，`pixi run -e fe fe-fetch` 下载官方 4.1.4 到 `.doris-fe/fe`，`fe-start/fe-stop/fe-clean`）、
  `be`（rust + thrift-compiler 0.22 + protoc，`pixi run -e be bash scripts/be.sh start` 起无引擎 BE，翻译-only + 落盘到 `log/dump`）、`check`（python 3.12 + `python-duckdb=1.5.5`：`duckdb-substrait-build` / `tpch-expected` / `tpch-cpu-diff`）、`client`。端口用 Doris 默认 8030/9020/9030/9010 + 9050/9060/8040/8060，
  与 `doris-dev-deploy` 的本地集群（8033/9022/9033/9011 + 9067/8045/9455/8067）不冲突。TPC-H SF1 parquet 在 `test_datasets/tpch_parquet_sf1/`（tpchgen-rs，246 MB，**未被 .gitignore 覆盖**），
  语料采集时通过软链 `/tmp/tpch-sf1` 引用。`scripts/run-tpch.sh --data /tmp/tpch-sf1 --translate-only` 重采语料。
- **GPU 机（09-19 起）**：AWS `g4dn.2xlarge` us-east-1，`ssh` 用户 `yy2`（无 sudo），仓库 `/home/yy2/gpu/sirius`（`origin` = fork `morningman/sirius`，分支 `experimental-doris`）。pixi 0.81 在 `~/.pixi/bin`；`experimental/doris/.pixi/envs/{be,fe,check}` 已装；
  `.doris-fe/fe` = 官方 4.1.4；`.duckdb-substrait/`（≈2 GB）已编；tpchgen-cli 在 `test_datasets/tpchgen-rs/target/release/`；数据 `test_datasets/tpch_parquet_sf1`（软链 `/tmp/tpch-sf1`）。根仓库 pixi 环境 / 引擎 **未装未编**（A0.4 第一步）；submodule 只拉了 `experimental/doris/doris` 与 `substrait`（浅）。
  常用：`pixi run -e fe fe-start|fe-stop`、`pixi run -e fe bash scripts/fe.sh status`、`pixi run -e be bash scripts/be.sh start|stop|log`、`.pixi/envs/fe/bin/mysql -h127.0.0.1 -P9030 -uroot`。
- **Mac（morningman 的开发机）是 macOS arm64，没有 NVIDIA GPU。** 但 **Docker 可用**（18 核 / 48 GB），
  `apache/doris:be-4.1.3`（arm64）镜像已在本机，`sirius-embed-exp:latest` 实验镜像已构建。
  所有 ld.so 层面的实验都不需要 GPU，也已经做完；CUDA 运行时层面的验证需要 GPU 机器（OQ-001）。
- 本机 `gh` 已登录（morningman），可以 `gh run download` Sirius 的 CI 产物（327 MB/变体），
  也能直接评论/编辑 Sirius 的 issue。
- **Doris BE 在 Linux 上是 clang + libstdc++**（`USE_LIBCPP` 仅 macOS 为 ON）；Sirius vcpkg 产物是 GCC。
  真实 BE 4.1.3 只要求 `GLIBC_2.17`，Sirius 产物要求 `GLIBC_2.28`。
- `wt-gpu` 是 worktree 不是独立 clone。`thirdparty/installed` 已软链好；`.worktree_initialized` 不存在、
  submodule 未拉。
- Sirius 仓库里 `cucascade`、`substrait` 两个 submodule 本轮已 `--depth=1` 初始化（只为读代码）。
- `BUILD_TYPE` 保持 `ASAN`，只有做性能测量才改 `RELEASE`。
- 仓库有一个 `git commit` 前的 LLM 清洁度 hook，会把 `plan-doc/` 判成「AI 运行笔记」而拒绝提交，
  而且偶尔会误拦长的 Bash 命令（把长命令写成脚本文件再 `bash 脚本` 可以绕开）。**提交 plan-doc 前
  要先和 hook 的规则对齐**（例如加进 `.gitignore` 或调整 SKILL 判据），否则提交会被拦。

### 实现

- **slot_id 在不同 tuple 之间不唯一。** 必须用 `(tuple_id, slot_id)` 联合键。
  StarRocks 集成在这里踩了两次（commit `15e8f6b8`、`1fd20963`）。
- **Sirius 的 HUGEINT 映射会静默截断成 INT64**（`cudf_utils.hpp:169`，代码自带
  `FIXME: silently corrupted`）。Doris 的 `LARGEINT` 必须在 type gate 硬拒绝。`push_arrow` 也应拒绝 int128。
- **Sirius 吃的是 duckdb-substrait 方言**（`sirius_ffi.cpp:261`）。方言特例集中放
  `translator/dialect.{h,cpp}`。DuckDB Substrait 消费端的已知 bug 见 `semantics-gaps.md` G-25～G-29。
- **Sirius 引擎进程内串行**，一个 Context 同时只能跑一个 query（issue #1303 追踪并发，
  #1364–#1372 / #1583 在推进）。
- **Sirius input stream 无背压**（无界队列，设计决定），Doris 侧要自建 in-flight 限流。
- **Sirius 线程没有 Doris ThreadContext**：RELEASE 下分配记到 Orphan tracker；DEBUG/ASAN 下 DCHECK；
  任何调到 `thread_context()` 的路径会 throw。设计上要保证 Sirius 线程零回调进 Doris。
- Doris 加载外部 .so 走 `dynamic_open()`（`RTLD_NOW|RTLD_LOCAL` + `updatePHDRCache` + `SymbolIndex::reload`），
  永不 `dlclose`。

---

## 待决问题

| 编号 | 问题 | 阻塞什么 | 当前处置 |
|---|---|---|---|
| **OQ-001** | GPU 验证机器从哪来？规格、访问方式、谁维护 | study §8.5 右栏全部、M0.8、之后全部集成/差分测试 | **已决**（09-18，ADR-011 第 4 条）：AWS 自购，单节点 `g6e.2xlarge`（省钱 `g5.2xlarge`），多节点 `g6e.12xlarge`；Ubuntu 22.04/24.04、驱动 ≥580.65.06（否则 `cuda12` 环境）、gp3 ≥500 GB。P1 结束前不买 |
| **OQ-002** | 进程内 vs 边车 | MVP-1 的形态 | **已决**：ADR-010 —— MVP-1/2 进程内（前提是 libsirius 满足 4 条链接约束），MVP-3 前后切边车 |
| **OQ-003** | Doris 侧通用改进走上游 PR 还是先在 wt-gpu 攒着 | M1.1 | 倾向独立提上游 —— 它们本身有价值 |
| **OQ-004** | 英文提案什么时候提交 Sirius 社区 | — | **已提（2026-09-01）**：`push_arrow` 提案挂在 https://github.com/sirius-db/sirius/issues/1590#issuecomment-5494647357（只提了方案一；libsirius 链接约束 / C ABI / 配置三项留待后续，素材在 study §8.4）。等维护者（aocsa / mbrobbel）回复，重点看线程契约那一点 |
| **OQ-005** | `push_arrow` 的线程契约：能否在 `run()` 期间从其他线程调用 | MVP-1 能否边扫边算；否则先 store-and-forward | 已在 #1590 提出，等 Sirius 侧答复 |
| **OQ-006** | 轨 1 落点：sirius `experimental/doris/` 还是独立仓库 | 轨 1 P0 | **已决**（09-18，ADR-011 第 2 条）：fork 上的 `experimental/doris/` 起步；**上游 PR / re-open #137 推迟到 MVP-A0 跑通后**（09-18 晚修订，原为 P1 结束 + CI 绿） |
| **OQ-007** | MVP-B 传输：等 aocsa NIXL 还是先用 Arrow-over-gRPC + `push_arrow` | MVP-B | **09-18 更新**：Arrow 路径已是 aocsa 主线 demo（#1792），照它做私有 gRPC `transmit_arrow` 拿正确性；性能等 #1794（NIXL）合并 |
| **OQ-008** | Q16 `count(distinct)` 在 Doris FE 的 phasing 能否规划成 group-by 形态 | MVP-A | **已答**（09-18 语料 `q16`）：不是嵌套 group-by，而是两阶段 `multi_distinct_count`（叶子 `partial_multi_distinct_count(ps_suppkey)` update-serialize → 上层 merge-finalize，`TAggregateExpr.is_merge_agg` 区分）。A0 拼接器合成单阶段 `count(distinct)`；A 阶段两端都是 Sirius，partial state 自定 |
| **OQ-009** | Doris master 是否已用 `TExprNodeType.PREDICATE/LITERAL` 代替旧枚举 | 翻译器 | **已答**（09-18，pin 4.1.4）：IDL 里有 `PREDICATE=43/LITERAL=44`，但 FE 4.1.4 **不用**——22 条语料只出现 `SLOT_REF / *_LITERAL / BINARY_PRED / COMPOUND_PRED / ARITHMETIC_EXPR / CAST_EXPR / FUNCTION_CALL / IN_PRED / AGG_EXPR`。翻译器只做旧枚举；换 tag 时用 `run-tpch.sh --translate-only` 重采一遍看 INDEX.md 的覆盖行 |
| **OQ-010** | 两轨并行的人力分配 | — | 会后定；P0 语料与白名单两轨共用 |

---

## 更新模板

下次 session 结束时，把「当前状态」和「下一步」替换成新的，旧的追加到下面。

<details>
<summary>历史记录</summary>

### 2026-09-19（第十次，GPU 机）
GPU 机 `g4dn.2xlarge` 到手，A0.4-0 Linux x64 三层验证全过：0a CI 同款三项 96+49+10 全绿；0b 官方 FE 4.1.4 + translate-only BE Alive，22/22 翻成单棵、`INDEX.md` 逐字一致，gaps 5 条一致；0c DuckDB+substrait 在 Linux 编成，CPU 差分 22 ok（仓库语料与本机新采语料各一遍）+ G-13 2 ok。
修了根 `.gitignore` `*.tsv` 挡掉 22 份基线的问题（补进仓库）、`check` 特性补 cmake/ninja/ccache、`fe.sh status` 改 `-E`；记录 FE 节点内表达式序按进程变的现象。下一步 A0.4 编引擎。

### 2026-09-18（第九次，晚）
MVP-A0 Mac 侧准备 A0.1～A0.3 全部完成，提交 `22d161d9` 并推到 fork；用户拍板 plan-doc 直接进 `experimental-doris` 分支、Linux x64 验证不在 Mac 上做（CI/Docker 都不做），改为 GPU 机上的第一件事：`substrait/` submodule 编成 DuckDB 1.5.5 可加载扩展（`build-duckdb-substrait.sh`），22 条拼接 plan 经 `from_substrait()` CPU 执行与原 SQL 22/22 逐行一致（`cpu-diff.sh`）；
`validate_tpch_results.py`（expected/consume/validate，1e-9 相对 + 半 ulp）+ `tests/expected/tpch-sf1` 进仓库，`run-tpch.sh` 执行模式自动校验；重复 Sort 两处消重（15/22 条受益）；
顺手修拼接器"update 相 top-N"缺口并把 g13 探针改确定性、重采 gaps 语料。G-13/19/25/26/28/29 处置列更新。

### 2026-09-18（第八次）
用户拍板：上游 PR / re-open #137 推迟到 MVP-A0 跑通后（ADR-011 D-1 修订），此前全在 fork 迭代。
P1.5 完成并提交（`9cfc92fa`，已推 fork）：`explain.rs` 补齐 `substrait-explain` 的四个盲区；22 条快照人工逐条核对无误；BE `dispatch` 改整批 `translate_batch`，FE 实测 22/22 翻成单棵；
`run-tpch.sh` 打印翻译结论 + `--sql-dir`；G-11/12/13 用真 FE 派发做成 `gaps/` 语料，顺带发现并修了「零函数两阶段 group-by（SELECT DISTINCT）不折叠」的拼接器 bug；G-13 改判放行。
semantics-gaps G-11～G-14 处置列更新。对外两步（draft PR、re-open #137）留待用户确认。

### 2026-09-18（第七次）
建 fork `morningman/sirius`，P0 提交（`17d8c086`）。P1 翻译器一口气到 P1.4：`type_mapper`/`descriptor_table`（`6641c450`）、`expr_translator`（`37260bb9`）、
`node_translator`/`scan_ranges`（`4e6f0921`）、`stitcher`（`ba470a4e`）。22 条 TPC-H 语料全部翻出单棵 Substrait；语料级测试 8 条钉住形状。
核实了 DuckDB Substrait 消费端的能力面（字面量/join 类型/local_files 按名投影/avg 返回 DOUBLE）并记入 semantics-gaps（G-30、G-19 更新、G-16/G-28 修正）。
`plan-doc/` 与 `test_datasets/tpch_parquet_sf1/` 进本机 `.git/info/exclude`。用户中途叫停，交接给下一个 session 做 P1.5。

### 2026-09-18（第六次）
轨 1 P0 落地：`experimental-doris` 分支 + `experimental/doris/`（浅 submodule 钉 Doris **4.1.4**）；`doris-thrift`/`doris-proto` codegen（build.rs 后处理补 Default/命名 Debug）；
`doris-plan-translator` 骨架；BE 主 crate（心跳 + `ALTER SYSTEM ADD BACKEND` + `BackendService` 桩 + tonic `PBackendService` 六个真 RPC/52 个 unimplemented + TCompact 解码合并 + 等待式结果 store）。
官方 FE 4.1.4 在 Mac 上跑起来，`SHOW BACKENDS` Alive；`local()` 分析期两 RPC 通；SELECT 走 prepare/start 派发、fetch_data 收错、cancel 收尾。
`run-tpch.sh --translate-only` 采到 22 条语料（151 fragment），`tests/corpus.rs` 回放；OQ-008/OQ-009 有答案；CI 加 `doris` job。代码未 commit，fork 未建。

### 2026-09-18（第五次）
用户拍板参考 `experimental/starrocks` 接入 Doris（启动轨 1）。通读 SR 全部 `src/`（5.6k）+ 构建/CI + `rust/crates/sirius` API，复核 `origin/doris` 可搬件，
`gh` 逐个核实依赖 PR 现状，产出 `doris-pseudo-be-plan.md`：三问直答（宿主进程 + 协议壳 / Doris 零改动 + `experimental/doris/` / Mac + AWS g6e）、
SR 值得照抄的 7 项设计、与 SR 的 11 项差异表、模块清单与来源、引擎依赖分阶段表、P0→MVP-B 分步验收、AWS 规格与搭建步骤、
D-1～D-5 待拍板、SR 逐文件处置。发现 09-15 上游 20 个 draft 全关、换成 #1791/#1792/#1794；`local()` 需 `shared_storage`/`backend_id`。
同日用户拍板 D-1～D-5（fork `experimental/doris/`、4.1.x 同 tag、AWS 按方案且 P1 前不买、`local()`、暂不公开）→ ADR-011；
方案追加 §3.0「A0 与 A 的区别」。

### 2026-09-09（第四次）
伪 BE 路线（轨 1）可行性调研，产出 `pseudo-be-feasibility.md`。五路并行：上游 PR/分支盘点、aocsa 69 个 PR 专项、
引擎能力矩阵、Doris FE→BE 协议面（wt-gpu master）、`origin/doris` 深挖。结论：可行、Doris 协议面薄（gRPC、TVF 无 RF、BE↔BE 可私有）、
分布式进度上限在 aocsa 上游（T5b/T6/#1590）；MVP 三步 A0/A/B，到 MVP-A 约 3 个月。发现 #1724 已按提案实现 `push_arrow`（未回帖）；
#137 于 06-10 降优先级但欢迎 re-open。新增 OQ-006～OQ-010。

### 2026-09-01（第三次）
P0 可嵌入性调研完成（`embeddability-study.md`）。实测：真实 Sirius 产物预加载进真实 doris_be，
687 个符号绑到 BE（549 个 libstdc++），protobuf/abseil/arrow 零绑定；90 例合成矩阵证明
conda 口味产物进 `-rdynamic` 宿主必崩、全静态隐藏 + 静态 libstdc++ 免疫、异常跨界必崩。
三个缺口的估算：push_arrow ≈150 行、C ABI ≈800 行、libsirius target ≈200 行 CMake/YAML。
ADR-010：MVP 进程内，附 4 条 libsirius 链接约束。修正了 sirius-ffi.md 的三处判断。
晚间：核实 #1590 —— 无讨论，进展在 draft PR #1644（`push_packed`/`export_packed`/`StagingArena`，
`Context` 单线程契约）；发现 `origin/doris` 分支（mbrobbel 的 Rust 伪 BE 实验，TPC-H via `local()`），
其 FINDINGS 记入 G-25～G-29；study 补 §9。`push_arrow` 提案（只提方案一，点名 Doris）发到 #1590，
等回复。

### 2026-09-01（第二次）
核实 Sirius 嵌入能力，发现三个阻断性缺口（无 Arrow 输入口 / 无 C ABI / 无可分发产物）
+ 依赖闭包冲突风险。纠正 ADR-003 的错误论证（StarRocks BE 是 C++，Sirius 是新写了一个
Rust 协议外壳进程，不是继承了什么 Rust 基础）。ADR-006 转为重新评估，新增 ADR-008/009。
下一步交接为 P0 可嵌入性调研。

### 2026-09-01（第一次）
建立文档空间；完成两侧勘察与架构设计。代码零行，wt-gpu 未初始化。

</details>
