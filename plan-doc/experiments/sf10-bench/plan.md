# Doris（CPU）vs Doris + Sirius 伪 BE（GPU）· TPC-H 性能对比（SF10 跑通，SF100 出主表）· 测试方案

> 状态：**已拍板并在 T0 跑通**（2026-09-19，第十二次 session）：§12 Q1/Q2/Q3/Q5 按建议（NVMe 已挂、正式机 g6e.4xlarge + c7i.12xlarge、做参照 C），Q4 待主结论，Q6 按 §5.0。§9 的脚本全部写好并在 SF1/SF10 上跑通，T0 结果在 `results.md`。**执行时发现两条改动方案的事**：§6.2 改成"跑原生系统时把伪 BE 从 FE 上 DROPP 掉"，§3 多了一个 `native-split`（原因见 §6.3 与 §10.11/§10.12）。
> 依赖：MVP-A0 已跑通（SF1 22/22，`../../handoff.md`）。现有机器：AWS `g4dn.2xlarge`（§4）。

## 0. 目标与非目标

**目标**：同一个 Doris FE、同一份 TPC-H parquet（**主表用 SF100，SF10 作跑通与规模点**，§5.0）、同一批 22 条 SQL 下，比较

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
| p5.4xlarge | H100 · 80 GB HBM3 · 3.35 TB/s · CC 9.0 | 16 / 256 GB | 有（待核） | 6.880 | T2 加测（只跑 Sirius 侧）；P 系列配额单独申请 |
| c7i.8xlarge（CPU 对照） | — | 32 / 64 GB | — | 1.428 | ≈ g6e.2xlarge 的 2/3 价 |
| c7i.12xlarge（CPU 对照） | — | 48 / 96 GB | — | ≈2.14 | ≈ g6e.2xlarge 同价（论文口径） |

多 GPU 实例（g6e.12xlarge 4×L40S、p4d 8×A100、p5.48xlarge 8×H100）**不需要**：伪 BE 单 GPU；MVP-B 多节点再说。

### 2.2 推荐分级

| 级 | 机型 | 用途 | 一天费用 |
|---|---|---|---|
| **T0（现在）** | g4dn.2xlarge | 把 SF10 全流程（原生 BE、跑批脚本、报告）跑通，出第一版数字，**标注 T4 下限** | $18 |
| **T1（主结论）** | **g6e.4xlarge**（1× L40S 48 GB，16 vCPU EPYC 7R13，128 GB，600 GB NVMe） | 同机 A vs B，**主表 SF100**（parquet ≈25 GB，解码超过显存 → 走 host tier 128 GB × 90%，正是要看的场景），SF10 作"全在显存"的规模点（解码 ≈10 GB ≪ 43 GB）；Doris 拿 16C/128G，≥ 它自己的"用户常见配置" 16C64G，官方 1.2 报告就是这个规格跑 SF100；数据放本地 NVMe | $72 |
| **T1′（成本对齐）** | 再加一台 **c7i.12xlarge**（48 vCPU / 96 GB，≈$2.1/h ≈ g6e.2xlarge）或 c7i.8xlarge | Doris 原生跑在同价 CPU 机上，得到 Sirius 论文口径的"同价格加速比"；FE 各自一套，数据各放一份 | +$51 |
| **T2（可选加测：更强 GPU 的可扩展性）** | p5.4xlarge（H100 80 GB）或 g7e.2xlarge（RTX PRO 6000 96 GB） | 同一套脚本**只跑 Sirius 侧（B/R2）**，不重跑 Doris，回答"换更强的卡加速比还能涨多少"——加速比要拿 T1 的 Doris 数字来除，属于跨机估算，报告里注明；g7e 顺便验证 Blackwell（CC 12.0）路径。等 T1 主结论出来再决定花不花这个钱 | $165 / $81 |

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

### 2.5 SF100 采购清单（2026-09-19 晚，按 T0 实测补的账）

- **T1 主机：g6e.4xlarge**（L40S 48 GB / 16 vCPU / 128 GB / 1×600 GB NVMe，$3.00/h）；预算允许就 **g6e.8xlarge**（32 vCPU / 256 GB / 1×900 GB，≈$4.5/h）——多花 $1.5/h 买 Doris 对齐官方报告的 32C、内存不用抠、更大更快的实例盘。**T1′ CPU 机：c7i.12xlarge**（$2.14/h，配 4xlarge）或 c7i.24xlarge（$4.28/h，配 8xlarge），只装 FE + 原生 BE。不买 g6e.2xlarge（8 vCPU）、g6（L4）、多卡。
- **盘**：根卷 gp3 300 GB（默认吞吐即可；本机用了 40 GB）；**数据全放实例盘**：SF100 parquet **≈36 GB**（按 SF10 实测 3.6 GB 推算，不是 §5.0 估的 25 GB）+ 内表 ≈40 GB + spill 100 GB + SF10/基线 → ≈200 GB，600 GB 够。停机即清，SF100 重生成只要几分钟。
- **到手先量盘速**（`dd iflag=direct` 单流 + 4～8 路并发）：G 系列实例盘是共享盘切片、吞吐大致随容量走，本机 225 GB 只有 0.4 GB/s，600 GB 估 1 GB/s 上下。它决定 B（O_DIRECT）有多少是盘的数字；B′ 不受影响。EBS 替代不了（gp3 单卷 1 GB/s 上限，io2 受实例 EBS 带宽限制）。
- **SF100 内存账**：GPU 池高水位 SF10 11.2 GB → SF100 ≈110 GB，L40S 43 GB 装不下 → 大 join 走 host tier（正是要看的）。128 GB 机器：host tier 默认 114 GiB（pinned）+ 36 GB page cache 超了 → B′ 用 `bench.sh --host-capacity 64Gi`，B 用默认；Doris `mem_limit` 70 % = 89 GB + page cache 36 GB 刚好。256 GB 机器什么都不用调。
- 配额：*Running On-Demand G and VT instances* ≥ 16（4xlarge）/ ≥ 32（8xlarge）；镜像 Ubuntu 24.04 + `nvidia-driver-580-open`；给用户 passwordless sudo；原生 BE 的 `storage_root_path` 从第一次启动起就定在 NVMe。按需不用 Spot。费用：一天 $72 / $108 + CPU 机半天 $26 / $51。

## 3. 被测系统与参照

| 代号 | 系统 | 数据入口 | 执行硬件 | 作用 |
|---|---|---|---|---|
| **A** | Doris FE 4.1.4 + **官方 BE 4.1.4**（同机，`SKIP_CHECK_ULIMIT=true` 起），会话变量 = 4.1.4 默认（`sql/session-native.sql`） | `local()` TVF 读 parquet（`sql/tpch-views.sql`，与 B 完全相同的视图） | 全部 vCPU | 主对照（**stock 默认**：单文件表只有 1 个 scanner 干活，§10.12） |
| **A-split**（`native-split`） | 同 A，只多 `SET GLOBAL file_split_size_on_be = 0`（FE 侧切分，4.1 之前的默认行为；`sql/session-native-split.sql`） | 同上 | 全部 vCPU | **主表的 Doris 基线**（16 个 scanner 并行；不是引擎调优，是绕开 §10.12） |
| **B** | Doris FE 4.1.4 + **Sirius 伪 BE**（`experimental/doris`，`be.sh start --engine`） | 同上 | GPU + 主机 pinned 内存 | **被测** |
| B′ | 同 B，Sirius 走 page cache（`scan_manager.local.use_odirect: false`） | 同上 | 同上 | 热跑对照（§6.5） |
| A′（T1′ 时） | Doris 原生跑在同价 CPU 机 c7i.12xlarge 上（自己的 FE + 数据副本） | 同上 | 48 vCPU | 成本对齐对照 |
| R1（`duckdb`） | DuckDB 1.5.5 = 引擎构建树里的 `build/release/duckdb` shell，`SIRIUS_DISABLE=1`，全部线程，单进程跑同一批 `sql/tpch/*.sql` | `read_parquet` 视图 | 全部 vCPU | 单机 CPU 引擎参照：Doris 在外表上是不是"太慢了" |
| R2（`duckdb-gpu`，`duckdb-gpu-pinned`） | Sirius 透明路径（同一个 shell，DuckDB 自己规划；`-pinned` 先 `pin_table` 把全部列常驻 GPU） | 同 R1 | GPU | 引擎上限参照：**B − R2 = FE 规划 + 伪 BE 协议 + 我们的 plan 形状**（FE 的 join 顺序 / 9～25 个恒等 Project）的代价 |
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

### 5.0 规模：SF10 只够跑通，主表要 SF100

| | SF10 | SF100 |
|---|---|---|
| 原始 / parquet / lineitem 行数 | 10 GB / ≈2.5 GB / 6000 万 | 100 GB / ≈25 GB / 6 亿 |
| 别人怎么用 | 开发/回归规模；Doris 1.2 报告用 SF100、3.x 用 SF1000；Sirius 论文单机和 Doris 分布式都用 **SF100**；ClickBench ≈1 亿行 | 单机对比的"公认"规模 |
| 在 T0（T4 16 GB / 30 GB）上 | 能跑：全部在 page cache；GPU 侧部分查询会 host 降级 | **跑不了**：parquet 25 GB > host pin 16Gi，Doris `mem_limit` 20 GB 也要 spill——数字没有意义 |
| 在 T1（L40S 48 GB / 128 GB）上 | 全部在显存里（解码 ≈10 GB ≪ 43 GB），引擎时间 ≈100～500 ms/条，**FE 固定开销（100～300 ms）与引擎同量级，加速比被稀释** | lineitem 一张表解码 ≈30 GB，join 中间态超过 43 GB → **走 host tier（128 GB × 90%）**，这正是读者最想看的"数据装不下显存时 GPU 还剩多少优势"；Doris 16C/128G 跑 SF100 很正常（官方 1.2 报告就是 3×16C64G 跑 SF100） |
| 结论 | **T0 只跑 SF10**（把流程、脚本、报告跑通，出第一版数字，标注 T4）；T1 上 SF10 作为"全在显存"的规模点 | **T1 的主表用 SF100**；SF1000 不做（parquet 250 GB，单节点/单 GPU 没意义，等 MVP-B 多节点） |

SF100 的额外成本：生成 ≈5～10 min（tpchgen-rs，8～16 核）、DuckDB 基线 ≈3～5 min（16 线程 / 128 GB）、Doris 一轮 22 条估 3～10 min、Sirius 一轮 1～3 min，全部配置 4 轮 ≈1.5 h；NVMe 600 GB 放得下。lineitem 单文件 ≈15 GB：Sirius 读单文件没问题，Doris 靠 split 并行也没问题；**若想切多文件（`--parts`），先在 SF1 上验一遍翻译器的多文件 scan range**（`scan_ranges.rs` 未验），再用于 SF100。

- **生成**：`tpchgen-cli -s 10 --format=parquet --parts=1`，布局与 SF1 一致（`<table>/part.0.parquet`，**一表一文件**——翻译器的多文件 scan range 尚未验证，先不引入变量）。≈2.5 GB，本机约 3 min。放 `test_datasets/tpch_parquet_sf10/`（`.git/info/exclude`），软链 **`/tmp/tpch-sf10`**（NVMe 挂上后改软链指向即可）。
- **row group**：tpchgen 默认 row group 与 Sirius harness 建议的 10M 行不同；先用默认（两边同一份），有余力用 `test/tpch_performance/rewrite_parquet.py` 重写一版做对照（对 Doris 的 split 并行也有影响，两边都要重跑）。
- **基线**：`validate_tpch_results.py expected --data /tmp/tpch-sf10 --out tests/expected/tpch-sf10`（DuckDB，估 2～5 min；Q11/Q16 大结果 gz）。A、B、R1、R2 的结果**全部**过校验（`--ulps 1`，G-19），校验不过的查询不进性能表。
- SF100 只在 T1 机型上做（§5.0）：`tpchgen-cli -s 100 …` 到 NVMe，基线 `tests/expected/tpch-sf100`（Q11/Q16 结果几百万行，gz 后仍大——基线目录改放 NVMe、不进仓库，只进 `INDEX.md` 的行数与哈希）。SF1 顺手跑一遍（已有基线）作为最小规模点。

## 6. 公平性规则

1. **同一个 FE、同一份 SQL、同一批视图、同一份 parquet**。两阶段之间只换 BE，不动 FE（不重启，避免 JIT/元数据缓存差异）。
2. **一次只跑一个 BE**：两个 BE 各用自己的端口（原生 BE 改 `9150/9160/8140/8160`，伪 BE 默认 `9050/9060/8040/8060`）。**跑原生系统前把伪 BE `ALTER SYSTEM DROPP BACKEND` 掉**（`bench.sh drop_sirius_be`）：伪 BE 从不向 FE 上报 CPU 数（FE 里 `pipelineExecutorSize` 默认 1），而 `parallel_pipeline_task_num = 0` 的自动并行度 = **所有已注册 BE**（含不 alive 的）的最小值 → 伪 BE 只要注册着，原生 BE 每个 fragment 就只有 1 个实例（profile `Parallel Fragment Exec Instance Num: 1`，DROPP 后 4）。伪 BE 没有 tablet，摘掉无损，`be.sh start` 时 `register_node` 自动重新注册。原生 BE 永远不摘（C 的内表在它上面），跑 B 时只停进程等 `Alive: false`（B 的 `parallel_pipeline_task_num = 1` 是钉死的，不受影响）。
3. **会话变量各用各的**：B 用 `sql/session.sql`（单实例、无 local shuffle、无 RF、结果单流、`file_split_size` 1 TB + **`file_split_size_on_be = 0` + `file_split_size_on_fe` 1 TB**——这些是伪 BE 单 fragment、整文件 scan range 的**前提**，不是调优；后两个是 SF10 才暴露的：4.1.4 默认的 BE 侧切分让 FE 无视 `file_split_size`、按 `file_split_size_on_fe` = 512 MB 切字节范围，2.4 GB 的 lineitem 来 5 段，翻译器拒绝——SF1 的文件都不到 512 MB 所以 A0.5 没碰到）；A 用 `sql/session-native.sql` 恢复 Doris 4.1.4 默认（按源码核对：`parallel_pipeline_task_num 0`、`enable_local_shuffle true`、`runtime_filter_mode GLOBAL`、`enable_parallel_result_sink true`、`enable_cte_materialize true`、`file_split_size 0`、`topn_lazy_materialization_threshold 1024`、`enable_fold_constant_by_be false`、`file_split_size_on_be 64MB`），只保留 `query_timeout 3600`、`enable_profile false`。**A 不做任何调优**（ClickBench 规则）；A-split 只改 `file_split_size_on_be = 0`（§10.12），其它要调的另列 A-tuned。两个文件互为逆操作（GLOBAL 变量存在 FE 元数据里，`run-tpch.sh --session-sql` 每轮前套一遍）。
4. **冷/热定义**（ClickBench 口径）：冷 = BE 进程刚启动 + 所有 parquet `posix_fadvise(POSIX_FADV_DONTNEED)` + `echo 3 > drop_caches`（`scripts/evict-cache.py --drop-caches`，有 sudo 时全清，没有时只 fadvise；对 O_DIRECT 路径无意义但无害）；每个配置只有第 1 轮是冷。热 = 紧接着的第 2～4 轮，取**中位数**为主指标，同时记最小值。
5. **IO 路径**（最容易被质疑的点）：Sirius 默认 `O_DIRECT` 读 parquet，**绕过 page cache，每条查询都从盘读**；Doris 走 page cache，热跑基本不碰盘。所以：**B（默认 O_DIRECT）**照跑并记录——这是 Sirius 上游的部署假设（NVMe 直读）；**B′（`use_odirect: false`）**作为**热跑主对照**——两边都从内存读，比的才是引擎；可选 B″：`enable_prefetch_cache: true`（Sirius 的 pinned-memory 预取缓存，跨查询保留）——若能把 SF10 全部缓存在 host pin 里，这是 Sirius 更"原生"的热态，只在 B′ 数字可疑时加。`pin_table`（表常驻 GPU，论文的口径）只在 R2 能用，作为引擎上限另列一行，不进 B。
6. **轮次**：每个配置 1 冷 + 3 热 × 22 条，顺序固定 Q1→Q22，单流。主配置（A、B、B′、R1、R2）≈ 5 × 4 × 22 = 440 次查询；按 SF1 经验每轮 1～3 min，全部约 1 h。
7. **结果校验**：每轮的 `result.tsv` 都过 `validate`（B 用 `--ulps 1`；A 的 `avg(DECIMAL)` 是 decimal 除法舍入，半 ulp 应该就过）。
8. **不动的东西**：伪 BE 代码（A0.6 的版本）、Sirius 引擎（A0.5 修过的两处）、DuckDB 版本。FE `fe.conf` 只改了一处 `remote_fragment_exec_timeout_ms = 600000`（伪 BE 在 `exec_plan_fragment_prepare` RPC 里同步执行整条查询，30 s 的默认 RPC 超时会咬 SF10 的慢查询；运行中用 `ADMIN SET FRONTEND CONFIG` 生效，不重启 FE）。`bench.sh` 每次跑都把 commit / 机型 / 驱动 / 配置文件哈希 / `SHOW BACKENDS` 写进 `env.txt`，第 1 轮后把 GLOBAL 变量写进 `variables.txt`，两者都进报告。

## 7. 指标

| 指标 | A 怎么取 | B 怎么取 | 说明 |
|---|---|---|---|
| **wall_ms**（主） | mysql 客户端往返（`run-tpch.sh` 的 `timings.csv`） | 同 | 用户看到的时间；含 FE 规划 + 派发 + 执行 + 取数 |
| engine_ms（次） | 没有（A 的引擎时间用 FE 审计日志的 `fragment_rpc_phase_1 + …` 近似，或单独一轮 `enable_profile=true` 看 profile，本次没做） | BE 日志 `query executed on the engine` 的 `engine_ms`（`SiriusContext::execute_substrait`，含 parquet 读） | 拆出 FE/协议开销：B 的 wall − engine 在 SF1 是 100～330 ms/条，SF10 下占比变小 |
| FE 审计（`fe-audit.py`） | `fe.audit.log` 每条查询的 `Time(ms)`（FE 端到端）、`PlanTimesMs.plan`、`ScheduleTimesMs.schedule_time_ms / fragment_rpc_phase_1_time_ms`、`CpuTimeMS`、`PeakMemoryBytes`、`ScanBytes/ScanRows`（BE 上报；伪 BE 全 0） | 同 | 按客户端窗口 `[start_ms, end_ms]` 与 `QueryId` 对上；审计日志有几秒的异步落盘延迟，轮次结束后再 join |
| speedup | — | — | `A.wall / B.wall`（热中位数），每条一个；**几何平均**做总评；另给 power 总时间比；T1′ 再给 **每美元**口径（`A′.wall × $A′ / (B.wall × $B)`） |
| GPU 利用率 / 显存 / 降级 | — | `bench.sh` 采样器每 0.5 s 记 `nvidia-smi` 的 `utilization.gpu`（有 kernel 在跑的时间占比）、`utilization.memory`（显存控制器忙的占比）、`memory.used`（= RMM 预留的池子，不是峰值），按查询窗口取均值；降级看 telemetry `batch_placement` 的 tier | 回答"GPU 被吃到几成"；判断是否触发 host/disk 降级 |
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
| 10 | **T1**：新机器（g6e.4xlarge）按 `environment.md` 搭环境（pixi 装 + 编引擎 45 min + 原生 BE） → 步骤 1、5～9 先用 SF10 重跑（验证环境），再 **SF100 跑一遍出主表**（生成 + 基线 ≈15 min，A/B/B′/R1/R2 各 4 轮 ≈1.5 h）；T1′ 的 CPU 机只跑 A | `results.md` 主表（SF100）+ 规模表（SF1/SF10/SF100） | 一天 |

## 9. 要新写 / 改的东西（全部在 `experimental/doris/`）← **已全部写好并跑通（2026-09-19）**，用法见 `experimental/doris/README.md`「Benchmark」一节

- ✅ `scripts/fetch-be.sh`（同 `fetch-fe.sh` 的流式解压，只留 `be/` → `.doris-be/be`，4.6 GB）、`scripts/be-native.sh start|stop|status`（`SKIP_CHECK_ULIMIT=true`，幂等 `ADD BACKEND`，等 `Alive: true`；BE 自己几秒后才写 `bin/be.pid`，用 `pgrep` 兜底）、`conf/be.conf`（模板：端口 91xx、`priority_networks 127.0.0.0/8`、`mem_limit` = 70 % RAM、`storage_root_path` → `/mnt/nvme/doris-storage`、**`user_files_secure_path = /`**——`local()` 的 glob 会拼上这个前缀，默认 `${DORIS_HOME}` 读不到数据集）、`sql/session-native.sql` + `sql/session-native-split.sql`
- ✅ `conf/sirius-bench.yaml` 模板（`@@HOST_CAPACITY@@` = min(90 % RAM, RAM − 14 GiB)、`@@SPILL_DIR@@`、`@@USE_ODIRECT@@`、`@@TELEMETRY_DIR@@`，`bench.sh` 填好后写到运行目录）
- ✅ `scripts/evict-cache.py`（fadvise + 可选 `--drop-caches`）
- ✅ `scripts/bench.sh`（一个系统 N 轮：切 BE、DROPP 伪 BE、套会话变量、驱逐缓存、每轮 `run-tpch.sh`/`run-tpch-duckdb.sh` + 校验 + `fe-audit.py`、0.5 s 采样 RSS/read_bytes/CPU/GPU、`env.txt`/`variables.txt`）、`scripts/bench-all.sh`（按顺序跑一串系统 + 出报告，一条命令）、`scripts/bench-report.py rounds|report`（`rounds.csv` + §11 的 Markdown 表：热中位数/最小值、加速比、几何平均、power 总时间、每美元、冷跑、FE 审计拆分、资源、环境）
- ✅ `scripts/run-tpch-duckdb.sh`（R1/R2：`build/release/duckdb` 单进程跑同一批 `sql/tpch/*.sql`，`.timer` 计时，`--pin gpu|host` 用上游 `tpch_pin_columns.py pin-all`）、`scripts/fe-audit.py`（FE 审计日志按时间窗 + QueryId join 进 `timings.csv`）、`scripts/olap-load.sh`（参照 C：官方 DDL + `INSERT INTO SELECT` + `ANALYZE … WITH SYNC`，库 `tpch_olap`）
- ✅ `run-tpch.sh`：加 `--session-sql FILE`、`--db NAME`，`timings.csv` 多 `start_ms,end_ms`；原生 BE 没有 engine_ms（留 `-`）。`sql/tpch-views.sql` 改 `CREATE OR REPLACE VIEW`（否则换数据集后旧视图还指向 SF1）。`--label` 没做：一轮一个目录（`round<k>/`）就够了
- ✅ `tests/expected/tpch-sf10/`（DuckDB 基线，19 s 生成，Q11 171,440 行 / Q16 27,840 行 gz，共 1.6 MB，进仓库）

不改：翻译器、伪 BE 执行路径、引擎。（伪 BE 不上报 CPU 数这件事本该在 `node.rs` 里补 `FrontendService.report`，这次用 DROPP 绕开，见 §6.2。）

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
11. **伪 BE 注册着就会把 Doris 的自动并行度压到 1**（§6.2）：任何"同一个 FE 上两个 BE"的对比都要先摘掉伪 BE，否则 A 的数字是单实例的（SF1 Q1 1.6 s vs 4 实例 1.4 s——差得不多是因为 §10.12 的单 scanner 才是瓶颈）。MVP-A 时应让 `node.rs` 上报真实核数（`TReportRequest.num_cores/pipeline_executor_size`）。
12. **Doris 4.1.4 的 BE 侧文件切分在单文件 `local()` 表上只有一个 scanner 干活（SF1 实测；SF10 的 2.4 GB 文件被 FE 按 512 MB 切成 5 段后 BE 用了 ≈4 核，见 `results.md`）**：默认 `enable_file_scanner_v2 + file_split_size_on_be = 64 MB` 让 FE 把整个文件当一个 range 发给 BE、由 BE 再切；profile 里 `NumScanners: 64` 但 `PerScannerRunningTime` 只有一个是秒级，其余微秒——scan 单线程（SF1 Q1 1.4 s）。`SET file_split_size_on_be = 0` 回到 FE 切 32/64 MB range 的老路（16 个 scanner，0.65 s）；`enable_file_scanner_v2 = false` 也行（0.59 s）。报告里 stock 默认（A）和 A-split 都给，主表加速比对 A-split。这是 Doris 外表路径的问题，内表（C）不受影响。

## 11. 报告模板（`results.md`）

主表（**SF100**，热跑中位数，ms；SF10/SF1 同格式作规模表）：

| q | A Doris wall | B′ Sirius wall | **speedup** | B′ engine | R1 DuckDB | R2 Sirius 透明 | 备注（降级 / 校验 / 结果行数） |

辅表：冷跑（A / B / B′ 第 1 轮）、power 总时间、几何平均加速比、每美元加速比（T1′）、规模表（SF1 / SF10 / SF100 的加速比怎么随规模变、哪些查询在 SF100 上走了 host tier）；资源表（GPU 峰值、RSS、read_bytes）；环境快照（机型、commit、驱动、配置哈希、`SHOW VARIABLES` 两套、价格）。

## 12. 待用户拍板

| # | 问题 | 建议 |
|---|---|---|
| Q1 | 现在这台是否 sudo 挂载实例盘 NVMe（`sudo mkfs.ext4 /dev/nvme1n1 && sudo mkdir -p /mnt/nvme && sudo mount /dev/nvme1n1 /mnt/nvme && sudo chown yy2 /mnt/nvme`；停机即清，数据 3 min 可重生成） | **挂**——否则冷跑和 Sirius 默认 O_DIRECT 路径都只反映 EBS |
| Q2 | 正式数字用哪台：g6e.4xlarge（推荐，$3/h）还是 g6e.2xlarge（$2.24/h，Doris 只有 8 vCPU） | **g6e.4xlarge**；先申请 G 系列 vCPU 配额 ≥ 32 |
| Q3 | 要不要 T1′ 成本对齐的 CPU 机（c7i.12xlarge ≈$2.1/h） | 要——这是论文口径，也是最难被反驳的口径 |
| Q4 | 要不要 T2 加测机（p5.4xlarge H100 $6.88/h 或 g7e.2xlarge $3.36/h，只跑 Sirius 侧） | 主结论出来后再定；g7e 有验证 Blackwell 的附带价值 |
| Q5 | 是否做可选参照 C（Doris 内表） | 做，但放在最后、不进主表；读者一定会问"Doris 主场差多少" |
| Q6 | 轮次 1 冷 + 3 热够不够；规模：T0 只跑 SF10（SF100 在 30 GB / 16 GB 机器上没意义），T1 主表 SF100 + SF10 规模点 + SF1 | 够；按 §5.0 |
