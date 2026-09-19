# Doris（CPU）vs Doris + Sirius 伪 BE（GPU）· TPC-H SF10 性能对比 · 测试方案

> 状态：**草案，待拍板**（2026-09-19，第十一次 session 末）。拍板后按 §8 执行，结果写 `results.md`。
> 依赖：MVP-A0 已跑通（SF1 22/22，`../../handoff.md`）。现有机器：AWS `g4dn.2xlarge`（§4）。

## 0. 目标与非目标

**目标**：同一个 Doris FE、同一份 SF10 parquet、同一批 22 条 TPC-H SQL 下，比较

- **A · Doris 原生**：官方 BE 4.1.4（pipeline 引擎，Doris 默认会话变量，用满机器的 CPU），和
- **B · Doris + Sirius**：我们的伪 BE 把 FE 派来的 fragment 拼成一棵 Substrait 树交给 Sirius 在 GPU 上跑，

给出每条查询的时间、加速比、以及"为什么"（哪部分是引擎、哪部分是 FE/协议开销、哪条查询为什么慢），并给出**同价格**口径的加速比（§1 的论文口径）。

**非目标**：

- 不比 Doris 的最佳状态（内表 + 统计 + colocate）——那是可选参照 C（§3），不进主表。
- 不做并发/吞吐（Sirius 引擎进程内串行，伪 BE 单 fragment）；只做单流 power run。
- 不在 T4 上下结论：T4 是 Sirius 支持的下限，§2 给出正式跑的机型。

## 1. 参考的现成测试方案

| 方案 | 硬件 | 方法要点 | 我们借鉴什么 |
|---|---|---|---|
| **Sirius 论文**《Rethinking Analytical Processing in the GPU Era》（CIDR 2026，[arXiv 2508.04701](https://arxiv.org/abs/2508.04701)） | 单机：**GH200**（92 GB HBM3，72 核 Grace，480 GB，Lambda $1.5/h）vs **c8i.8xlarge@AWS（同样 $1.5/h）**；分布式：4 节点 × 1 **A100 40 GB** + Doris，InfiniBand 400 Gbps | TPC-H **SF100**；**热跑**（数据已缓存：GPU 显存一半做数据缓存、一半算）；按 **每小时价格归一化**的成本效率（单机 DuckDB+Sirius 8.3×）；**Doris + Sirius 4 节点 vs CPU Doris：Q1/Q3/Q6 = 12.5× / 2.5× / 2.4×** | 成本对齐的 CPU 机型（§2 T1′）；热跑口径；GPU 缓存预算 50%；Doris 对照的 Q1/Q3/Q6 作 sanity（我们的单节点数字应与 4 节点趋势一致） |
| **Sirius 仓库 harness** `test/tpch_performance/`（`performance_test.py`、`run_tpch_parquet.sh`） | 上游 CI/开发机 | 每条查询 **cold + warm 两次迭代**（`--iterations`）；pinning `none / per-query / pinned-hot`（表常驻 GPU/host）；`--mode isolated` 每次 drop OS cache（需 sudo）；parquet 建议 **10M 行 row group**、大表切多文件；DuckDB CPU 与 Sirius 同进程对比 | R1/R2 直接复用它的口径；row group / 分文件建议（我们的 SF1 语料是 tpchgen 默认 row group，SF10 起按它重写一版做对照） |
| **Doris 官方 TPC-H**（[3.x 报告](https://doris.apache.org/docs/3.x/benchmark/tpch/)、[1.2 报告](https://doris.apache.org/blog/tpch/)） | 阿里云 4 台 **32C / 128G**（Ice Lake 8369B，企业级 SSD PL0），1 FE + 3 BE，SF1000；1.2 报告是"用户常见配置" **16C / 64G** 1 FE 3 BE，SF100 | 每条查询跑一次，报 Query Time(ms) 和 22 条总时间；内表 + 官方建表/导入脚本 | Doris 侧一台 BE 的规格参考（**16C64G 是 Doris 自己认的"用户常见"**，32C128G 是官方报告）；总时间指标；可选参照 C 照它的建表方式 |
| **ClickBench**（[方法说明](https://github.com/ClickHouse/ClickBench)） | c6a.4xlarge，500 GB gp2 | 每条 **3 次**：第 1 次冷（drop page cache + 重启 DB），后两次热；相对分数 =（10 ms + t）/（10 ms + 最快），**几何平均**；**默认配置、不调优**，调优要另列条目；缺失结果罚分 | 3 次冷/热口径；几何平均总评；"默认不调优、调优另列"规则 |

取舍：主口径 = ClickBench 式（1 冷 + N 热，中位数/几何平均，默认配置）+ Sirius 论文式的**成本归一化**；数据入口用 parquet 外表（两边同源），Doris 主场（内表）作参照。

## 2. 机型选择建议（AWS EC2，2026-09 查价，us-east-1 按需 Linux；以 [AWS 定价页](https://aws.amazon.com/ec2/pricing/on-demand/) 当天为准）

### 2.1 候选

| 实例 | GPU（显存 / 带宽 / 计算能力） | vCPU / 内存 | 本地 NVMe | $/h | 说明 |
|---|---|---|---|---|---|
| g4dn.2xlarge | T4 · 16 GB GDDR6 · 320 GB/s · CC 7.5 | 8 / 32 GB | 225 GB | 0.752 | **现用**；Sirius 支持下限；SF10 显存勉强、SF100 不行 |
| g6.2xlarge | L4 · 24 GB · 300 GB/s · CC 8.9 | 8 / 32 GB | 450 GB | 0.978 | 带宽不比 T4 强，**不推荐** |
| g5.2xlarge | A10G · 24 GB · 600 GB/s · CC 8.6 | 8 / 32 GB | 450 GB | 1.212 | 便宜档，显存仍小 |
| g6e.2xlarge | L40S · 48 GB GDDR6 · 864 GB/s · CC 8.9 | 8 / 64 GB | 450 GB | 2.242 | `doris-pseudo-be-plan.md` §4.2 的原推荐；CPU 侧只有 8 vCPU，Doris 吃亏 |
| **g6e.4xlarge** | L40S · 48 GB · 864 GB/s · CC 8.9 | **16 / 128 GB** | 600 GB | **3.004** | **推荐主机型**（§2.2） |
| g6e.8xlarge | L40S · 48 GB | 32 / 256 GB | 900 GB | ≈4.5（待核） | Doris 侧对齐官方报告的 32C 规格时用 |
| g7e.2xlarge | RTX PRO 6000 Blackwell SE · 96 GB GDDR7 · ≈1.6 TB/s · CC 12.0 | 8 / 64 GB | 有（待核） | 3.363 | 2026-01 GA，**仅 us-east-1 / us-east-2**；Sirius `CUDAARCHS` 含 `120a/120` 但我们没在 Blackwell 上验证过 |
| p5.4xlarge | H100 · 80 GB HBM3 · 3.35 TB/s · CC 9.0 | 16 / 256 GB | 有（待核） | 6.880 | 头条数字用；P 系列配额单独申请 |
| c7i.8xlarge（CPU 对照） | — | 32 / 64 GB | — | 1.428 | ≈ g6e.2xlarge 的 2/3 价 |
| c7i.12xlarge（CPU 对照） | — | 48 / 96 GB | — | ≈2.14 | ≈ g6e.2xlarge 同价（论文口径） |

多 GPU 实例（g6e.12xlarge 4×L40S、p4d 8×A100、p5.48xlarge 8×H100）**不需要**：伪 BE 单 GPU；MVP-B 多节点再说。

### 2.2 推荐分级

| 级 | 机型 | 用途 | 一天费用 |
|---|---|---|---|
| **T0（现在）** | g4dn.2xlarge | 把 SF10 全流程（原生 BE、跑批脚本、报告）跑通，出第一版数字，**标注 T4 下限** | $18 |
| **T1（主结论）** | **g6e.4xlarge**（1× L40S 48 GB，16 vCPU EPYC 7R13，128 GB，600 GB NVMe） | 同机 A vs B：SF10 全部在显存里（2.5 GB parquet → 解码后 ≈10 GB ≪ 43 GB）不降级；Doris 拿 16C/128G，≥ 它自己的"用户常见配置" 16C64G；SF100（≈25 GB parquet）靠 host tier（128 GB × 90%）也能试；数据放本地 NVMe | $72 |
| **T1′（成本对齐）** | 再加一台 **c7i.12xlarge**（48 vCPU / 96 GB，≈$2.1/h ≈ g6e.2xlarge）或 c7i.8xlarge | Doris 原生跑在同价 CPU 机上，得到 Sirius 论文口径的"同价格加速比"；FE 各自一套，数据各放一份 | +$51 |
| **T2（上限/头条，可选）** | p5.4xlarge（H100 80 GB）或 g7e.2xlarge（RTX PRO 6000 96 GB） | 同一套脚本只跑 B/R2，回答"换更强的卡加速比怎么变"；g7e 顺便验证 Blackwell 路径 | $165 / $81 |

**为什么主机型是 g6e.4xlarge 而不是 2xlarge**：同机对比里 Doris 只能用 GPU 实例自带的 vCPU，8 vCPU 会让 A 明显弱于任何真实 Doris 部署，读者会质疑；16 vCPU/128 GB 让 A 至少是 Doris 自己认的常见单 BE 规格，同时显存/主机内存对 SF10 都有 3～4 倍余量。多花的 $0.76/h 买的是结论的可信度。

### 2.3 规格规则（换 SF 时按这个算）

- **显存 ≥ 3 × parquet 大小**（解码列存 + join 中间态 + cudf 临时；Sirius 论文按显存一半做缓存）：SF10 ≈2.5 GB → ≥16 GB 勉强、≥24 GB 舒适；SF100 ≈25 GB → ≥80 GB，或接受 host 降级（L40S 48 GB + 128 GB host 可跑但慢）。
- **主机内存 ≥ FE 4 GB + Doris `mem_limit`（≥ 2 × parquet） + Sirius host pin（≥ 2 × parquet） + page cache（≈ parquet）**：SF10 → 32 GB 勉强（现状）、64 GB 舒适；SF100 → ≥ 256 GB。A 和 B 不同时起，所以取两者较大者而不是相加。
- **vCPU ≥ 16**（Doris 有代表性；`parallel_pipeline_task_num=0` 自动取核数一半）。
- **本地 NVMe 必须有**：Sirius 默认 `O_DIRECT` 直读；冷跑数字才是盘的数字而不是 EBS 的（gp3 基线 125 MB/s，提到 250 也远低于 NVMe）；EBS 只放系统、构建树、pixi 缓存（≥ 300 GB，我们现在用了 33 GB）。实例盘停机即清，数据用脚本重生成（SF10 3 min）。
- **驱动 ≥ 580.65（CUDA 13）**：我们的 `experimental/doris` 环境只有 cuda13 一档；Ubuntu 24.04 + NVIDIA apt 源装 `nvidia-driver-580-open`（T4/L40S/H100 都支持 open 内核模块）；别用自带旧驱动的 DLAMI。`io_uring` 默认开。
- **CPU 架构**：x86_64（Doris 官方 x64 二进制要 AVX2；EPYC 7R13 / Xeon 都有）。g6e 是 AMD EPYC Milan，Doris 官方报告是 Intel；同机对比不受影响，跨机对比（T1′）注明。

### 2.4 EC2 可购性与配额

- **配额**：G 系列走 Service Quotas 的 *Running On-Demand G and VT instances*（按 vCPU 计；新账户常为 0 或 8，**g6e.4xlarge 要 16、8xlarge 要 32，先申请到 ≥ 32**）；P 系列走 *Running On-Demand P instances*（p5.4xlarge 16 vCPU）；Spot 配额另算。申请通常 1～2 个工作日。
- **区域**：g4dn/g5/g6/g6e 在 us-east-1 等主要区域都有；**g7e 目前只有 us-east-1 / us-east-2**；p5.4xlarge 区域有限（us-east-1 有）。容量紧张时换 AZ 或用按需 Capacity Reservation；基准测试**用按需不用 Spot**（Spot 3～6 折但会被回收，跑到一半丢结果）。
- **价格**：表里是 2026-09 从 [Vantage](https://instances.vantage.sh/aws/ec2/g6e.4xlarge) / [Holori](https://calculator.holori.com/aws/ec2/g6e.2xlarge) / [DevZero](https://www.devzero.io/instances/aws/g7e.4xlarge) 抓的 us-east-1 按需 Linux 价，下单前看 AWS 定价页。
- **镜像与磁盘**：Ubuntu Server 24.04 LTS 官方 AMI；根卷 gp3 300 GB（吞吐 250 MB/s）；实例盘由脚本 `mkfs.ext4 + mount /mnt/nvme`（需要 sudo——**新机器把 `yy2` 加进 sudoers 或直接用 ubuntu 用户**，现在这台没 sudo 是本方案唯一被卡住的地方）。

## 3. 被测系统与参照

| 代号 | 系统 | 数据入口 | 执行硬件 | 作用 |
|---|---|---|---|---|
| **A** | Doris FE 4.1.4 + **官方 BE 4.1.4**（同机，`SKIP_CHECK_ULIMIT=true` 起） | `local()` TVF 读 parquet（`sql/tpch-views.sql`，与 B 完全相同的视图） | 全部 vCPU | **主对照** |
| **B** | Doris FE 4.1.4 + **Sirius 伪 BE**（`experimental/doris`，`be.sh start --engine`） | 同上 | GPU + 主机 pinned 内存 | **被测** |
| B′ | 同 B，Sirius 走 page cache（`scan_manager.local.use_odirect: false`） | 同上 | 同上 | 热跑对照（§6.5） |
| A′（T1′ 时） | Doris 原生跑在同价 CPU 机 c7i.12xlarge 上（自己的 FE + 数据副本） | 同上 | 48 vCPU | 成本对齐对照 |
| R1 | DuckDB 1.5.5（`check` 环境，全部线程）直接跑 SQL | `read_parquet` 视图 | 全部 vCPU | 单机 CPU 引擎参照：Doris 在外表上是不是"太慢了" |
| R2 | Sirius 透明路径（`build/release/duckdb` + 扩展，DuckDB 自己规划；可加 `pin_table` 常驻） | 同 R1 | GPU | 引擎上限参照：**B − R2 = FE 规划 + 伪 BE 协议 + 我们的 plan 形状**（FE 的 join 顺序 / 9～25 个恒等 Project）的代价 |
| C（可选） | Doris 原生 + **内表**（`INSERT INTO … SELECT FROM local()` 灌入，官方建表脚本的分桶/分区，`ANALYZE`） | OLAP 存储 | 全部 vCPU | Doris 最佳状态；说明"GPU vs Doris 本职工作"的差距；不进主表 |

主表 = **A vs B（热）**；辅表 = 冷跑、A′（成本对齐）、R1/R2、C。

## 4. 现有机器（g4dn.2xlarge）与它对 T0 的影响

| 项 | 实测 | 影响 |
|---|---|---|
| GPU | Tesla T4 16 GB（15,360 MiB 可用，CC 7.5） | `usage_limit_fraction 0.9` → 13.5 GB；SF10 解码后一张 lineitem 3～6 GB，Q9/Q21 的 join 中间态可能触发 **GPU→host 降级**（Sirius 正常路径，但慢），要记录 |
| CPU | 8 vCPU = 4 物理核 Xeon 8259CL（HT） | Doris `parallel_pipeline_task_num=0`（自动）；A 的成绩就是 4 核的成绩——T0 的 A 数字只能算"跑通" |
| 内存 | 30 GB，无 swap | FE 4 GB heap 常驻；A 阶段 BE `mem_limit=20G`；B 阶段 Sirius host pin **16Gi**（B 独占时比 A0 的 12Gi 高）；**A 和 B 不能同时起**（§6.2） |
| 盘 | 根卷 gp3 300 GB（≈250 MB/s）；实例盘 NVMe 209 GB **未挂载，需 sudo** | 冷跑两边都被 EBS 卡住：lineitem SF10 ≈2.4 GB 单文件 ≈10 s。**建议用户 sudo 挂上 NVMe**（`/mnt/nvme`：数据 + Sirius spill + Doris storage） |
| 账户 | 无 sudo；`vm.max_map_count=1,048,576`（<2M）、`ulimit -n 1,048,576`、swap 0 | Doris BE 启动脚本的检查用 `SKIP_CHECK_ULIMIT=true` 跳过（单 BE、SF10 够用）；**不能 drop page cache** → 冷跑用 `posix_fadvise(DONTNEED)` 逐文件驱逐（不需要 root，§6.4） |

## 5. 数据与基线

- **生成**：`tpchgen-cli -s 10 --format=parquet --parts=1`，布局与 SF1 一致（`<table>/part.0.parquet`，**一表一文件**——翻译器的多文件 scan range 尚未验证，先不引入变量）。≈2.5 GB，本机约 3 min。放 `test_datasets/tpch_parquet_sf10/`（`.git/info/exclude`），软链 **`/tmp/tpch-sf10`**（NVMe 挂上后改软链指向即可）。
- **row group**：tpchgen 默认 row group 与 Sirius harness 建议的 10M 行不同；先用默认（两边同一份），有余力用 `test/tpch_performance/rewrite_parquet.py` 重写一版做对照（对 Doris 的 split 并行也有影响，两边都要重跑）。
- **基线**：`validate_tpch_results.py expected --data /tmp/tpch-sf10 --out tests/expected/tpch-sf10`（DuckDB，估 2～5 min；Q11/Q16 大结果 gz）。A、B、R1、R2 的结果**全部**过校验（`--ulps 1`，G-19），校验不过的查询不进性能表。
- SF1 顺手跑一遍同样流程（已有基线）作为"随规模变化"的第二个点；SF100 只在 T1 机型上考虑（parquet ≈25 GB，生成 ≈30 min，L40S 要靠 host 降级）。

## 6. 公平性规则

1. **同一个 FE、同一份 SQL、同一批视图、同一份 parquet**。两阶段之间只换 BE，不动 FE（不重启，避免 JIT/元数据缓存差异）。
2. **一次只跑一个 BE**：两个 BE 各用自己的端口（原生 BE 改 `9150/9160/8140/8160`，伪 BE 默认 `9050/9060/8040/8060`），都 `ALTER SYSTEM ADD BACKEND` 注册；切阶段时停掉另一个并**等它 `Alive: false`**（心跳 5 s × 3）再跑——FE 只把 TVF scan 和 `glob` 派给 alive 的 BE。不用 DROP BACKEND。
3. **会话变量各用各的**：B 用 `sql/session.sql`（单实例、无 local shuffle、无 RF、结果单流、`file_split_size` 1 TB——这些是伪 BE 单 fragment 的**前提**，不是调优）；A 用 `sql/session-native.sql` 恢复 Doris 4.1.4 默认（`parallel_pipeline_task_num 0`、`enable_local_shuffle true`、`runtime_filter_mode GLOBAL`、`enable_parallel_result_sink true`、`enable_cte_materialize true`、`file_split_size 0`、`topn_lazy_materialization_threshold` 默认、`enable_fold_constant_by_be false`），只保留 `query_timeout 3600`、`enable_profile false`。**A 不做任何调优**（ClickBench 规则）；要调（如 `parallel_pipeline_task_num` = 核数）另列 A-tuned。
4. **冷/热定义**（ClickBench 口径的可行版）：冷 = BE 进程刚启动 + 所有 parquet `posix_fadvise(POSIX_FADV_DONTNEED)`（`scripts/evict-cache.py`，无需 root；对 O_DIRECT 路径无意义但无害）；每个配置只有第 1 轮是冷。热 = 紧接着的第 2～4 轮，取**中位数**为主指标，同时记最小值。
5. **IO 路径**（最容易被质疑的点）：Sirius 默认 `O_DIRECT` 读 parquet，**绕过 page cache，每条查询都从盘读**；Doris 走 page cache，热跑基本不碰盘。所以：**B（默认 O_DIRECT）**照跑并记录——这是 Sirius 上游的部署假设（NVMe 直读）；**B′（`use_odirect: false`）**作为**热跑主对照**——两边都从内存读，比的才是引擎；可选 B″：`enable_prefetch_cache: true`（Sirius 的 pinned-memory 预取缓存，跨查询保留）——若能把 SF10 全部缓存在 host pin 里，这是 Sirius 更"原生"的热态，只在 B′ 数字可疑时加。`pin_table`（表常驻 GPU，论文的口径）只在 R2 能用，作为引擎上限另列一行，不进 B。
6. **轮次**：每个配置 1 冷 + 3 热 × 22 条，顺序固定 Q1→Q22，单流。主配置（A、B、B′、R1、R2）≈ 5 × 4 × 22 = 440 次查询；按 SF1 经验每轮 1～3 min，全部约 1 h。
7. **结果校验**：每轮的 `result.tsv` 都过 `validate`（B 用 `--ulps 1`；A 的 `avg(DECIMAL)` 是 decimal 除法舍入，半 ulp 应该就过）。
8. **不动的东西**：FE `fe.conf`、伪 BE 代码（A0.6 的版本）、Sirius 引擎（A0.5 修过的两处）、DuckDB 版本。跑之前记下 commit / 驱动 / 配置文件哈希 / `SHOW VARIABLES` 进报告。

## 7. 指标

| 指标 | A 怎么取 | B 怎么取 | 说明 |
|---|---|---|---|
| **wall_ms**（主） | mysql 客户端往返（`run-tpch.sh` 的 `timings.csv`） | 同 | 用户看到的时间；含 FE 规划 + 派发 + 执行 + 取数 |
| engine_ms（次） | FE `fe.audit.log` 的 `Time(ms)` + 单独一轮 `enable_profile=true` 取 BE 执行时间（`SHOW QUERY PROFILE`，只做热跑一轮） | BE 日志 `query executed on the engine` 的 `engine_ms`（`SiriusContext::execute_substrait`，含 parquet 读） | 拆出 FE/协议开销：B 的 wall − engine 在 SF1 是 100～330 ms/条，SF10 下占比变小 |
| speedup | — | — | `A.wall / B.wall`（热中位数），每条一个；**几何平均**做总评；另给 power 总时间比；T1′ 再给 **每美元**口径（`A′.wall × $A′ / (B.wall × $B)`） |
| GPU 峰值显存 / 降级 | — | `nvidia-smi --query-gpu=memory.used -lms 200` 采样 + `log/telemetry/<query_id>/memory*.ndjson` | 判断是否触发 host/disk 降级 |
| CPU / RSS | `/proc/<pid>/status`、`/proc/<pid>/stat` 采样（BE 进程） | 同（伪 BE 进程） | Doris 是否吃满核；伪 BE 的 CPU 占用（解码在 GPU，CPU 应很低） |
| 读盘量 | `/proc/<pid>/io` `read_bytes` 前后差 | 同 | 证明冷/热定义成立（热跑 ≈ 0；B 默认 O_DIRECT 每轮 ≈ 数据集大小） |
| 正确性 | validate 结论 | 同 | 不过的不计入 |

## 8. 执行步骤（T0 一个 session 半天；T1 换机器后按 §9 的脚本重跑一遍，一小时）

| # | 步骤 | 产出 | 估时 |
|---|---|---|---|
| 0 | **用户侧**：拍板 §12；本机 sudo 挂 NVMe；push 本机 commit；申请 G 系列 vCPU 配额（为 T1） | — | — |
| 1 | 数据：SF10 生成 → 软链 `/tmp/tpch-sf10` → DuckDB 基线 `tests/expected/tpch-sf10`（进仓库，gz） | `test_datasets/tpch_parquet_sf10/`、`tests/expected/tpch-sf10/` | 10 min |
| 2 | 原生 BE 落地：`scripts/fetch-be.sh`（同 `fetch-fe.sh` 的流式解压，只留 `be/` 到 `.doris-be/be`，≈3 GB）、`conf/be.conf`（端口 91xx、`mem_limit`、`storage_root_path`、`JAVA_HOME` 用 pixi `fe` 的 JDK 17）、`scripts/be-native.sh start\|stop\|status`（`SKIP_CHECK_ULIMIT=true`，`ALTER SYSTEM ADD BACKEND` 一次）、`sql/session-native.sql` | 上述文件；`SHOW BACKENDS` 两个 BE | 40 min |
| 3 | 跑通验证：A 跑 SF1 22 条过校验（Doris 外表 TVF 路径本身是否 22/22 也是个结论） | `log/bench/sf1-native/` | 15 min |
| 4 | 跑批工具：`scripts/bench.sh --system {native\|sirius\|sirius-buffered\|duckdb\|duckdb-gpu} --data DIR --rounds 4 --out DIR`：切 BE + 等 Alive、套会话变量、第 1 轮前 `evict-cache.py`、每轮调 `run-tpch.sh`（已有 `timings.csv`/validate）、采样 GPU/RSS/read_bytes、汇总 `rounds.csv`；环境快照 | `scripts/bench.sh`、`scripts/evict-cache.py` | 1 h |
| 5 | **A**：4 轮 × 22 | `log/bench/sf10-native/` | 15 min |
| 6 | **B**（`conf/sirius-bench.yaml`：GPU 0.9、host 16Gi、spill 到 NVMe）和 **B′**（`use_odirect: false`）各 4 轮 | `log/bench/sf10-sirius{,-buffered}/` | 20 min |
| 7 | **R1 / R2**：`build/release/duckdb`（`SIRIUS_DISABLE=1` = R1，默认 = R2，R2 再加一轮 `pin_table`）各 4 轮，同一批视图 SQL | `log/bench/sf10-duckdb{,-gpu}/` | 15 min |
| 8 | （可选）**C**：内表灌数（`INSERT INTO SELECT`，SF10 估 10 min）+ `ANALYZE` + 4 轮 | `log/bench/sf10-native-olap/` | 40 min |
| 9 | 汇总：`scripts/bench-report.py` 从各 `rounds.csv` 出 §11 的表 → `results.md`；同一批脚本再跑一遍 SF1 | `results.md` | 30 min |
| 10 | **T1**：新机器（g6e.4xlarge）按 `environment.md` 搭环境（pixi 装 + 编引擎 45 min + 原生 BE） → 步骤 1、5～9 重跑；T1′ 的 CPU 机只跑 A | `results.md` 主表 | 半天 |

## 9. 要新写 / 改的东西（全部在 `experimental/doris/`）

- `scripts/fetch-be.sh`、`scripts/be-native.sh`、`conf/be.conf`（模板：端口 91xx、`mem_limit`、`storage_root_path=${DORIS_HOME}/../storage`）、`sql/session-native.sql`
- `conf/sirius-bench.yaml`（+ `-buffered` 变体）：`host.capacity_bytes` 按机器、`disk.downgrade_root_dirs` 指向 NVMe、`telemetry` 开
- `scripts/evict-cache.py`（`os.posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED)` 遍历数据目录）
- `scripts/bench.sh`、`scripts/bench-report.py`（读 `timings.csv` + `summary.csv` + 采样，出中位数/最小值/加速比/几何平均/每美元）
- `run-tpch.sh`：加 `--session-sql FILE`（默认 `sql/session.sql`）、`--label`；原生 BE 没有 engine_ms（留 `-`）

不改：翻译器、伪 BE 执行路径、引擎。

## 10. 已知风险与解释口径

1. **T4 ≠ L40S ≠ H100**：T4 显存带宽 320 GB/s，是 L40S 的 1/2.7、H100 的 1/10；CC 7.5 也是 Sirius 支持的最低架构。T0 的加速比只对这台机器有效，报告首页写死。
2. **SF10 在 16 GB 显存上会降级**：Q9/Q21（lineitem ⋈ orders ⋈ partsupp）中间态可能超出 13.5 GB → host pinned → 再不够 → 磁盘 spill（gp3 会非常慢）。某条查询突然慢 10× 先看 telemetry 的 memory tier，报告里单列。T1 机型上不应出现。
3. **冷跑是盘的成绩**：不挂 NVMe 时两边冷跑都是 EBS ≈250 MB/s；B 默认 O_DIRECT **每轮都是冷跑**。热跑主对照用 B′。
4. **Doris 外表路径不是 Doris 的主场**：`local()` TVF 没有统计、没有索引、没有 colocate；但 **FE 给 A 和 B 的 plan 形状相同**（同 FE、同 SQL；join 顺序一样，A 多了 RF/local shuffle/并行实例），所以 A vs B 比的是执行引擎。要看 Doris 主场跑 C。
5. **FE 开销在 wall 里**：SF1 下 FE 规划 100～330 ms/条 ≈ 引擎时间的 1～3×，SF10 下引擎时间涨 10× 而 FE 不变，占比下降；报告同时给 wall 和 engine 两栏。
6. **单 fragment vs 并行**：B 的伪 BE 是"一棵树、一个 GPU、串行"；A 是 pipeline 并行。两边都用满了各自的硬件，这就是 MVP-A0 的形态；MVP-A 之后再比。
7. **结果末位**：Sirius 的 DOUBLE→DECIMAL 截断（G-19）用 `--ulps 1` 兜住；Doris 的 `avg(DECIMAL)` 本身是舍入。两边都要过校验，不过的查询从性能表里剔除并注明。
8. **Q11/Q16 大结果集**：SF10 下 Q11/Q16 各几十万行（待实测），mysql 取数会占 wall 的大头，两边一样，但报告里标出。
9. **同机 FE 与 BE 抢 CPU**：A 阶段 FE 规划和 BE 执行共用 CPU；B 阶段 FE 只和伪 BE 的少量 CPU 工作竞争。这对 A 略不利，属于"同机部署"的真实情况，注明；T1′ 的跨机对照没有这个问题。
10. **与论文数字对不上是正常的**：论文是 4 节点 A100 + Doris 分布式 SF100（Q1/Q3/Q6 = 12.5×/2.5×/2.4×），我们是单节点、单 fragment、T4/L40S、SF10；趋势（Q1 类扫描聚合加速最大，Q3/Q6 小）应一致，量级不必一致。

## 11. 报告模板（`results.md`）

主表（SF10，热跑中位数，ms）：

| q | A Doris wall | B′ Sirius wall | **speedup** | B′ engine | R1 DuckDB | R2 Sirius 透明 | 备注（降级 / 校验 / 结果行数） |

辅表：冷跑（A / B / B′ 第 1 轮）、power 总时间、几何平均加速比、每美元加速比（T1′）、SF1 同表；资源表（GPU 峰值、RSS、read_bytes）；环境快照（机型、commit、驱动、配置哈希、`SHOW VARIABLES` 两套、价格）。

## 12. 待用户拍板

| # | 问题 | 建议 |
|---|---|---|
| Q1 | 现在这台是否 sudo 挂载实例盘 NVMe（`sudo mkfs.ext4 /dev/nvme1n1 && sudo mkdir -p /mnt/nvme && sudo mount /dev/nvme1n1 /mnt/nvme && sudo chown yy2 /mnt/nvme`；停机即清，数据 3 min 可重生成） | **挂**——否则冷跑和 Sirius 默认 O_DIRECT 路径都只反映 EBS |
| Q2 | 正式数字用哪台：g6e.4xlarge（推荐，$3/h）还是 g6e.2xlarge（$2.24/h，Doris 只有 8 vCPU） | **g6e.4xlarge**；先申请 G 系列 vCPU 配额 ≥ 32 |
| Q3 | 要不要 T1′ 成本对齐的 CPU 机（c7i.12xlarge ≈$2.1/h） | 要——这是论文口径，也是最难被反驳的口径 |
| Q4 | 要不要 T2 头条机（p5.4xlarge H100 $6.88/h 或 g7e.2xlarge $3.36/h） | 主结论出来后再定；g7e 有验证 Blackwell 的附带价值 |
| Q5 | 是否做可选参照 C（Doris 内表） | 做，但放在最后、不进主表；读者一定会问"Doris 主场差多少" |
| Q6 | 轮次 1 冷 + 3 热够不够；规模 SF10 为主、SF1 顺带、SF100 只在 T1 试 | 够；SF100 看 T1 上 SF10 的降级情况再定 |
