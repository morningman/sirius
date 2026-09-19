# 开发环境

> 最后核对：2026-09-19（GPU 机 Linux x86_64；Mac 部分 2026-09-18）

## 两个仓库

| 仓库 | 路径 | 分支 | 角色 |
|---|---|---|---|
| **Doris（开发主战场）** | `/Users/morningman/workspace/git/wt-gpu` | `wt-gpu`（worktree，追踪 `upstream-apache/master`） | 本项目**所有 Doris 侧改动都在这里**。它是 `/Users/morningman/workspace/git/doris` 的 git worktree |
| **Sirius（参考 + 轨 1 主战场）** | Mac `/Users/morningman/workspace/git/sirius`；**GPU 机 `/home/yy2/gpu/sirius`** | `dev`；轨 1 在 **`experimental-doris`** 分支（`experimental/doris/`），两台机器共用 fork `morningman/sirius` 同步 | 轨 2 在 MVP-0/1 阶段只读参考；轨 1 的全部代码在这里 |
| 文档空间 | `sirius/plan-doc/` | 随 sirius | 本目录 |

`wt-gpu` 是 worktree 不是独立 clone —— `git rev-parse --git-dir` 指向
`/Users/morningman/workspace/git/doris/.git/worktrees/wt-gpu`。改动主仓库的分支状态会互相影响，
提交前确认自己在 `wt-gpu` 分支上。

---

## ⚠️ 本机能做什么、不能做什么

**这台机器是 macOS arm64，没有 NVIDIA GPU。** 这不是小事，它决定了任务排布：

| 档位 | 能做的事 | 在哪 |
|---|---|---|
| ✅ **本机可做** | 翻译器（thrift → Substrait）的全部编码与单测<br>eligibility gate 的全部逻辑与单测<br>Block ↔ Arrow 桥接的编码与单测<br>Doris BE / FE 编译、BE 单测、regression test<br>起本地 Doris 集群、采集 fragment 语料 | `wt-gpu` |
| ⛔ **本机不可做** | 编译 Sirius（需要 Linux + CUDA 13 + RAPIDS）<br>运行任何 GPU 代码<br>端到端集成验证 | 需要 Linux + NVIDIA GPU 机器 |
| 📖 **本机只读** | 读 Sirius 源码 / 文档，作为翻译目标的依据 | `sirius/` |

**这个约束反过来验证了设计。** `design.md` §3.1 要求「契约可序列化，翻译器测试不需要 GPU」——
在这台机器上这不是好习惯，是**硬性前提**。所以：

> 任何一段代码，如果它的测试必须有 GPU 才能跑，就说明它放错了层。

**需要 GPU 机器的环节**（提前安排，不要卡在最后）：
- MVP-0 的最后一步 M0.8：拿翻译产物在 Sirius 上实跑并对结果
- MVP-1 起的全部差分测试
- 所有性能测量

---

## wt-gpu 首次初始化

**当前状态：未初始化。** `.worktree_initialized` 不存在，submodule 未拉，无 `output/`。
`thirdparty/installed` 已经软链到主仓库（`-> /Users/morningman/workspace/git/doris/thirdparty/installed/`），这一步不用重做。

按 `wt-gpu/AGENTS.md` 的 worktree 协议，第一件事：

```bash
cd /Users/morningman/workspace/git/wt-gpu
ROOT_WORKSPACE_PATH=/Users/morningman/workspace/git/doris hooks/setup_worktree.sh
# 完成后确认：
ls .worktree_initialized                 # 应存在
ls -l thirdparty/installed               # 应是有效软链
git submodule status | head              # 前缀不应是 '-'
```

submodule 若仍未初始化，手动补：
```bash
git submodule update --init --recursive --jobs 4
```

> 编译部署的完整流程（contrib 依赖、custom_env、增量编译组合、起停与健康检查、
> 以及固定会踩的坑）走 **`doris-dev-deploy` skill**，不要在这里重复一份会过期的步骤。

## 构建与测试（Doris 侧）

```bash
cd /Users/morningman/workspace/git/wt-gpu

./build.sh --be --fe          # 完整构建；产物在 ./output/
./build.sh --be               # 只编 BE（改翻译器时用这个）

./run-be-ut.sh --run <filter>            # BE 单测
./run-regression-test.sh -d <dir> -s <suite>   # 回归测试，-d 指父目录能快很多
```

- `BUILD_TYPE` 在 `custom_env.sh` 里设。**保持 `ASAN`**，只有明确要做性能测量时才改 `RELEASE`
  （AGENTS.md 的要求）。翻译器是纯逻辑代码，ASAN 下开发正合适。
- 起集群前检查 `conf/` 里的端口和 `priority_networks`，避免和主仓库的集群冲突。
- 集群启动慢，`--daemon` 起完至少等 30s。

## 轨 1 · 伪 BE 开发环（`sirius/experimental/doris/`，2026-09-18 起）

**在这台 Mac 上就能做 P0/P1 的全部工作**，不需要 wt-gpu，也不编 Doris：

| 组件 | 怎么来 | 命令（都在 `experimental/doris/` 下） |
|---|---|---|
| Doris FE 4.1.4 官方二进制 | `scripts/fetch-fe.sh` 流式下载 4.35 GB tarball，只留 `fe/`（1.1 GB）到 `.doris-fe/fe`（git-ignored） | `pixi run -e fe fe-fetch`；`fe-start` / `fe-stop` / `fe-clean`；`scripts/fe.sh status` |
| JDK 17 + mysql 客户端 | pixi `fe` 环境（conda-forge） | `pixi run -e fe mysql -h127.0.0.1 -P9030 -uroot` |
| thrift 0.22 / protoc / rust | pixi `be` 环境 | `pixi run -e be cargo test --workspace --no-default-features` |
| 伪 BE（无引擎） | `scripts/be.sh start`（翻译-only，落盘 `log/dump`） | `pixi run -e be bash scripts/be.sh start` / `stop` / `log` |
| TPC-H SF1 parquet | tpchgen-rs（`test_datasets/tpchgen-rs`，Mac 用 **rustup** 的 cargo 编，钉 1.89；没有 rustup 的机器直接用 pixi `be` 的 cargo）→ `test_datasets/tpch_parquet_sf1/`，软链 `/tmp/tpch-sf1` | `pixi run -e fe bash scripts/run-tpch.sh --data /tmp/tpch-sf1 --translate-only` |
| DuckDB + substrait 消费端（CPU 差分） | pixi `check` 环境（python-duckdb 1.5.5 + cmake/ninja/ccache）+ 系统 C++ 编译器 → `.duckdb-substrait/` | `pixi run -e check duckdb-substrait-build`；`pixi run -e check tpch-cpu-diff` |

端口：FE 8030/9020/9030/9010，BE 9050/9060/8040/8060（Doris 默认），与 `doris-dev-deploy` 的本地集群不冲突。
引擎路径（`sirius-engine` feature、`pixi run be-build`）只能在 Linux + NVIDIA 上跑（MVP-A0 起）。

## GPU 机（AWS `g4dn.2xlarge`，2026-09-19 起）

| 项 | 实测 |
|---|---|
| 实例 | `g4dn.2xlarge`，us-east-1；Tesla T4 16 GB（CC 7.5 = Sirius 下限）、8 vCPU Xeon 8259CL、30 GB 内存、无 swap |
| OS / 驱动 | Ubuntu 24.04.4 LTS x86_64，内核 6.17 aws；NVIDIA **580.178.04**，`nvidia-smi` 报 CUDA 13.0；`/proc/sys/kernel/io_uring_disabled = 0`；无系统 CUDA toolkit（全靠 pixi） |
| 盘 | 根卷 300 GB gp3（`/`，已用 ≈33 GB：根 pixi env 7.1 + doris default env 5.2 + build 树 2.2 + 其余）；实例盘 `nvme1n1` 209 GB **未分区未挂载**，`/mnt` 空（停机即清；要用需 sudo） |
| 账户 | `yy2`，**无 sudo**；系统只有 g++ 13.3 / make / git / python 3.12，**没有** cmake、ninja、unzip、java、gh、docker、rustup |
| pixi | 0.81.0，`~/.pixi/bin`（`~/.bashrc` 已加 PATH）；包缓存 `~/.cache/rattler` |
| 仓库 | `/home/yy2/gpu/sirius`，`origin` = fork `morningman/sirius`，分支 `experimental-doris`；submodule 已拉（都浅）：`experimental/doris/doris`（4.1.4）、`substrait`、`duckdb`、`cucascade`（`vcpkg` 不需要，没拉）；根 pixi 环境 `.pixi/envs/default` 已装（CUDA 13 + RAPIDS 26.08 + clang 21）；**引擎已编**：`build/release/extension/sirius/{sirius.duckdb_extension, libsirius.so.0.0.0}`（09-19，45 min；改引擎代码后 `pixi run make TEST_BUILD_TARGET=` 增量） |
| `experimental/doris/` | `.pixi/envs/{be,fe,check,default}` 已装（`default` 含 `engine` 特性，是引擎路径 BE 的编译/运行环境）；`.doris-fe/fe` = 官方 4.1.4；`.duckdb-substrait/`（DuckDB 1.5.5 + substrait 扩展，≈2 GB）已编；`target/debug`（无引擎）和 `target/release`（链 `libsirius.so.0`）都已编；`conf/sirius.yaml` 是本机的引擎配置 |
| 数据 | `test_datasets/tpch_parquet_sf1/`（tpchgen-rs，246 MB，`<table>/part.0.parquet`；本机 `.git/info/exclude`），软链 **`/tmp/tpch-sf1`**（开机清 `/tmp`，重建：`ln -sfn /home/yy2/gpu/sirius/test_datasets/tpch_parquet_sf1 /tmp/tpch-sf1`）；生成器 `test_datasets/tpchgen-rs/target/release/tpchgen-cli` |
| 进程 | FE：`pixi run -e fe fe-start|fe-stop`，`scripts/fe.sh status`；BE 引擎路径：**`pixi run bash scripts/be.sh start --engine`**（default 环境；缺省 `--sirius-config conf/sirius.yaml`）；BE 无引擎（translate-only）：`pixi run -e be bash scripts/be.sh start`；`be.sh stop|log`（`log/be.pid`）；客户端 `.pixi/envs/fe/bin/mysql -h127.0.0.1 -P9030 -uroot -E`（`\G` 在 9.7 客户端里不能用） |

**能做什么**：Mac 能做的全部 + 编 Sirius 引擎 + 引擎路径 BE + GPU 差分 + 性能测量（T4 数字不代表 L40S）。三层验证（A0.4-0）和引擎路径（A0.4）都已过，见 `handoff.md`。
**内存约束**：Sirius 默认 pin 90% 内存做 host tier，30 GB 机器上 BE 必须带 `--sirius-config` 把 `host.capacity_bytes` 限到 ≈12Gi（`doris-pseudo-be-plan.md` §4.2）——已固化在 `experimental/doris/conf/sirius.yaml`（GPU 90%、host 12Gi、spill `log/sirius-spill` 100Gi、Quent 遥测 `log/telemetry`），`be.sh start --engine` 缺省就用它。

## Sirius 侧（只读参考期）

MVP-0/1 不需要编译 Sirius。需要读源码时直接看文件即可，submodule 也不用初始化。

真要在 GPU 机器上编（M0.8 及之后）：
```bash
git submodule update --init --depth=1 --jobs 3 duckdb substrait cucascade
pixi run make
```
要求：Linux amd64/arm64、glibc ≥ 2.28、NVIDIA 计算能力 7.5+、CUDA 13.x（驱动 ≥ 580.65.06）
或 12.x、运行时开启 `io_uring`。详见 `sirius/docs/README.md`。

## 提交约定

- Doris 侧改动 → `wt-gpu` 分支。往 apache/doris 提 PR 前读 `wt-gpu/CONTRIBUTING.md`。
- Sirius 侧改动 → 默认分支是 `dev`，PR 规则见 `sirius/CONTRIBUTING.md` 的
  "PR branching strategy"（多数情况走个人 fork 的 Self-contained PR）。
- 文档空间（本目录）跟随 sirius 仓库。
