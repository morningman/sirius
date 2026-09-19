# Doris vs Doris + Sirius · TPC-H SF100 / SF10 / SF1 · T1 结果（g6e.8xlarge，2026-09-19）

> **这是主结论机（T1）的数字。** 机器：AWS **g6e.8xlarge** = NVIDIA **L40S 48 GB**（CC 8.9，显存带宽 864 GB/s，PCIe 4.0 ×16）、**32 vCPU** AMD EPYC 7R13、248 GiB 内存、两块 450 GB 实例盘做 RAID0（真实文件 O_DIRECT 顺序读 **2.0–3.2 GB/s**）；$4.529/h。同机对比：Doris 拿全部 32 核，Sirius 拿 L40S + 1～2 个核。T0（g4dn.2xlarge，T4 / 8 vCPU）的数字在文末附录，只作跑通记录。
> 方法（`plan.md`）：同一个 FE 4.1.4、同一份 parquet（一表一文件，NVMe 上）、同一批 22 条 SQL（Doris tpch-tools 版）；每个系统 1 冷（进程新起 + `drop_caches`）+ 3 热，热 = 中位数；**每一轮的 22 个结果都过 DuckDB 基线校验**（SF100 7 个系统、SF10/SF1 8 个系统 × 88 条，全部 OK；Q1 的 `avg` 差 1 ulp 是已知的 `--ulps 1`）。原始数据在 GPU 机 `experimental/doris/log/bench-t1/<sf>-<system>/`（`rounds.csv`、`env.txt`、`variables.txt`、`telemetry/`、每轮每条的 `result.tsv`/`explain.txt`），跑法 `experimental/doris/README.md`「Benchmark」。SF100 全套 57 min、SF10 11 min、SF1 ≈10 min。

## 1. 一眼看完（热跑，22 条合计，秒）

### 1.1 主表：SF100（parquet 38 GB，lineitem 25.75 GB 单文件）

| 系统 | 是什么 | 22 条合计 | 相对 A | 用了几个核 |
|---|---|---|---|---|
| **A `native`** | Doris 官方 BE 4.1.4，外表 `local()` 读 parquet，**stock 默认**会话变量（SF100 上 Doris 更快的配置，见 §2.2） | **154.8** | 1× | ≈21 |
| A-split `native-split` | 同上，只多 `file_split_size_on_be = 0`（FE 侧切 32/64 MB；SF10 上更快，SF100 上更慢） | 205.9 | 0.75× | ≈26 |
| C `native-olap` | Doris 内表（官方 SF100 DDL 分桶 96 + colocate + ANALYZE），Doris 主场 | **18.0** | 8.6× | ≈22 |
| B `sirius` | Doris + Sirius 伪 BE，Sirius 默认 **O_DIRECT** 直读 parquet（每轮从盘读 181 GiB） | 141.7（引擎 138.6） | 1.09× | ≈1.0 |
| **B′ `sirius-buffered`** | 同上，`use_odirect: false` 走 page cache（Doris IO 路径的对应物，主表口径） | **98.6**（引擎 95.6） | **1.56×（几何平均 1.34×）** | ≈1.5 |
| R1 `duckdb` | DuckDB 1.5.5，32 线程，单进程 | **39.0** | 3.97× | ≈23 |
| R2 `duckdb-gpu` | Sirius 透明路径（DuckDB 规划、同一引擎、O_DIRECT） | 94.7 | 1.63× | ≈1.2 |

冷跑（第 1 轮）合计：A 163.6、A-split 206.8、C 21.3、B 144.4、B′ 112.0、R1 52.0、R2 94.8。GPU 池高水位 **35.6 GiB**（Q9；Q1 29.4、Q4 32.1），在 41.4 GB 的池子里，**HOST/DISK tier 一个批都没落**（telemetry 6036 个批全在 GPU-0，spill 目录空）。

### 1.2 规模表（热跑 22 条合计，秒；A = 该规模上 Doris 更快的外表配置）

| SF | parquet | A（Doris 外表） | A-split | C 内表 | B O_DIRECT | **B′** | R1 DuckDB 32 线程 | R2 透明路径 | R2-pinned（表常驻显存） | **A / B′** 几何平均 · 总时间 |
|---|---|---|---|---|---|---|---|---|---|---|
| SF1 | 0.25 GB | 8.07（stock）/ **5.23（split）** | — | 1.76 | 3.12 | **3.25**（引擎 1.25） | 1.25 | 1.13 | **0.62** | 1.53× · 1.59×（对 split；wall 的 60 % 是 FE 规划 + RPC） |
| SF10 | 3.6 GB | 28.5（stock）/ **15.0（split）** | — | 2.9 | 12.4 | **12.2** | 4.1 | 7.9 | **2.0** | **1.09× · 1.23×**（对 split） |
| SF100 | 38 GB | **154.8（stock）** / 205.9（split） | — | 18.0 | 141.7 | **98.6** | 39.0 | 94.7 | 装不下 41 GB 显存，未跑 | **1.34× · 1.56×**（对 stock） |

## 2. 怎么读这些数字

1. **主表口径（SF100，A stock vs B′）：GPU 路径快 1.3～1.6×（几何平均 1.34×，power 总时间 1.56×）**，单条从 0.63×（Q14、Q21）到 5.24×（Q3）。赢的都是大扫描 + 大聚合/大 join：Q3 5.2×、Q18 4.2×、Q13 2.7×、Q10 2.5×、Q16 2.5×、Q9 2.2×、Q5 1.6×、Q8 1.5×；输的是 Q21（14.8 s vs 9.3 s）、Q14 0.63×、Q15 0.70×、Q7 0.73×、Q6 0.75×、Q12 0.76×——多是 lineitem 上的窄扫描 + 少量计算，Doris 32 核把 parquet 解码摊得很开，而 Sirius 每条都要把用到的列走一遍 page cache → pinned host → PCIe → GPU 解码。SF10 上同口径只有 1.09× / 1.23×（对 split）：单条几百毫秒，固定开销（FE 规划 40～300 ms + RPC + 扫描启动）占大头。**T0 的 2.03× 是 8 核 Doris 的成绩，不能沿用。**
2. **A 的基线要按规模选 Doris 更快的配置**：SF10 上 `file_split_size_on_be = 0`（FE 侧切 32/64 MB）让 stock 的 28.5 s 变 15.0 s（单文件外表 stock 只有几个 scanner）；SF100 上 stock 的两级切分（512 MB 段 + BE 侧 64 MB）已经能用 21 核，再切小反而 205.9 s（26 核、RSS 85 GB、更多 scanner 元数据）。报告里 SF10 对 split、SF100 对 stock；两者都跑了，`log/bench-t1/` 里都有。
3. **GPU 大部分时间空着，引擎是搬运瓶颈不是算力瓶颈**：B′ 在 SF100 上 `nvidia-smi utilization.gpu` 按查询窗口取均值的中位数只有 **22 %**（Q13 50 %、Q11 37 %、Q1 36 %），显存控制器忙 2.5 %；SF10 同样 20 %（T4 上也是 20 %）。SF10 的 `duckdb-gpu-pinned`（8 张表先 pin 进显存，再跑 22 条）只要 **2.0 s**——同一引擎、同一批 plan，不扫 parquet 不 H2D 就是 4× 于 R2 的 7.9 s、5× 于伪 BE 引擎时间 10.0 s。也就是说算子本身很快，时间花在 parquet 解码 + 数据搬运上；L40S 相对 T4 只把引擎时间压了 ≈2×（SF10 B′ 引擎 T4 ≈19 s → 10 s），显存带宽 2.7× 没有全兑现。对症的是预取/常驻缓存（`pin_table`、`enable_prefetch_cache`），而不是更强的卡。
4. **伪 BE 的 plan 比 DuckDB 自己规划的慢 1.42×（几何平均，SF100 热，B vs R2，同样 O_DIRECT）**，22 条**全部**变慢（1.04×～2.04×：Q18 2.04×、Q15 1.95×、Q21 1.93×、Q22 1.82×、Q12 1.57×、Q4 1.56×）；SF10 上是 1.28×，T0（T4）上是 0.99×——**规模越大、卡越快，plan 形状的代价越明显**。均匀变慢说明不是个别 join 顺序，而是系统性的：翻译器发出的每条 9～25 个恒等 `Project`（DuckDB 优化器不折叠，`semantics-gaps`/handoff 里记过"只影响时间"）和 Q18 那种三层重复 Sort，在 SF100 的宽 lineitem 上每个都要物化一遍。**这是下一步最值得在翻译器里修的一项（折叠恒等投影、消重复 Sort），预期把 B′ 从 98.6 s 拉到 R2 的 ≈70 s 量级（R2 走 page cache 会比 94.7 更低）。**
5. **B 的 O_DIRECT 在这台盘上已经不是主要损失**：B 141.7 s vs B′ 98.6 s（1.44×），每轮从 RAID0 读 181 GiB（22 条各读自己用到的列，列裁剪有效），有效读速 ≈1.3 GB/s 与单流 `dd` 一致；T0 上是 54.6 vs 21.0（盘 0.4 GB/s）。R2 同样 O_DIRECT 却只要 94.7 s ≈ B′——第 4 条的 plan 代价在 B 上叠在读盘上。
6. **DuckDB 32 线程是这台机器上最强的单机参照**：SF100 39.0 s、SF10 4.1 s，比 B′ 快 2.5～3×，比 Doris 外表快 4×。T0 上 8 线程 DuckDB ≈ Sirius；换 32 个 EPYC 核后 CPU 参照抬了 4×，GPU 路径只抬了 2×。这是"GPU 引擎 vs 单机列存 CPU 引擎"的诚实对照，和主表口径（Doris 外表 vs Doris+Sirius）是两回事，但读者一定会问。
7. **Doris 内表（C）18.0 s，比 B′ 快 5.5×、比自己的外表快 8.6×**：分桶 + colocate join + zone map/前缀索引 + 列存直读，没有 parquet 解码；Q3 0.38 s、Q6 0.09 s、Q18 2.9 s。GPU 路径要在 Doris 主场上有意义，得先解决"数据在哪"（常驻 GPU/host 的列缓存，即 MVP-A 之后的事），parquet 外表口径只能证明"同一份 parquet 上 GPU 比 Doris 外表快"。
8. **资源**：B/B′ 进程 RSS 12–13 GiB（不含 160 GiB pinned host tier 的 first-touch 部分）、CPU 1～1.5 核；A 21 核、RSS 60 GB（split 26 核 / 85 GB）；R1 23 核 / 15.7 GB；C 22 核 / 50 GB。GPU 池预留 41.4 GB（`usage_limit_fraction 0.9`），host tier 配 160 GiB（`bench-all.sh --host-capacity`，给 B′ 的 38 GB page cache 留位置；透明路径日志里 host pool 高水位只有 3.8 GiB——读盘的 staging，没有降级）。
9. **FE 侧开销在 SF100 上可以忽略**：B′ 的 wall − engine ≈ 90～250 ms/条（Nereids 规划 40～144 ms，Q21 最贵），引擎时间占 wall 的 97 %；SF10 上占 82 %，SF1 上不到一半。
10. **SF100 装得下 L40S**：GPU 池高水位 35.6 GiB（Q9），没有 host/disk 降级。按线性外推 SF300 就会溢出到 host tier——那才是 plan §10.2 想看的场景，本轮没看到。

## 3. 这次换机跑通过程中修掉的方法问题（都已进脚本 / 文档）

- `olap-load.sh` 换 SF 会撞 colocate 桶数（Doris DDL 的 `DROP TABLE` 不带 FORCE，旧表在回收站里占着组）：改为 `DROP DATABASE ... FORCE` 后重建；
- `be-native.sh` 起 BE 只等 90 s，重启后第一次冷读 EBS 上 2.65 GB 的二进制要 ≈2 min（热起 9 s）：等待上限提到 300 s；
- `bench-all.sh` 加 `--expected DIR`（SF100 基线在 NVMe 上不进仓库）和 `--host-capacity` 转发；
- `tpchgen-cli` 是 `-C target-cpu=native` 编的，Xeon → EPYC 直接 SIGILL，且 cargo 指纹不认 CPU 变化，要 `rm -rf target` 重编；
- 换机 = 实例盘清零 → FE 元数据 `fe.sh clean` 一起清，原生 BE 的唯一 storage root 从第一次起就在 NVMe；两块实例盘 `mdadm` RAID0；
- SF100 上 `native-split` 比 stock 慢，报告基线按规模选（`bench-report.py report --baseline native`）。

## 4. 下一步

1. **T1′ 成本对齐**：c7i.24xlarge（$4.28/h，配 8xlarge）只搭 FE + 原生 BE，跑 `native`/`native-split`/`native-olap` SF100，`bench-report.py report --runs <两台的目录> --price native=4.28 --price sirius-buffered=4.529` 出每美元加速比（同机口径下 1.34×，CPU 机便宜 5 % 后 ≈1.27×，Doris 在 96 核上还会更快——这一行大概率接近 1×，要如实写）。
2. **翻译器折叠恒等投影 / 重复 Sort**（§2 第 4 条），然后只重跑 B′ 与 R2 的 SF100，看 1.42× 收回多少。
3. `duckdb-gpu-pinned` 的 SF100 版本用 `SIRIUS_PIN_TIER=host`（表常驻 pinned host，省 parquet 解码）——引擎上限的另一个点。
4. T2（H100 / RTX PRO 6000）只在 §2 第 3 条的搬运瓶颈解决后才有意义。

---

以下为 `scripts/bench-report.py report` 自动生成的完整表（英文）：SF100、SF10、SF1 各一份。


## SF100 · g6e.8xlarge (L40S, 32 vCPU) · 2026-09-19 — auto-generated

Systems: `native` (4 round(s)), `native-split` (4 round(s)), `sirius` (4 round(s)), `sirius-buffered` (4 round(s)), `duckdb` (4 round(s)), `duckdb-gpu` (4 round(s)), `native-olap` (4 round(s)). Round 1 is cold (freshly started process, page cache evicted), the others hot; **hot** = median of the hot rounds, (min) in parentheses; ms of client round trip (`wall_ms`). Queries that did not validate against the DuckDB baseline in every round are marked and excluded from speedups and totals.

### Hot runs (median wall ms, min in parentheses)

| q | native | native-split | sirius | sirius-buffered | duckdb | duckdb-gpu | native-olap | speedup native/sirius-buffered | sirius-buffered engine ms | notes |
|---|---|---|---|---|---|---|---|---|---|---|
| q01 | 5,339 (5,327) | 7,955 (7,882) | 4,415 (4,396) | 3,963 (3,960) | 2,125 (2,104) | 3,379 (2,994) | 2,644 (2,624) | **1.35×** | 3,874 |  |
| q02 | 1,814 (1,811) | 1,102 (1,097) | 1,287 (1,287) | 1,251 (1,235) | 407 (406) | 1,144 (1,121) | 128 (119) | **1.45×** | 1,049 |  |
| q03 | 20,270 (20,092) | 24,030 (23,979) | 5,985 (5,980) | 3,868 (3,867) | 1,734 (1,712) | 4,636 (4,631) | 384 (382) | **5.24×** | 3,741 |  |
| q04 | 3,359 (3,295) | 5,875 (5,843) | 3,738 (3,693) | 3,089 (3,034) | 1,279 (1,269) | 2,412 (2,345) | 172 (161) | **1.09×** | 3,002 |  |
| q05 | 8,721 (8,684) | 12,147 (12,069) | 8,509 (8,483) | 5,320 (5,310) | 1,812 (1,806) | 5,865 (5,854) | 511 (504) | **1.64×** | 5,152 |  |
| q06 | 2,046 (1,983) | 4,125 (4,124) | 3,672 (3,658) | 2,716 (2,657) | 785 (779) | 2,959 (2,927) | 90 (89) | **0.75×** | 2,650 |  |
| q07 | 4,176 (4,172) | 6,390 (6,367) | 9,020 (9,011) | 5,696 (5,649) | 1,548 (1,543) | 6,233 (6,221) | 395 (383) | **0.73×** | 5,507 |  |
| q08 | 11,059 (10,871) | 13,033 (13,027) | 11,705 (11,704) | 7,163 (7,113) | 1,678 (1,677) | 7,749 (7,747) | 481 (472) | **1.54×** | 6,943 |  |
| q09 | 14,681 (14,522) | 17,040 (17,010) | 11,552 (11,535) | 6,736 (6,698) | 4,272 (4,255) | 8,588 (8,566) | 2,551 (2,512) | **2.18×** | 6,544 |  |
| q10 | 11,537 (11,434) | 14,435 (13,716) | 6,782 (6,747) | 4,551 (4,527) | 1,967 (1,956) | 4,594 (4,590) | 756 (748) | **2.54×** | 4,406 |  |
| q11 | 1,153 (1,141) | 1,409 (1,293) | 1,140 (1,139) | 1,078 (1,059) | 249 (247) | 1,109 (1,099) | 380 (370) | **1.07×** | 948 |  |
| q12 | 2,781 (2,706) | 5,073 (5,037) | 4,424 (4,415) | 3,673 (3,630) | 1,264 (1,246) | 2,839 (2,838) | 429 (425) | **0.76×** | 3,579 |  |
| q13 | 3,763 (3,745) | 3,839 (3,836) | 2,666 (2,663) | 1,416 (1,393) | 2,531 (2,527) | 2,427 (2,423) | 1,893 (1,873) | **2.66×** | 1,363 |  |
| q14 | 2,434 (2,417) | 4,271 (4,260) | 6,003 (5,967) | 3,853 (3,791) | 1,260 (1,259) | 4,651 (4,595) | 153 (147) | **0.63×** | 3,743 |  |
| q15 | 4,521 (4,477) | 8,458 (8,395) | 8,729 (8,671) | 6,469 (6,433) | 1,305 (1,294) | 4,527 (4,493) | 292 (287) | **0.70×** | 6,319 |  |
| q16 | 1,355 (1,331) | 870 (834) | 554 (548) | 546 (542) | 463 (460) | 412 (410) | 450 (441) | **2.48×** | 456 |  |
| q17 | 8,049 (8,022) | 11,776 (11,722) | 9,355 (9,338) | 6,091 (6,003) | 1,592 (1,582) | 6,380 (6,341) | 358 (309) | **1.32×** | 5,960 |  |
| q18 | 29,349 (28,630) | 35,550 (33,442) | 7,880 (7,848) | 6,921 (6,889) | 3,523 (3,508) | 3,902 (3,884) | 2,890 (2,791) | **4.24×** | 6,755 |  |
| q19 | 3,162 (3,004) | 4,805 (4,721) | 5,420 (5,418) | 3,858 (3,692) | 1,684 (1,589) | 4,557 (4,525) | 495 (371) | **0.82×** | 3,732 |  |
| q20 | 4,123 (4,109) | 6,157 (6,078) | 6,943 (6,940) | 4,467 (4,407) | 1,333 (1,274) | 4,922 (4,900) | 522 (503) | **0.92×** | 4,291 |  |
| q21 | 9,330 (9,253) | 15,817 (15,741) | 20,631 (20,618) | 14,849 (14,844) | 5,231 (5,094) | 10,728 (10,705) | 1,661 (1,459) | **0.63×** | 14,602 |  |
| q22 | 1,349 (1,344) | 1,249 (1,204) | 1,181 (1,170) | 1,129 (1,121) | 820 (802) | 631 (630) | 338 (301) | **1.19×** | 1,039 |  |
| **power total** | **154,371** (22 q) | **205,406** (22 q) | **141,591** (22 q) | **98,703** (22 q) | **38,862** (22 q) | **94,644** (22 q) | **17,973** (22 q) | **geomean 1.34×**, total 1.56× | 95,654 |  |

Cost-normalized (plan §7): native at $4.529/h vs sirius-buffered at $4.529/h → geomean speedup per dollar **1.34×**.

### Cold run (round 1, wall ms)

| q | native | native-split | sirius | sirius-buffered | duckdb | duckdb-gpu | native-olap |
|---|---|---|---|---|---|---|---|
| q01 | 5,699 | 8,297 | 5,133 | 7,708 | 10,272 | 3,470 | 4,072 |
| q02 | 2,027 | 1,240 | 1,394 | 1,743 | 2,798 | 1,152 | 394 |
| q03 | 20,615 | 24,543 | 6,003 | 5,383 | 4,368 | 4,618 | 825 |
| q04 | 4,397 | 6,148 | 4,292 | 3,281 | 1,287 | 2,433 | 512 |
| q05 | 8,647 | 12,040 | 8,571 | 6,253 | 1,987 | 5,823 | 1,012 |
| q06 | 2,217 | 4,113 | 3,734 | 2,782 | 785 | 2,906 | 108 |
| q07 | 4,318 | 6,340 | 9,080 | 6,147 | 1,508 | 6,279 | 426 |
| q08 | 11,023 | 13,051 | 11,766 | 8,136 | 1,651 | 7,790 | 672 |
| q09 | 14,445 | 16,906 | 11,577 | 7,194 | 4,227 | 8,596 | 2,744 |
| q10 | 12,392 | 13,881 | 6,828 | 4,883 | 1,971 | 4,604 | 868 |
| q11 | 1,122 | 1,412 | 1,151 | 1,342 | 251 | 1,108 | 389 |
| q12 | 2,667 | 5,042 | 4,516 | 3,747 | 1,257 | 2,828 | 444 |
| q13 | 3,880 | 3,933 | 2,644 | 2,227 | 2,541 | 2,435 | 1,917 |
| q14 | 2,466 | 4,267 | 6,026 | 3,873 | 1,241 | 4,631 | 149 |
| q15 | 4,576 | 8,405 | 8,757 | 6,444 | 1,280 | 4,563 | 275 |
| q16 | 1,406 | 894 | 1,023 | 652 | 476 | 455 | 447 |
| q17 | 8,029 | 11,722 | 9,279 | 6,032 | 1,595 | 6,374 | 318 |
| q18 | 35,997 | 36,503 | 7,834 | 6,893 | 3,682 | 3,901 | 2,928 |
| q19 | 3,025 | 4,685 | 5,458 | 3,692 | 1,745 | 4,530 | 369 |
| q20 | 4,163 | 6,239 | 6,967 | 4,419 | 1,283 | 4,924 | 506 |
| q21 | 9,069 | 15,879 | 21,212 | 18,047 | 5,031 | 10,735 | 1,626 |
| q22 | 1,375 | 1,249 | 1,189 | 1,133 | 744 | 638 | 305 |
| **total** | 163,555 | 206,789 | 144,434 | 112,011 | 51,980 | 94,793 | 21,306 |

### FE audit (hot medians, ms): fe = FE end-to-end, plan = Nereids planning, rpc1 = first exec RPC

| q | native fe / plan / rpc1 | native-split fe / plan / rpc1 | sirius fe / plan / rpc1 | sirius-buffered fe / plan / rpc1 | native-olap fe / plan / rpc1 |
|---|---|---|---|---|---|
| q01 | 5,326 / 102 / 5 | 7,942 / 171 / 8 | 4,403 / 41 / 4,359 | 3,950 / 40 / 3,908 | 2,632 / 2 / 8 |
| q02 | 1,801 / 65 / 19 | 1,090 / 73 / 23 | 1,275 / 46 / 1,228 | 1,234 / 45 / 1,188 | 115 / 10 / 16 |
| q03 | 20,257 / 141 / 10 | 24,017 / 158 / 18 | 5,972 / 78 / 5,893 | 3,855 / 73 / 3,780 | 372 / 5 / 13 |
| q04 | 3,347 / 195 / 8 | 5,862 / 136 / 14 | 3,725 / 53 / 3,668 | 3,077 / 71 / 3,023 | 160 / 3 / 13 |
| q05 | 8,709 / 159 / 15 | 12,135 / 163 / 22 | 8,496 / 78 / 8,416 | 5,307 / 70 / 5,226 | 498 / 18 / 20 |
| q06 | 2,034 / 156 / 4 | 4,112 / 154 / 6 | 3,659 / 41 / 3,616 | 2,703 / 41 / 2,661 | 79 / 3 / 4 |
| q07 | 4,164 / 157 / 16 | 6,377 / 159 / 21 | 9,006 / 88 / 8,913 | 5,684 / 88 / 5,593 | 382 / 19 / 24 |
| q08 | 11,046 / 166 / 18 | 13,019 / 170 / 29 | 11,693 / 97 / 11,595 | 7,151 / 87 / 7,064 | 469 / 37 / 34 |
| q09 | 14,664 / 161 / 15 | 17,028 / 183 / 27 | 11,539 / 86 / 11,464 | 6,723 / 72 / 6,633 | 2,539 / 19 / 20 |
| q10 | 11,524 / 147 / 10 | 14,423 / 174 / 18 | 6,769 / 65 / 6,700 | 4,538 / 65 / 4,461 | 743 / 7 / 15 |
| q11 | 1,140 / 50 / 16 | 1,396 / 52 / 21 | 1,128 / 34 / 1,092 | 1,065 / 35 / 1,024 | 367 / 7 / 19 |
| q12 | 2,768 / 176 / 8 | 5,059 / 174 / 14 | 4,412 / 69 / 4,341 | 3,661 / 70 / 3,607 | 416 / 4 / 13 |
| q13 | 3,750 / 31 / 8 | 3,827 / 35 / 13 | 2,653 / 18 / 2,632 | 1,403 / 16 / 1,382 | 1,881 / 4 / 15 |
| q14 | 2,416 / 143 / 6 | 4,259 / 124 / 11 | 5,990 / 48 / 5,940 | 3,840 / 67 / 3,771 | 141 / 4 / 9 |
| q15 | 4,509 / 251 / 9 | 8,445 / 230 / 16 | 8,717 / 87 / 8,605 | 6,456 / 87 / 6,367 | 280 / 7 / 17 |
| q16 | 1,331 / 29 / 10 | 845 / 30 / 16 | 531 / 21 / 504 | 522 / 20 / 497 | 428 / 5 / 18 |
| q17 | 8,036 / 222 / 9 | 11,763 / 246 / 19 | 9,343 / 110 / 9,230 | 6,079 / 83 / 5,995 | 346 / 5 / 12 |
| q18 | 29,336 / 242 / 12 | 35,538 / 294 / 26 | 7,867 / 115 / 7,770 | 6,909 / 97 / 6,814 | 2,877 / 8 / 17 |
| q19 | 3,148 / 178 / 7 | 4,790 / 192 / 12 | 5,408 / 67 / 5,353 | 3,844 / 69 / 3,773 | 482 / 8 / 9 |
| q20 | 4,103 / 139 / 15 | 6,137 / 166 / 25 | 6,923 / 65 / 6,851 | 4,446 / 76 / 4,365 | 503 / 8 / 22 |
| q21 | 9,317 / 356 / 16 | 15,803 / 378 / 31 | 20,619 / 156 / 20,457 | 14,835 / 144 / 14,684 | 1,649 / 23 / 21 |
| q22 | 1,336 / 42 / 13 | 1,236 / 45 / 19 | 1,168 / 29 / 1,138 | 1,117 / 27 / 1,078 | 325 / 8 / 20 |

### Resources (hot medians): peak RSS MiB / bytes read from disk MiB / CPU cores busy / GPU MiB in use / GPU busy % / GPU memory-controller busy %

| q | native | native-split | sirius | sirius-buffered | duckdb | duckdb-gpu | native-olap |
|---|---|---|---|---|---|---|---|
| q01 | 7,936 / 0 / 26.3 / - / - / - | 28,680 / 0 / 27.7 / - / - / - | 11,926 / 6,234 / 1.5 / 41,421 / 36 / 10 | 11,875 / 0 / 1.8 / 41,421 / 35 / 13 | 2,377 / 0 / 22.0 / - / - / - | 1,956 / 7,296 / 2.6 / 41,383 / 32 / 5 | 42,819 / 0 / 26.2 / - / - / - |
| q02 | 7,931 / 0 / 10.4 / - / - / - | 27,765 / 0 / 20.1 / - / - / - | 11,926 / 2,710 / 1.1 / 41,421 / 0 / 0 | 11,875 / 0 / 1.4 / 41,421 / 25 / 1 | 2,377 / 0 / 17.6 / - / - / - | 1,956 / 2,431 / 1.1 / 41,391 / 30 / 0 | 42,819 / 0 / 16.2 / - / - / - |
| q03 | 21,517 / 0 / 6.0 / - / - / - | 38,595 / 0 / 8.6 / - / - / - | 11,996 / 8,913 / 1.0 / 41,421 / 15 / 3 | 12,005 / 0 / 1.5 / 41,421 / 27 / 2 | 2,909 / 0 / 24.1 / - / - / - | 2,104 / 9,162 / 1.8 / 41,391 / 21 / 1 | 43,019 / 0 / 18.5 / - / - / - |
| q04 | 22,039 / 0 / 21.3 / - / - / - | 41,147 / 0 / 26.7 / - / - / - | 12,057 / 4,553 / 1.2 / 41,421 / 10 / 0 | 12,009 / 0 / 1.5 / 41,421 / 15 / 8 | 3,350 / 0 / 24.5 / - / - / - | 2,095 / 4,977 / 1.9 / 41,393 / 23 / 1 | 43,440 / 0 / 21.5 / - / - / - |
| q05 | 22,039 / 0 / 10.6 / - / - / - | 41,147 / 0 / 14.7 / - / - / - | 12,087 / 11,668 / 0.9 / 41,421 / 14 / 2 | 12,110 / 0 / 1.4 / 41,421 / 22 / 5 | 3,482 / 0 / 25.4 / - / - / - | 2,101 / 11,952 / 1.6 / 41,393 / 19 / 2 | 43,440 / 0 / 22.1 / - / - / - |
| q06 | 12,244 / 0 / 22.3 / - / - / - | 28,070 / 0 / 26.8 / - / - / - | 12,083 / 5,756 / 1.1 / 41,421 / 15 / 0 | 12,110 / 0 / 1.6 / 41,421 / 24 / 2 | 3,482 / 0 / 21.0 / - / - / - | 2,101 / 5,756 / 1.9 / 41,393 / 24 / 6 | 43,440 / 0 / 22.4 / - / - / - |
| q07 | 11,037 / 0 / 22.9 / - / - / - | 27,772 / 0 / 26.3 / - / - / - | 12,099 / 12,711 / 1.0 / 41,421 / 16 / 2 | 11,966 / 0 / 1.6 / 41,421 / 27 / 3 | 4,336 / 0 / 25.1 / - / - / - | 2,368 / 12,329 / 0.9 / 41,393 / 16 / 3 | 43,458 / 0 / 21.8 / - / - / - |
| q08 | 47,055 / 0 / 23.1 / - / - / - | 70,826 / 0 / 25.9 / - / - / - | 12,149 / 14,933 / 0.8 / 41,421 / 13 / 2 | 12,058 / 0 / 1.4 / 41,421 / 20 / 3 | 4,336 / 0 / 25.7 / - / - / - | 2,198 / 15,230 / 0.7 / 41,393 / 18 / 0 | 43,618 / 0 / 23.3 / - / - / - |
| q09 | 61,654 / 0 / 23.4 / - / - / - | 87,241 / 0 / 24.8 / - / - / - | 12,197 / 15,699 / 0.8 / 41,421 / 19 / 3 | 12,071 / 0 / 1.6 / 41,421 / 29 / 5 | 16,062 / 0 / 25.9 / - / - / - | 5,629 / 15,699 / 1.8 / 41,401 / 23 / 4 | 48,379 / 0 / 23.4 / - / - / - |
| q10 | 46,750 / 0 / 9.4 / - / - / - | 64,457 / 0 / 14.2 / - / - / - | 12,197 / 9,362 / 1.1 / 41,421 / 16 / 3 | 12,069 / 0 / 1.6 / 41,421 / 24 / 2 | 16,052 / 0 / 20.9 / - / - / - | 5,663 / 10,169 / 1.9 / 41,403 / 21 / 1 | 47,904 / 0 / 20.8 / - / - / - |
| q11 | 11,531 / 0 / 10.4 / - / - / - | 14,523 / 0 / 19.9 / - / - / - | 11,969 / 2,907 / 0.9 / 41,421 / 1 / 0 | 11,972 / 0 / 1.1 / 41,421 / 34 / 1 | 5,418 / 0 / 16.6 / - / - / - | 5,663 / 2,600 / 1.4 / 41,405 / 22 / 0 | 47,520 / 0 / 22.9 / - / - / - |
| q12 | 11,073 / 0 / 21.3 / - / - / - | 30,396 / 0 / 28.3 / - / - / - | 11,882 / 5,466 / 1.2 / 41,421 / 16 / 1 | 11,890 / 0 / 1.6 / 41,421 / 14 / 2 | 5,418 / 0 / 25.7 / - / - / - | 5,683 / 6,534 / 1.4 / 41,405 / 19 / 4 | 46,910 / 0 / 25.6 / - / - / - |
| q13 | 7,497 / 0 / 21.7 / - / - / - | 27,906 / 0 / 26.3 / - / - / - | 11,877 / 4,702 / 0.7 / 41,421 / 28 / 8 | 11,890 / 0 / 1.6 / 41,421 / 50 / 14 | 8,227 / 0 / 29.1 / - / - / - | 5,683 / 5,171 / 1.3 / 41,405 / 26 / 4 | 46,442 / 0 / 25.9 / - / - / - |
| q14 | 8,738 / 0 / 22.4 / - / - / - | 24,705 / 0 / 26.1 / - / - / - | 12,000 / 9,097 / 1.0 / 41,421 / 14 / 1 | 12,036 / 0 / 1.5 / 41,421 / 19 / 4 | 8,227 / 0 / 21.1 / - / - / - | 5,644 / 9,709 / 1.6 / 41,405 / 18 / 3 | 44,476 / 0 / 18.3 / - / - / - |
| q15 | 12,252 / 0 / 25.6 / - / - / - | 41,641 / 0 / 29.0 / - / - / - | 12,000 / 9,196 / 0.9 / 41,421 / 11 / 2 | 12,036 / 0 / 1.3 / 41,421 / 10 / 2 | 5,837 / 0 / 22.2 / - / - / - | 5,948 / 9,551 / 1.5 / 41,409 / 22 / 4 | 43,760 / 0 / 19.5 / - / - / - |
| q16 | 11,758 / 0 / 7.4 / - / - / - | 41,462 / 0 / 18.1 / - / - / - | 11,997 / 898 / 0.9 / 41,421 / 58 / 9 | 12,034 / 0 / 1.2 / 41,421 / 0 / 0 | 5,332 / 0 / 24.1 / - / - / - | 5,642 / 843 / 1.0 / 41,409 / 43 / 12 | 43,760 / 0 / 20.6 / - / - / - |
| q17 | 13,856 / 0 / 25.5 / - / - / - | 42,309 / 0 / 28.4 / - / - / - | 12,383 / 12,472 / 0.9 / 41,421 / 12 / 2 | 12,413 / 0 / 1.3 / 41,421 / 19 / 3 | 5,332 / 0 / 21.5 / - / - / - | 6,204 / 12,897 / 1.6 / 41,409 / 17 / 3 | 44,284 / 0 / 22.5 / - / - / - |
| q18 | 37,433 / 0 / 8.0 / - / - / - | 75,932 / 0 / 10.9 / - / - / - | 12,427 / 7,242 / 1.2 / 41,421 / 14 / 5 | 12,416 / 0 / 1.4 / 41,421 / 17 / 6 | 11,133 / 0 / 25.8 / - / - / - | 5,985 / 7,242 / 2.1 / 41,409 / 27 / 9 | 51,588 / 0 / 27.9 / - / - / - |
| q19 | 24,012 / 0 / 18.4 / - / - / - | 42,016 / 0 / 27.9 / - / - / - | 12,427 / 9,095 / 1.3 / 41,421 / 20 / 4 | 12,416 / 0 / 1.9 / 41,421 / 25 / 3 | 5,680 / 0 / 20.7 / - / - / - | 5,923 / 9,651 / 1.4 / 41,409 / 25 / 4 | 51,588 / 0 / 20.5 / - / - / - |
| q20 | 21,352 / 0 / 25.2 / - / - / - | 42,271 / 0 / 27.5 / - / - / - | 12,031 / 9,664 / 0.8 / 41,421 / 13 / 1 | 11,989 / 0 / 1.3 / 41,421 / 22 / 4 | 5,015 / 0 / 18.5 / - / - / - | 5,776 / 10,350 / 1.6 / 41,409 / 22 / 4 | 50,674 / 0 / 21.0 / - / - / - |
| q21 | 17,790 / 0 / 25.2 / - / - / - | 61,396 / 0 / 28.9 / - / - / - | 13,074 / 19,682 / 1.1 / 41,421 / 18 / 4 | 12,719 / 0 / 1.6 / 41,421 / 24 / 7 | 7,548 / 0 / 24.4 / - / - / - | 7,024 / 20,093 / 1.6 / 41,409 / 21 / 4 | 49,651 / 0 / 24.7 / - / - / - |
| q22 | 14,149 / 0 / 11.6 / - / - / - | 55,820 / 0 / 21.4 / - / - / - | 13,074 / 1,545 / 1.5 / 41,421 / 24 / 6 | 12,719 / 0 / 1.6 / 41,421 / 22 / 8 | 5,381 / 0 / 19.1 / - / - / - | 6,112 / 1,962 / 1.2 / 41,411 / 4 / 0 | 46,090 / 0 / 16.6 / - / - / - |

Bytes read from disk = `/proc/<pid>/io read_bytes` delta over the query (0 on a page-cache hit; O_DIRECT reads always count); sampled every 0.5 s, so sub-second queries are attributed approximately. GPU MiB in use is the RMM pool (reserved up front, not a peak); GPU busy % = nvidia-smi `utilization.gpu` (share of time a kernel was running) and memory-controller busy % = `utilization.memory`, both averaged over the query's samples; `-` when the query was shorter than one sample.

### Environment

#### native (`log/bench-t1/sf100-native`)

```
date: 2026-09-19T10:48:53Z
host: ip-172-31-26-244
instance_type: g6e.8xlarge
kernel: 7.0.0-1012-aws
cpu: AMD EPYC 7R13 Processor x 32
mem_total_kib: 260437876
gpu: NVIDIA L40S, 46068 MiB, 580.178.04
system: native
data: /mnt/nvme/tpch_parquet_sf100 (38G) on /dev/md0       ext4
expected: /mnt/nvme/expected-sf100
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f5116c6c docs(doris): T0 results with GPU utilization, SF100 purchase list
sirius_dirty: 3 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb (v1.5.5 (Variegata) 3ff87f1e)
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	true	doris-4.1.4-rc04-ad35a140c7f
-- session variables (GLOBAL) --
parallel_pipeline_task_num	0
experimental_enable_local_shuffle	true
enable_parallel_result_sink	true
runtime_filter_mode	GLOBAL
enable_cte_materialize	true
experimental_topn_lazy_materialization_threshold	1024
file_split_size	0
max_file_split_size	67108864
max_initial_file_split_size	33554432
file_split_size_on_be	67108864
file_split_size_on_fe	536870912
max_file_scanners_concurrency	16
enable_file_scanner_v2	true
enable_fold_constant_by_be	false
enable_profile	false
query_timeout	3600
```

#### native-split (`log/bench-t1/sf100-native-split`)

```
date: 2026-09-19T11:00:34Z
host: ip-172-31-26-244
instance_type: g6e.8xlarge
kernel: 7.0.0-1012-aws
cpu: AMD EPYC 7R13 Processor x 32
mem_total_kib: 260437876
gpu: NVIDIA L40S, 46068 MiB, 580.178.04
system: native-split
data: /mnt/nvme/tpch_parquet_sf100 (38G) on /dev/md0       ext4
expected: /mnt/nvme/expected-sf100
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f5116c6c docs(doris): T0 results with GPU utilization, SF100 purchase list
sirius_dirty: 3 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb (v1.5.5 (Variegata) 3ff87f1e)
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	true	doris-4.1.4-rc04-ad35a140c7f
-- session variables (GLOBAL) --
parallel_pipeline_task_num	0
experimental_enable_local_shuffle	true
enable_parallel_result_sink	true
runtime_filter_mode	GLOBAL
enable_cte_materialize	true
experimental_topn_lazy_materialization_threshold	1024
file_split_size	0
max_file_split_size	67108864
max_initial_file_split_size	33554432
file_split_size_on_be	0
file_split_size_on_fe	536870912
max_file_scanners_concurrency	16
enable_file_scanner_v2	true
enable_fold_constant_by_be	false
enable_profile	false
query_timeout	3600
```

#### sirius (`log/bench-t1/sf100-sirius`)

```
date: 2026-09-19T11:15:35Z
host: ip-172-31-26-244
instance_type: g6e.8xlarge
kernel: 7.0.0-1012-aws
cpu: AMD EPYC 7R13 Processor x 32
mem_total_kib: 260437876
gpu: NVIDIA L40S, 46068 MiB, 580.178.04
system: sirius
data: /mnt/nvme/tpch_parquet_sf100 (38G) on /dev/md0       ext4
expected: /mnt/nvme/expected-sf100
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f5116c6c docs(doris): T0 results with GPU utilization, SF100 purchase list
sirius_dirty: 3 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb ()
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
  c383a210d02de83c9a9791c0a24065ffd1e256da6845d3f9b8539f9a704334e8  log/bench-t1/sf100-sirius/sirius.yaml
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	false	doris-4.1.4-rc04-ad35a140c7f
  127.0.0.1	9050	true	sirius-doris-be/0.1.0
-- session variables (GLOBAL) --
parallel_pipeline_task_num	1
experimental_enable_local_shuffle	false
enable_parallel_result_sink	false
runtime_filter_mode	OFF
enable_cte_materialize	false
experimental_topn_lazy_materialization_threshold	-1
file_split_size	1099511627776
max_file_split_size	67108864
max_initial_file_split_size	33554432
file_split_size_on_be	0
file_split_size_on_fe	1099511627776
max_file_scanners_concurrency	16
enable_file_scanner_v2	true
enable_fold_constant_by_be	false
enable_profile	false
query_timeout	3600
```

#### sirius-buffered (`log/bench-t1/sf100-sirius-buffered`)

```
date: 2026-09-19T11:25:59Z
host: ip-172-31-26-244
instance_type: g6e.8xlarge
kernel: 7.0.0-1012-aws
cpu: AMD EPYC 7R13 Processor x 32
mem_total_kib: 260437876
gpu: NVIDIA L40S, 46068 MiB, 580.178.04
system: sirius-buffered
data: /mnt/nvme/tpch_parquet_sf100 (38G) on /dev/md0       ext4
expected: /mnt/nvme/expected-sf100
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f5116c6c docs(doris): T0 results with GPU utilization, SF100 purchase list
sirius_dirty: 3 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb ()
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
  55f1aeb9f5973536835e6725788356470e001fde0b643a0da5e6a2a5c14206f0  log/bench-t1/sf100-sirius-buffered/sirius.yaml
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	false	doris-4.1.4-rc04-ad35a140c7f
  127.0.0.1	9050	true	sirius-doris-be/0.1.0
-- session variables (GLOBAL) --
parallel_pipeline_task_num	1
experimental_enable_local_shuffle	false
enable_parallel_result_sink	false
runtime_filter_mode	OFF
enable_cte_materialize	false
experimental_topn_lazy_materialization_threshold	-1
file_split_size	1099511627776
max_file_split_size	67108864
max_initial_file_split_size	33554432
file_split_size_on_be	0
file_split_size_on_fe	1099511627776
max_file_scanners_concurrency	16
enable_file_scanner_v2	true
enable_fold_constant_by_be	false
enable_profile	false
query_timeout	3600
```

#### duckdb (`log/bench-t1/sf100-duckdb`)

```
date: 2026-09-19T11:33:28Z
host: ip-172-31-26-244
instance_type: g6e.8xlarge
kernel: 7.0.0-1012-aws
cpu: AMD EPYC 7R13 Processor x 32
mem_total_kib: 260437876
gpu: NVIDIA L40S, 46068 MiB, 580.178.04
system: duckdb
data: /mnt/nvme/tpch_parquet_sf100 (38G) on /dev/md0       ext4
expected: /mnt/nvme/expected-sf100
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f5116c6c docs(doris): T0 results with GPU utilization, SF100 purchase list
sirius_dirty: 3 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb (v1.5.5 (Variegata) 3ff87f1e)
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	false	doris-4.1.4-rc04-ad35a140c7f
  127.0.0.1	9050	true	sirius-doris-be/0.1.0
```

#### duckdb-gpu (`log/bench-t1/sf100-duckdb-gpu`)

```
date: 2026-09-19T11:36:44Z
host: ip-172-31-26-244
instance_type: g6e.8xlarge
kernel: 7.0.0-1012-aws
cpu: AMD EPYC 7R13 Processor x 32
mem_total_kib: 260437876
gpu: NVIDIA L40S, 46068 MiB, 580.178.04
system: duckdb-gpu
data: /mnt/nvme/tpch_parquet_sf100 (38G) on /dev/md0       ext4
expected: /mnt/nvme/expected-sf100
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f5116c6c docs(doris): T0 results with GPU utilization, SF100 purchase list
sirius_dirty: 3 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb (v1.5.5 (Variegata) 3ff87f1e)
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
  187b518c785ba53d0feff86efc3413bb425b5ef8a72bff21badf3e9dde05e379  log/bench-t1/sf100-duckdb-gpu/sirius.yaml
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	false	doris-4.1.4-rc04-ad35a140c7f
  127.0.0.1	9050	false	sirius-doris-be/0.1.0
```

#### native-olap (`log/bench-t1/sf100-native-olap`)

```
date: 2026-09-19T11:43:35Z
host: ip-172-31-26-244
instance_type: g6e.8xlarge
kernel: 7.0.0-1012-aws
cpu: AMD EPYC 7R13 Processor x 32
mem_total_kib: 260437876
gpu: NVIDIA L40S, 46068 MiB, 580.178.04
system: native-olap
data: /mnt/nvme/tpch_parquet_sf100 (38G) on /dev/md0       ext4
expected: /mnt/nvme/expected-sf100
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f5116c6c docs(doris): T0 results with GPU utilization, SF100 purchase list
sirius_dirty: 3 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb (v1.5.5 (Variegata) 3ff87f1e)
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	true	doris-4.1.4-rc04-ad35a140c7f
-- session variables (GLOBAL) --
parallel_pipeline_task_num	0
experimental_enable_local_shuffle	true
enable_parallel_result_sink	true
runtime_filter_mode	GLOBAL
enable_cte_materialize	true
experimental_topn_lazy_materialization_threshold	1024
file_split_size	0
max_file_split_size	67108864
max_initial_file_split_size	33554432
file_split_size_on_be	67108864
file_split_size_on_fe	536870912
max_file_scanners_concurrency	16
enable_file_scanner_v2	true
enable_fold_constant_by_be	false
enable_profile	false
query_timeout	3600
```

## SF10 · g6e.8xlarge (L40S, 32 vCPU) · 2026-09-19 — auto-generated

Systems: `native` (4 round(s)), `native-split` (4 round(s)), `sirius` (4 round(s)), `sirius-buffered` (4 round(s)), `duckdb` (4 round(s)), `duckdb-gpu` (4 round(s)), `duckdb-gpu-pinned` (4 round(s)), `native-olap` (4 round(s)). Round 1 is cold (freshly started process, page cache evicted), the others hot; **hot** = median of the hot rounds, (min) in parentheses; ms of client round trip (`wall_ms`). Queries that did not validate against the DuckDB baseline in every round are marked and excluded from speedups and totals.

### Hot runs (median wall ms, min in parentheses)

| q | native | native-split | sirius | sirius-buffered | duckdb | duckdb-gpu | duckdb-gpu-pinned | native-olap | speedup native-split/sirius-buffered | sirius-buffered engine ms | notes |
|---|---|---|---|---|---|---|---|---|---|---|---|
| q01 | 1,667 (1,645) | 659 (658) | 479 (469) | 480 (480) | 231 (230) | 402 (401) | 196 (195) | 280 (279) | **1.37×** | 420 |  |
| q02 | 1,171 (1,149) | 352 (349) | 393 (390) | 393 (392) | 58 (57) | 165 (163) | 84 (82) | 96 (95) | **0.90×** | 194 |  |
| q03 | 1,927 (1,901) | 1,821 (1,769) | 486 (485) | 485 (482) | 176 (175) | 278 (276) | 91 (90) | 65 (65) | **3.75×** | 410 |  |
| q04 | 1,260 (1,230) | 425 (408) | 370 (366) | 368 (367) | 138 (130) | 201 (198) | 99 (94) | 93 (88) | **1.15×** | 314 |  |
| q05 | 1,574 (1,572) | 1,079 (1,072) | 678 (677) | 672 (670) | 180 (179) | 297 (297) | 95 (82) | 181 (180) | **1.61×** | 547 |  |
| q06 | 796 (781) | 235 (234) | 311 (309) | 292 (289) | 83 (82) | 224 (224) | 62 (61) | 30 (30) | **0.80×** | 256 |  |
| q07 | 1,488 (1,476) | 462 (459) | 717 (711) | 706 (705) | 163 (155) | 311 (310) | 79 (79) | 148 (139) | **0.65×** | 569 |  |
| q08 | 1,775 (1,761) | 585 (580) | 924 (922) | 901 (900) | 208 (206) | 484 (477) | 93 (91) | 207 (196) | **0.65×** | 723 |  |
| q09 | 1,436 (1,426) | 1,277 (1,253) | 829 (825) | 810 (804) | 392 (385) | 765 (762) | 95 (92) | 259 (251) | **1.58×** | 669 |  |
| q10 | 1,551 (1,531) | 1,061 (988) | 588 (588) | 581 (577) | 216 (213) | 470 (467) | 84 (84) | 162 (161) | **1.83×** | 486 |  |
| q11 | 674 (669) | 263 (255) | 369 (365) | 363 (363) | 134 (119) | 179 (176) | 119 (117) | 141 (136) | **0.72×** | 155 |  |
| q12 | 1,080 (1,065) | 272 (271) | 433 (425) | 424 (423) | 131 (129) | 221 (219) | 65 (65) | 74 (74) | **0.64×** | 361 |  |
| q13 | 2,434 (2,433) | 336 (329) | 220 (218) | 208 (205) | 245 (241) | 225 (224) | 16 (16) | 147 (144) | **1.62×** | 163 |  |
| q14 | 612 (605) | 284 (282) | 441 (441) | 442 (436) | 127 (127) | 443 (439) | 50 (49) | 48 (48) | **0.64×** | 381 |  |
| q15 | 758 (727) | 625 (604) | 716 (715) | 708 (706) | 126 (125) | 415 (413) | 83 (81) | 66 (66) | **0.88×** | 618 |  |
| q16 | 412 (407) | 333 (330) | 183 (183) | 183 (180) | 75 (74) | 112 (112) | 78 (74) | 108 (108) | **1.82×** | 96 |  |
| q17 | 992 (954) | 806 (798) | 689 (683) | 667 (666) | 153 (150) | 516 (511) | 106 (103) | 56 (54) | **1.21×** | 594 |  |
| q18 | 2,501 (2,461) | 2,340 (2,308) | 773 (770) | 758 (757) | 302 (300) | 373 (371) | 156 (139) | 276 (275) | **3.09×** | 656 |  |
| q19 | 942 (937) | 368 (368) | 432 (431) | 433 (430) | 162 (156) | 474 (473) | 67 (61) | 63 (62) | **0.85×** | 358 |  |
| q20 | 869 (856) | 502 (501) | 599 (595) | 589 (582) | 128 (126) | 425 (424) | 70 (69) | 114 (111) | **0.85×** | 469 |  |
| q21 | 1,905 (1,892) | 782 (772) | 1,529 (1,524) | 1,511 (1,509) | 549 (533) | 871 (871) | 200 (200) | 205 (189) | **0.52×** | 1,373 |  |
| q22 | 527 (526) | 162 (159) | 225 (225) | 227 (225) | 77 (73) | 88 (88) | 31 (31) | 74 (72) | **0.71×** | 153 |  |
| **power total** | **28,351** (22 q) | **15,029** (22 q) | **12,384** (22 q) | **12,201** (22 q) | **4,054** (22 q) | **7,939** (22 q) | **2,019** (22 q) | **2,893** (22 q) | **geomean 1.09×**, total 1.23× | 9,966 |  |

Cost-normalized (plan §7): native-split at $4.529/h vs sirius-buffered at $4.529/h → geomean speedup per dollar **1.09×**.

### Cold run (round 1, wall ms)

| q | native | native-split | sirius | sirius-buffered | duckdb | duckdb-gpu | duckdb-gpu-pinned | native-olap |
|---|---|---|---|---|---|---|---|---|
| q01 | 1,982 | 845 | 1,113 | 1,446 | 623 | 805 | 362 | 616 |
| q02 | 1,658 | 423 | 2,314 | 521 | 341 | 1,645 | 177 | 334 |
| q03 | 2,171 | 1,751 | 873 | 659 | 258 | 286 | 107 | 144 |
| q04 | 1,359 | 469 | 2,271 | 459 | 136 | 248 | 139 | 144 |
| q05 | 1,574 | 1,098 | 1,461 | 765 | 204 | 301 | 92 | 239 |
| q06 | 789 | 232 | 353 | 334 | 82 | 237 | 83 | 33 |
| q07 | 1,498 | 459 | 944 | 719 | 161 | 325 | 90 | 167 |
| q08 | 1,860 | 695 | 1,476 | 1,050 | 208 | 375 | 99 | 233 |
| q09 | 1,413 | 1,309 | 826 | 815 | 387 | 692 | 100 | 299 |
| q10 | 1,571 | 1,076 | 822 | 636 | 229 | 481 | 105 | 212 |
| q11 | 695 | 271 | 903 | 413 | 123 | 819 | 146 | 138 |
| q12 | 1,079 | 285 | 944 | 452 | 134 | 220 | 74 | 91 |
| q13 | 3,279 | 382 | 485 | 305 | 250 | 593 | 16 | 252 |
| q14 | 616 | 289 | 445 | 438 | 127 | 243 | 52 | 49 |
| q15 | 757 | 603 | 1,371 | 733 | 128 | 251 | 92 | 74 |
| q16 | 419 | 339 | 1,948 | 254 | 77 | 178 | 139 | 128 |
| q17 | 992 | 814 | 697 | 680 | 153 | 362 | 108 | 64 |
| q18 | 2,320 | 2,414 | 999 | 774 | 295 | 307 | 137 | 313 |
| q19 | 947 | 378 | 434 | 429 | 158 | 242 | 60 | 92 |
| q20 | 888 | 502 | 597 | 583 | 126 | 265 | 72 | 123 |
| q21 | 1,960 | 805 | 2,531 | 1,530 | 524 | 764 | 210 | 237 |
| q22 | 540 | 158 | 460 | 247 | 71 | 102 | 52 | 77 |
| **total** | 30,367 | 15,597 | 24,267 | 14,242 | 4,795 | 9,741 | 2,512 | 4,059 |

### FE audit (hot medians, ms): fe = FE end-to-end, plan = Nereids planning, rpc1 = first exec RPC

| q | native fe / plan / rpc1 | native-split fe / plan / rpc1 | sirius fe / plan / rpc1 | sirius-buffered fe / plan / rpc1 | native-olap fe / plan / rpc1 |
|---|---|---|---|---|---|
| q01 | 1,632 / 20 / 5 | 646 / 18 / 7 | 465 / 11 / 450 | 468 / 11 / 455 | 269 / 3 / 6 |
| q02 | 1,135 / 52 / 26 | 340 / 45 / 19 | 382 / 42 / 337 | 380 / 42 / 334 | 84 / 10 / 12 |
| q03 | 1,887 / 33 / 9 | 1,808 / 28 / 11 | 473 / 21 / 449 | 473 / 23 / 450 | 53 / 7 / 16 |
| q04 | 1,245 / 27 / 7 | 412 / 24 / 8 | 358 / 17 / 337 | 356 / 18 / 335 | 81 / 4 / 15 |
| q05 | 1,559 / 45 / 14 | 1,066 / 41 / 16 | 666 / 34 / 628 | 660 / 33 / 624 | 169 / 15 / 34 |
| q06 | 897 / 18 / 4 | 222 / 17 / 4 | 299 / 12 / 284 | 280 / 11 / 267 | 18 / 2 / 4 |
| q07 | 1,475 / 50 / 15 | 448 / 45 / 16 | 704 / 34 / 663 | 693 / 33 / 657 | 137 / 21 / 33 |
| q08 | 1,748 / 56 / 18 | 572 / 50 / 19 | 911 / 42 / 867 | 889 / 42 / 844 | 195 / 29 / 33 |
| q09 | 1,413 / 44 / 13 | 1,256 / 42 / 15 | 816 / 34 / 780 | 798 / 34 / 758 | 246 / 21 / 22 |
| q10 | 1,518 / 37 / 9 | 1,049 / 34 / 11 | 575 / 25 / 547 | 569 / 26 / 541 | 151 / 7 / 20 |
| q11 | 629 / 35 / 16 | 219 / 31 / 16 | 321 / 28 / 268 | 315 / 28 / 268 | 98 / 9 / 14 |
| q12 | 1,066 / 27 / 7 | 260 / 25 / 9 | 420 / 20 / 396 | 412 / 20 / 390 | 63 / 5 / 14 |
| q13 | 2,419 / 15 / 9 | 324 / 14 / 9 | 208 / 12 / 193 | 196 / 11 / 183 | 135 / 3 / 12 |
| q14 | 599 / 25 / 5 | 272 / 23 / 6 | 429 / 16 / 411 | 429 / 17 / 409 | 36 / 5 / 7 |
| q15 | 744 / 44 / 9 | 612 / 45 / 9 | 705 / 29 / 672 | 697 / 27 / 667 | 55 / 9 / 12 |
| q16 | 388 / 20 / 9 | 309 / 19 / 11 | 160 / 16 / 135 | 160 / 16 / 138 | 85 / 6 / 10 |
| q17 | 979 / 40 / 8 | 792 / 38 / 10 | 676 / 24 / 652 | 654 / 24 / 628 | 44 / 6 / 8 |
| q18 | 2,489 / 49 / 12 | 2,327 / 45 / 14 | 759 / 30 / 728 | 746 / 28 / 715 | 264 / 9 / 20 |
| q19 | 929 / 32 / 6 | 355 / 28 / 7 | 419 / 21 / 395 | 421 / 20 / 399 | 52 / 8 / 7 |
| q20 | 854 / 45 / 15 | 488 / 39 / 15 | 584 / 31 / 547 | 577 / 32 / 541 | 101 / 9 / 14 |
| q21 | 1,891 / 74 / 14 | 769 / 66 / 18 | 1,515 / 44 / 1,468 | 1,499 / 41 / 1,456 | 193 / 26 / 30 |
| q22 | 513 / 23 / 11 | 149 / 22 / 12 | 213 / 19 / 190 | 215 / 18 / 193 | 62 / 7 / 12 |

### Resources (hot medians): peak RSS MiB / bytes read from disk MiB / CPU cores busy / GPU MiB in use / GPU busy % / GPU memory-controller busy %

| q | native | native-split | sirius | sirius-buffered | duckdb | duckdb-gpu | duckdb-gpu-pinned | native-olap |
|---|---|---|---|---|---|---|---|---|
| q01 | 2,483 / 0 / 7.1 / - / - / - | 4,255 / 0 / 15.9 / - / - / - | 1,789 / 746 / 0.9 / 41,401 / 38 / 1 | 1,766 / 0 / 0.9 / 41,401 / 33 / 1 | 1,102 / 2,666 / 7.4 / - / - / - | 1,420 / 1,450 / 1.3 / 41,387 / 41 / 1 | 1,453 / 604 / 1.4 / 41,393 / 62 / 10 | 9,393 / 0 / 13.0 / - / - / - |
| q02 | 2,953 / 0 / 2.8 / - / - / - | 4,623 / 0 / 14.3 / - / - / - | 1,789 / 1,095 / 1.0 / 41,401 / 18 / 1 | 1,766 / 0 / 1.1 / 41,401 / 21 / 0 | 1,102 / 0 / 20.5 / - / - / - | 1,420 / 837 / 1.6 / 41,387 / 7 / 0 | 1,453 / 107 / 1.5 / 41,393 / 66 / 14 | 9,393 / 0 / 7.9 / - / - / - |
| q03 | 4,408 / 0 / 5.2 / - / - / - | 6,533 / 0 / 7.0 / - / - / - | 1,762 / 986 / 0.8 / 41,401 / 50 / 4 | 1,727 / 0 / 1.0 / 41,401 / 0 / 0 | 1,102 / 0 / 20.5 / - / - / - | 1,493 / 2,612 / 1.3 / 41,393 / 48 / 4 | 1,453 / 107 / 1.5 / 41,393 / - / - | 9,393 / 0 / 7.9 / - / - / - |
| q04 | 5,006 / 0 / 4.9 / - / - / - | 6,990 / 0 / 10.8 / - / - / - | 1,744 / 507 / 0.8 / 41,401 / 39 / 15 | 1,727 / 0 / 0.8 / 41,401 / 31 / 15 | 1,102 / 0 / 20.5 / - / - / - | 1,493 / 1,775 / 1.0 / 41,393 / - / - | 1,464 / 107 / 1.5 / 41,393 / 4 / 1 | 9,393 / 0 / 7.9 / - / - / - |
| q05 | 5,006 / 0 / 4.2 / - / - / - | 7,272 / 0 / 13.5 / - / - / - | 1,747 / 2,059 / 0.8 / 41,401 / 18 / 0 | 1,758 / 0 / 0.9 / 41,401 / 28 / 2 | 1,215 / 0 / 21.9 / - / - / - | 1,493 / 3,448 / 1.1 / 41,393 / 50 / 4 | 1,525 / 0 / 1.4 / 41,397 / 4 / 2 | 9,489 / 0 / 8.2 / - / - / - |
| q06 | 4,669 / 0 / 3.6 / - / - / - | 7,272 / 0 / 13.9 / - / - / - | 1,747 / 675 / 0.7 / 41,401 / 0 / 0 | 1,758 / 0 / 0.9 / 41,401 / - / - | 1,215 / 0 / 23.2 / - / - / - | 1,493 / 1,713 / 1.1 / 41,393 / 55 / 1 | 1,525 / 0 / 1.4 / 41,397 / 9 / 7 | 9,489 / 0 / 8.8 / - / - / - |
| q07 | 3,472 / 0 / 3.2 / - / - / - | 6,715 / 0 / 16.6 / - / - / - | 1,769 / 1,783 / 0.8 / 41,401 / 24 / 0 | 1,758 / 0 / 1.0 / 41,401 / 25 / 0 | 1,215 / 0 / 23.2 / - / - / - | 1,499 / 1,673 / 1.0 / 41,393 / 62 / 16 | 1,525 / 0 / 1.3 / 41,397 / - / - | 9,489 / 0 / 8.8 / - / - / - |
| q08 | 3,810 / 0 / 5.5 / - / - / - | 7,063 / 0 / 19.3 / - / - / - | 1,775 / 1,555 / 0.8 / 41,401 / 0 / 0 | 1,740 / 0 / 0.9 / 41,401 / 0 / 0 | 1,904 / 0 / 23.2 / - / - / - | 1,499 / 3,062 / 0.9 / 41,393 / 56 / 17 | 1,525 / 0 / 1.3 / 41,397 / - / - | 10,142 / 0 / 10.6 / - / - / - |
| q09 | 7,454 / 0 / 13.9 / - / - / - | 10,377 / 0 / 20.9 / - / - / - | 1,788 / 1,471 / 0.9 / 41,401 / 14 / 1 | 1,778 / 0 / 1.0 / 41,401 / 28 / 2 | 1,904 / 0 / 24.5 / - / - / - | 1,554 / 3,783 / 0.6 / 41,393 / 14 / 4 | 1,525 / 0 / 1.3 / 41,397 / - / - | 10,142 / 0 / 12.8 / - / - / - |
| q10 | 7,765 / 0 / 5.8 / - / - / - | 10,377 / 0 / 9.4 / - / - / - | 1,788 / 2,214 / 0.8 / 41,401 / 0 / 0 | 1,778 / 0 / 1.0 / 41,401 / 0 / 0 | 1,904 / 0 / 22.5 / - / - / - | 1,585 / 2,176 / 1.0 / 41,397 / 39 / 14 | 1,534 / 0 / 1.3 / 41,397 / 25 / 17 | 10,145 / 0 / 12.8 / - / - / - |
| q11 | 7,649 / 0 / 4.0 / - / - / - | 10,054 / 0 / 8.1 / - / - / - | 1,786 / 1,158 / 0.8 / 41,401 / 0 / 0 | 1,767 / 0 / 0.9 / 41,401 / 5 / 0 | 1,904 / 0 / 19.9 / - / - / - | 1,585 / 1,119 / 1.2 / 41,397 / 13 / 2 | 1,623 / 0 / 1.3 / 41,401 / 13 / 9 | 10,145 / 0 / 8.5 / - / - / - |
| q12 | 6,728 / 0 / 3.2 / - / - / - | 9,905 / 0 / 14.3 / - / - / - | 1,790 / 1,249 / 0.8 / 41,401 / 0 / 0 | 1,767 / 0 / 0.9 / 41,401 / 20 / 0 | 1,904 / 0 / 19.9 / - / - / - | 1,585 / 1,119 / 1.2 / 41,397 / - / - | 1,623 / 0 / 1.2 / 41,401 / 8 / 4 | 10,145 / 0 / 8.5 / - / - / - |
| q13 | 4,963 / 0 / 2.4 / - / - / - | 9,328 / 0 / 17.8 / - / - / - | 1,790 / 1,014 / 0.7 / 41,401 / 15 / 0 | 1,767 / 0 / 0.8 / 41,401 / 33 / 13 | 1,904 / 0 / 19.9 / - / - / - | 1,585 / 2,123 / 0.9 / 41,397 / 42 / 13 | 1,623 / 0 / 1.2 / 41,401 / - / - | 10,145 / 0 / 8.5 / - / - / - |
| q14 | 2,549 / 0 / 5.0 / - / - / - | 8,215 / 0 / 19.6 / - / - / - | 1,790 / 1,889 / 0.8 / 41,401 / 26 / 18 | 1,767 / 0 / 0.9 / 41,401 / 0 / 0 | 1,904 / 0 / 20.4 / - / - / - | 1,610 / 1,004 / 0.5 / 41,401 / 40 / 1 | 1,623 / 0 / 1.2 / 41,401 / - / - | 10,545 / 0 / 8.7 / - / - / - |
| q15 | 2,549 / 0 / 7.3 / - / - / - | 8,206 / 0 / 13.1 / - / - / - | 1,793 / 1,653 / 0.9 / 41,401 / 0 / 0 | 1,758 / 0 / 1.0 / 41,401 / 0 / 0 | 1,843 / 0 / 21.4 / - / - / - | 1,610 / 1,866 / 0.7 / 41,401 / 16 / 0 | 1,623 / 0 / 1.2 / 41,401 / - / - | 10,549 / 0 / 10.7 / - / - / - |
| q16 | 2,824 / 0 / 3.6 / - / - / - | 6,729 / 0 / 3.6 / - / - / - | 1,793 / 131 / 0.8 / 41,401 / 58 / 10 | 1,758 / 0 / 0.9 / 41,401 / 27 / 9 | 1,843 / 0 / 21.4 / - / - / - | 1,610 / 862 / 0.8 / 41,401 / - / - | 1,623 / 0 / 1.2 / 41,401 / - / - | 10,549 / 0 / 10.7 / - / - / - |
| q17 | 3,494 / 0 / 15.6 / - / - / - | 7,020 / 0 / 23.1 / - / - / - | 1,794 / 1,268 / 0.8 / 41,401 / 0 / 0 | 1,770 / 0 / 0.9 / 41,401 / 0 / 0 | 1,843 / 0 / 21.4 / - / - / - | 1,644 / 2,046 / 0.8 / 41,401 / 16 / 1 | 1,627 / 0 / 1.2 / 41,401 / - / - | 10,549 / 0 / 10.7 / - / - / - |
| q18 | 8,320 / 0 / 7.5 / - / - / - | 10,558 / 0 / 10.0 / - / - / - | 1,808 / 2,719 / 0.9 / 41,401 / 12 / 1 | 1,770 / 0 / 1.1 / 41,401 / 0 / 0 | 1,843 / 0 / 22.3 / - / - / - | 1,644 / 2,489 / 1.0 / 41,401 / 16 / 5 | 1,627 / 0 / 1.4 / 41,401 / 6 / 5 | 10,957 / 0 / 10.8 / - / - / - |
| q19 | 8,320 / 0 / 4.3 / - / - / - | 10,558 / 0 / 12.4 / - / - / - | 1,808 / 1,601 / 0.9 / 41,401 / 30 / 1 | 1,747 / 0 / 1.0 / 41,401 / 38 / 1 | 1,541 / 0 / 23.3 / - / - / - | 1,668 / 2,398 / 0.9 / 41,401 / 16 / 0 | 1,627 / 0 / 1.5 / 41,401 / 34 / 27 | 10,957 / 0 / 9.4 / - / - / - |
| q20 | 7,325 / 0 / 5.8 / - / - / - | 10,216 / 0 / 17.2 / - / - / - | 1,808 / 910 / 0.9 / 41,401 / 2 / 0 | 1,747 / 0 / 1.0 / 41,401 / 41 / 9 | 1,541 / 0 / 23.3 / - / - / - | 1,765 / 2,184 / 1.1 / 41,401 / 16 / 0 | 1,627 / 0 / 1.5 / 41,401 / - / - | 10,957 / 0 / 9.4 / - / - / - |
| q21 | 6,415 / 0 / 6.4 / - / - / - | 9,179 / 0 / 19.4 / - / - / - | 1,858 / 2,569 / 0.8 / 41,401 / 18 / 2 | 1,834 / 0 / 1.0 / 41,401 / 0 / 0 | 1,541 / 0 / 22.3 / - / - / - | 1,765 / 1,882 / 0.8 / 41,401 / 20 / 1 | 1,627 / 0 / 1.5 / 41,401 / - / - | 10,957 / 0 / 6.4 / - / - / - |
| q22 | 3,999 / 0 / 2.7 / - / - / - | 8,222 / 0 / 3.3 / - / - / - | 1,858 / 152 / 0.6 / 41,401 / 14 / 0 | 1,834 / 0 / 0.8 / 41,401 / 35 / 18 | 1,502 / 4 / 14.2 / - / - / - | 1,765 / 790 / 0.7 / 41,401 / - / - | 1,627 / 0 / 1.5 / 41,401 / - / - | 10,957 / 0 / 1.5 / - / - / - |

Bytes read from disk = `/proc/<pid>/io read_bytes` delta over the query (0 on a page-cache hit; O_DIRECT reads always count); sampled every 0.5 s, so sub-second queries are attributed approximately. GPU MiB in use is the RMM pool (reserved up front, not a peak); GPU busy % = nvidia-smi `utilization.gpu` (share of time a kernel was running) and memory-controller busy % = `utilization.memory`, both averaged over the query's samples; `-` when the query was shorter than one sample.

### Environment

#### native (`log/bench-t1/sf10-native`)

```
date: 2026-09-19T10:28:03Z
host: ip-172-31-26-244
instance_type: g6e.8xlarge
kernel: 7.0.0-1012-aws
cpu: AMD EPYC 7R13 Processor x 32
mem_total_kib: 260437876
gpu: NVIDIA L40S, 46068 MiB, 580.178.04
system: native
data: /mnt/nvme/tpch_parquet_sf10 (3.6G) on /dev/md0       ext4
expected: /home/yy2/gpu/sirius/experimental/doris/tests/expected/tpch-sf10
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f5116c6c docs(doris): T0 results with GPU utilization, SF100 purchase list
sirius_dirty: 1 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb (v1.5.5 (Variegata) 3ff87f1e)
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	true	doris-4.1.4-rc04-ad35a140c7f
-- session variables (GLOBAL) --
parallel_pipeline_task_num	0
experimental_enable_local_shuffle	true
enable_parallel_result_sink	true
runtime_filter_mode	GLOBAL
enable_cte_materialize	true
experimental_topn_lazy_materialization_threshold	1024
file_split_size	0
max_file_split_size	67108864
max_initial_file_split_size	33554432
file_split_size_on_be	67108864
file_split_size_on_fe	536870912
max_file_scanners_concurrency	16
enable_file_scanner_v2	true
enable_fold_constant_by_be	false
enable_profile	false
query_timeout	3600
```

#### native-split (`log/bench-t1/sf10-native-split`)

```
date: 2026-09-19T10:30:52Z
host: ip-172-31-26-244
instance_type: g6e.8xlarge
kernel: 7.0.0-1012-aws
cpu: AMD EPYC 7R13 Processor x 32
mem_total_kib: 260437876
gpu: NVIDIA L40S, 46068 MiB, 580.178.04
system: native-split
data: /mnt/nvme/tpch_parquet_sf10 (3.6G) on /dev/md0       ext4
expected: /home/yy2/gpu/sirius/experimental/doris/tests/expected/tpch-sf10
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f5116c6c docs(doris): T0 results with GPU utilization, SF100 purchase list
sirius_dirty: 2 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb (v1.5.5 (Variegata) 3ff87f1e)
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	true	doris-4.1.4-rc04-ad35a140c7f
-- session variables (GLOBAL) --
parallel_pipeline_task_num	0
experimental_enable_local_shuffle	true
enable_parallel_result_sink	true
runtime_filter_mode	GLOBAL
enable_cte_materialize	true
experimental_topn_lazy_materialization_threshold	1024
file_split_size	0
max_file_split_size	67108864
max_initial_file_split_size	33554432
file_split_size_on_be	0
file_split_size_on_fe	536870912
max_file_scanners_concurrency	16
enable_file_scanner_v2	true
enable_fold_constant_by_be	false
enable_profile	false
query_timeout	3600
```

#### sirius (`log/bench-t1/sf10-sirius`)

```
date: 2026-09-19T10:32:52Z
host: ip-172-31-26-244
instance_type: g6e.8xlarge
kernel: 7.0.0-1012-aws
cpu: AMD EPYC 7R13 Processor x 32
mem_total_kib: 260437876
gpu: NVIDIA L40S, 46068 MiB, 580.178.04
system: sirius
data: /mnt/nvme/tpch_parquet_sf10 (3.6G) on /dev/md0       ext4
expected: /home/yy2/gpu/sirius/experimental/doris/tests/expected/tpch-sf10
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f5116c6c docs(doris): T0 results with GPU utilization, SF100 purchase list
sirius_dirty: 2 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb ()
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
  c219596990ecc564adfa23a4d68c78e56c827dbc206c7a06f499740b065b7ba5  log/bench-t1/sf10-sirius/sirius.yaml
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	false	doris-4.1.4-rc04-ad35a140c7f
  127.0.0.1	9050	true	sirius-doris-be/0.1.0
-- session variables (GLOBAL) --
parallel_pipeline_task_num	1
experimental_enable_local_shuffle	false
enable_parallel_result_sink	false
runtime_filter_mode	OFF
enable_cte_materialize	false
experimental_topn_lazy_materialization_threshold	-1
file_split_size	1099511627776
max_file_split_size	67108864
max_initial_file_split_size	33554432
file_split_size_on_be	0
file_split_size_on_fe	1099511627776
max_file_scanners_concurrency	16
enable_file_scanner_v2	true
enable_fold_constant_by_be	false
enable_profile	false
query_timeout	3600
```

#### sirius-buffered (`log/bench-t1/sf10-sirius-buffered`)

```
date: 2026-09-19T10:34:36Z
host: ip-172-31-26-244
instance_type: g6e.8xlarge
kernel: 7.0.0-1012-aws
cpu: AMD EPYC 7R13 Processor x 32
mem_total_kib: 260437876
gpu: NVIDIA L40S, 46068 MiB, 580.178.04
system: sirius-buffered
data: /mnt/nvme/tpch_parquet_sf10 (3.6G) on /dev/md0       ext4
expected: /home/yy2/gpu/sirius/experimental/doris/tests/expected/tpch-sf10
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f5116c6c docs(doris): T0 results with GPU utilization, SF100 purchase list
sirius_dirty: 2 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb ()
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
  f2658eddd10ea8e7a8e60356134d3e0303e971a4261d2a239ea7adb4b08b3ae8  log/bench-t1/sf10-sirius-buffered/sirius.yaml
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	false	doris-4.1.4-rc04-ad35a140c7f
  127.0.0.1	9050	true	sirius-doris-be/0.1.0
-- session variables (GLOBAL) --
parallel_pipeline_task_num	1
experimental_enable_local_shuffle	false
enable_parallel_result_sink	false
runtime_filter_mode	OFF
enable_cte_materialize	false
experimental_topn_lazy_materialization_threshold	-1
file_split_size	1099511627776
max_file_split_size	67108864
max_initial_file_split_size	33554432
file_split_size_on_be	0
file_split_size_on_fe	1099511627776
max_file_scanners_concurrency	16
enable_file_scanner_v2	true
enable_fold_constant_by_be	false
enable_profile	false
query_timeout	3600
```

#### duckdb (`log/bench-t1/sf10-duckdb`)

```
date: 2026-09-19T10:36:01Z
host: ip-172-31-26-244
instance_type: g6e.8xlarge
kernel: 7.0.0-1012-aws
cpu: AMD EPYC 7R13 Processor x 32
mem_total_kib: 260437876
gpu: NVIDIA L40S, 46068 MiB, 580.178.04
system: duckdb
data: /mnt/nvme/tpch_parquet_sf10 (3.6G) on /dev/md0       ext4
expected: /home/yy2/gpu/sirius/experimental/doris/tests/expected/tpch-sf10
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f5116c6c docs(doris): T0 results with GPU utilization, SF100 purchase list
sirius_dirty: 2 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb (v1.5.5 (Variegata) 3ff87f1e)
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	false	doris-4.1.4-rc04-ad35a140c7f
  127.0.0.1	9050	false	sirius-doris-be/0.1.0
```

#### duckdb-gpu (`log/bench-t1/sf10-duckdb-gpu`)

```
date: 2026-09-19T10:36:41Z
host: ip-172-31-26-244
instance_type: g6e.8xlarge
kernel: 7.0.0-1012-aws
cpu: AMD EPYC 7R13 Processor x 32
mem_total_kib: 260437876
gpu: NVIDIA L40S, 46068 MiB, 580.178.04
system: duckdb-gpu
data: /mnt/nvme/tpch_parquet_sf10 (3.6G) on /dev/md0       ext4
expected: /home/yy2/gpu/sirius/experimental/doris/tests/expected/tpch-sf10
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f5116c6c docs(doris): T0 results with GPU utilization, SF100 purchase list
sirius_dirty: 2 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb (v1.5.5 (Variegata) 3ff87f1e)
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
  5a989055ffe4d744b9d89200561675b9bcb2c1b4cd8070a32d6d6d0d709d9106  log/bench-t1/sf10-duckdb-gpu/sirius.yaml
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	false	doris-4.1.4-rc04-ad35a140c7f
  127.0.0.1	9050	false	sirius-doris-be/0.1.0
```

#### duckdb-gpu-pinned (`log/bench-t1/sf10-duckdb-gpu-pinned`)

```
date: 2026-09-19T10:37:43Z
host: ip-172-31-26-244
instance_type: g6e.8xlarge
kernel: 7.0.0-1012-aws
cpu: AMD EPYC 7R13 Processor x 32
mem_total_kib: 260437876
gpu: NVIDIA L40S, 46068 MiB, 580.178.04
system: duckdb-gpu-pinned
data: /mnt/nvme/tpch_parquet_sf10 (3.6G) on /dev/md0       ext4
expected: /home/yy2/gpu/sirius/experimental/doris/tests/expected/tpch-sf10
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f5116c6c docs(doris): T0 results with GPU utilization, SF100 purchase list
sirius_dirty: 2 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb (v1.5.5 (Variegata) 3ff87f1e)
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
  d693f499281e5a6d4d4c0cbdb9e2273254ea5abd20706589062be187ded97277  log/bench-t1/sf10-duckdb-gpu-pinned/sirius.yaml
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	false	doris-4.1.4-rc04-ad35a140c7f
  127.0.0.1	9050	false	sirius-doris-be/0.1.0
```

#### native-olap (`log/bench-t1/sf10-native-olap`)

```
date: 2026-09-19T10:38:33Z
host: ip-172-31-26-244
instance_type: g6e.8xlarge
kernel: 7.0.0-1012-aws
cpu: AMD EPYC 7R13 Processor x 32
mem_total_kib: 260437876
gpu: NVIDIA L40S, 46068 MiB, 580.178.04
system: native-olap
data: /mnt/nvme/tpch_parquet_sf10 (3.6G) on /dev/md0       ext4
expected: /home/yy2/gpu/sirius/experimental/doris/tests/expected/tpch-sf10
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f5116c6c docs(doris): T0 results with GPU utilization, SF100 purchase list
sirius_dirty: 2 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb (v1.5.5 (Variegata) 3ff87f1e)
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	true	doris-4.1.4-rc04-ad35a140c7f
-- session variables (GLOBAL) --
parallel_pipeline_task_num	0
experimental_enable_local_shuffle	true
enable_parallel_result_sink	true
runtime_filter_mode	GLOBAL
enable_cte_materialize	true
experimental_topn_lazy_materialization_threshold	1024
file_split_size	0
max_file_split_size	67108864
max_initial_file_split_size	33554432
file_split_size_on_be	67108864
file_split_size_on_fe	536870912
max_file_scanners_concurrency	16
enable_file_scanner_v2	true
enable_fold_constant_by_be	false
enable_profile	false
query_timeout	3600
```

## SF1 · g6e.8xlarge (L40S, 32 vCPU) · 2026-09-19 — auto-generated

Systems: `native` (4 round(s)), `native-split` (4 round(s)), `sirius` (4 round(s)), `sirius-buffered` (4 round(s)), `duckdb` (4 round(s)), `duckdb-gpu` (4 round(s)), `duckdb-gpu-pinned` (4 round(s)), `native-olap` (4 round(s)). Round 1 is cold (freshly started process, page cache evicted), the others hot; **hot** = median of the hot rounds, (min) in parentheses; ms of client round trip (`wall_ms`). Queries that did not validate against the DuckDB baseline in every round are marked and excluded from speedups and totals.

### Hot runs (median wall ms, min in parentheses)

| q | native | native-split | sirius | sirius-buffered | duckdb | duckdb-gpu | duckdb-gpu-pinned | native-olap | speedup native-split/sirius-buffered | sirius-buffered engine ms | notes |
|---|---|---|---|---|---|---|---|---|---|---|---|
| q01 | 685 (681) | 306 (304) | 92 (91) | 98 (97) | 64 (63) | 130 (128) | 69 (69) | 62 (61) | **3.12×** | 43 |  |
| q02 | 228 (223) | 226 (223) | 277 (277) | 279 (278) | 33 (33) | 104 (101) | 71 (69) | 48 (48) | **0.81×** | 87 |  |
| q03 | 499 (478) | 304 (300) | 110 (107) | 113 (112) | 42 (41) | 33 (33) | 19 (19) | 149 (148) | **2.69×** | 46 |  |
| q04 | 353 (346) | 187 (185) | 74 (71) | 75 (74) | 41 (35) | 58 (58) | 43 (41) | 66 (63) | **2.49×** | 31 |  |
| q05 | 512 (498) | 308 (302) | 174 (174) | 181 (180) | 42 (40) | 51 (50) | 29 (27) | 191 (190) | **1.70×** | 69 |  |
| q06 | 187 (185) | 85 (85) | 51 (47) | 53 (52) | 15 (14) | 25 (25) | 16 (16) | 22 (22) | **1.60×** | 23 |  |
| q07 | 378 (376) | 228 (226) | 200 (194) | 204 (200) | 42 (42) | 53 (52) | 26 (25) | 100 (98) | **1.12×** | 75 |  |
| q08 | 495 (478) | 314 (304) | 256 (255) | 263 (263) | 43 (42) | 65 (65) | 31 (29) | 133 (133) | **1.19×** | 93 |  |
| q09 | 437 (414) | 226 (224) | 208 (204) | 215 (212) | 123 (109) | 65 (64) | 29 (28) | 128 (125) | **1.05×** | 84 |  |
| q10 | 466 (463) | 301 (296) | 152 (149) | 156 (155) | 77 (77) | 56 (56) | 26 (26) | 77 (76) | **1.93×** | 68 |  |
| q11 | 143 (141) | 136 (131) | 193 (192) | 203 (199) | 33 (32) | 53 (53) | 38 (38) | 58 (55) | **0.67×** | 66 |  |
| q12 | 341 (326) | 203 (199) | 85 (85) | 91 (91) | 34 (33) | 25 (24) | 9 (9) | 66 (57) | **2.23×** | 38 |  |
| q13 | 708 (687) | 698 (693) | 71 (70) | 76 (74) | 141 (136) | 30 (30) | 6 (6) | 46 (46) | **9.18×** | 34 |  |
| q14 | 164 (161) | 91 (90) | 80 (80) | 89 (88) | 28 (28) | 21 (21) | 8 (8) | 32 (32) | **1.02×** | 37 |  |
| q15 | 196 (192) | 113 (105) | 121 (120) | 125 (124) | 24 (23) | 37 (37) | 24 (22) | 54 (54) | **0.90×** | 46 |  |
| q16 | 286 (285) | 285 (282) | 117 (114) | 117 (117) | 52 (48) | 80 (78) | 68 (66) | 87 (84) | **2.44×** | 41 |  |
| q17 | 217 (213) | 122 (121) | 107 (105) | 116 (113) | 22 (21) | 34 (34) | 13 (13) | 32 (32) | **1.05×** | 51 |  |
| q18 | 249 (238) | 236 (219) | 150 (146) | 150 (150) | 81 (80) | 38 (38) | 17 (16) | 72 (67) | **1.57×** | 57 |  |
| q19 | 293 (271) | 144 (139) | 110 (109) | 113 (111) | 54 (47) | 30 (29) | 11 (11) | 35 (34) | **1.27×** | 44 |  |
| q20 | 308 (302) | 196 (193) | 170 (167) | 174 (172) | 42 (42) | 45 (44) | 18 (18) | 54 (53) | **1.13×** | 64 |  |
| q21 | 785 (784) | 402 (394) | 221 (221) | 228 (226) | 138 (126) | 68 (68) | 30 (30) | 155 (148) | **1.76×** | 99 |  |
| q22 | 102 (102) | 98 (97) | 110 (109) | 111 (111) | 38 (38) | 35 (34) | 19 (19) | 92 (87) | **0.88×** | 42 |  |
| **power total** | **8,032** (22 q) | **5,209** (22 q) | **3,129** (22 q) | **3,230** (22 q) | **1,209** (22 q) | **1,136** (22 q) | **620** (22 q) | **1,759** (22 q) | **geomean 1.54×**, total 1.61× | 1,239 |  |

Cost-normalized (plan §7): native-split at $4.529/h vs sirius-buffered at $4.529/h → geomean speedup per dollar **1.54×**.

### Cold run (round 1, wall ms)

| q | native | native-split | sirius | sirius-buffered | duckdb | duckdb-gpu | duckdb-gpu-pinned | native-olap |
|---|---|---|---|---|---|---|---|---|
| q01 | 842 | 470 | 713 | 717 | 123 | 482 | 199 | 252 |
| q02 | 397 | 263 | 373 | 368 | 52 | 223 | 163 | 122 |
| q03 | 502 | 326 | 110 | 119 | 60 | 38 | 33 | 165 |
| q04 | 378 | 201 | 163 | 165 | 44 | 123 | 89 | 75 |
| q05 | 529 | 317 | 196 | 205 | 51 | 66 | 37 | 195 |
| q06 | 189 | 93 | 82 | 84 | 20 | 45 | 36 | 24 |
| q07 | 409 | 235 | 215 | 220 | 44 | 67 | 35 | 108 |
| q08 | 488 | 318 | 303 | 308 | 56 | 84 | 39 | 142 |
| q09 | 441 | 233 | 224 | 226 | 113 | 75 | 36 | 114 |
| q10 | 490 | 303 | 173 | 179 | 93 | 73 | 38 | 85 |
| q11 | 146 | 140 | 213 | 216 | 38 | 90 | 64 | 58 |
| q12 | 330 | 199 | 122 | 124 | 47 | 26 | 11 | 66 |
| q13 | 763 | 757 | 88 | 96 | 146 | 47 | 6 | 92 |
| q14 | 160 | 93 | 84 | 86 | 35 | 22 | 8 | 34 |
| q15 | 208 | 108 | 144 | 146 | 24 | 52 | 38 | 55 |
| q16 | 289 | 288 | 196 | 197 | 46 | 160 | 145 | 100 |
| q17 | 234 | 127 | 109 | 115 | 31 | 36 | 15 | 38 |
| q18 | 234 | 268 | 157 | 162 | 77 | 39 | 16 | 91 |
| q19 | 278 | 143 | 110 | 114 | 52 | 28 | 12 | 38 |
| q20 | 305 | 200 | 167 | 172 | 51 | 46 | 19 | 60 |
| q21 | 794 | 407 | 259 | 261 | 136 | 79 | 42 | 166 |
| q22 | 101 | 101 | 132 | 130 | 40 | 51 | 38 | 102 |
| **total** | 8,507 | 5,590 | 4,333 | 4,410 | 1,379 | 1,952 | 1,119 | 2,182 |

### FE audit (hot medians, ms): fe = FE end-to-end, plan = Nereids planning, rpc1 = first exec RPC

| q | native fe / plan / rpc1 | native-split fe / plan / rpc1 | sirius fe / plan / rpc1 | sirius-buffered fe / plan / rpc1 | native-olap fe / plan / rpc1 |
|---|---|---|---|---|---|
| q01 | 673 / 7 / 6 | 293 / 6 / 6 | 81 / 7 / 72 | 85 / 7 / 77 | 50 / 2 / 7 |
| q02 | 216 / 38 / 27 | 213 / 39 / 27 | 265 / 38 / 226 | 267 / 38 / 226 | 37 / 8 / 12 |
| q03 | 488 / 15 / 10 | 292 / 14 / 13 | 98 / 13 / 82 | 102 / 13 / 86 | 137 / 5 / 16 |
| q04 | 342 / 10 / 7 | 175 / 11 / 7 | 62 / 10 / 50 | 64 / 10 / 52 | 54 / 3 / 17 |
| q05 | 499 / 24 / 17 | 295 / 25 / 16 | 163 / 25 / 136 | 169 / 25 / 143 | 179 / 12 / 28 |
| q06 | 175 / 6 / 3 | 73 / 7 / 3 | 39 / 6 / 30 | 41 / 6 / 34 | 10 / 2 / 4 |
| q07 | 365 / 26 / 18 | 215 / 26 / 18 | 187 / 26 / 157 | 191 / 27 / 163 | 88 / 18 / 21 |
| q08 | 466 / 33 / 17 | 302 / 34 / 19 | 244 / 32 / 209 | 251 / 33 / 216 | 121 / 25 / 33 |
| q09 | 443 / 26 / 14 | 215 / 26 / 13 | 196 / 26 / 168 | 202 / 25 / 175 | 116 / 19 / 20 |
| q10 | 452 / 19 / 9 | 289 / 18 / 9 | 140 / 18 / 120 | 144 / 18 / 125 | 64 / 6 / 15 |
| q11 | 122 / 26 / 16 | 113 / 26 / 18 | 175 / 25 / 146 | 183 / 26 / 150 | 40 / 7 / 13 |
| q12 | 373 / 11 / 7 | 187 / 11 / 8 | 74 / 11 / 61 | 79 / 11 / 66 | 54 / 4 / 15 |
| q13 | 676 / 9 / 8 | 686 / 10 / 9 | 59 / 9 / 49 | 64 / 9 / 53 | 35 / 3 / 10 |
| q14 | 152 / 10 / 5 | 79 / 11 / 6 | 69 / 10 / 58 | 76 / 10 / 64 | 22 / 4 / 7 |
| q15 | 184 / 17 / 9 | 101 / 17 / 9 | 108 / 17 / 89 | 113 / 16 / 94 | 42 / 7 / 12 |
| q16 | 267 / 15 / 9 | 265 / 14 / 9 | 97 / 15 / 78 | 98 / 15 / 80 | 67 / 4 / 10 |
| q17 | 205 / 16 / 9 | 109 / 16 / 8 | 95 / 14 / 79 | 104 / 16 / 86 | 22 / 5 / 8 |
| q18 | 237 / 20 / 11 | 224 / 20 / 11 | 137 / 19 / 116 | 138 / 19 / 117 | 61 / 7 / 20 |
| q19 | 274 / 13 / 6 | 132 / 14 / 6 | 98 / 14 / 82 | 100 / 13 / 84 | 23 / 7 / 6 |
| q20 | 297 / 24 / 15 | 183 / 23 / 16 | 158 / 23 / 132 | 161 / 22 / 136 | 42 / 7 / 14 |
| q21 | 773 / 30 / 14 | 390 / 31 / 14 | 209 / 29 / 177 | 215 / 31 / 182 | 143 / 23 / 27 |
| q22 | 90 / 16 / 11 | 87 / 17 / 11 | 99 / 16 / 80 | 99 / 16 / 81 | 80 / 6 / 12 |

### Resources (hot medians): peak RSS MiB / bytes read from disk MiB / CPU cores busy / GPU MiB in use / GPU busy % / GPU memory-controller busy %

| q | native | native-split | sirius | sirius-buffered | duckdb | duckdb-gpu | duckdb-gpu-pinned | native-olap |
|---|---|---|---|---|---|---|---|---|
| q01 | 1,846 / 0 / 2.2 / - / - / - | 2,076 / 0 / 3.4 / - / - / - | 1,555 / 39 / 0.5 / 41,399 / 2 / 1 | 1,556 / 0 / 0.6 / 41,399 / 4 / 1 | 374 / 157 / 2.1 / - / - / - | 1,334 / 47 / 1.2 / 41,385 / 2 / 1 | 1,329 / 143 / 1.1 / 41,385 / - / - | 3,231 / 0 / 6.1 / - / - / - |
| q02 | 2,065 / 0 / 2.1 / - / - / - | 2,439 / 0 / 3.0 / - / - / - | 1,555 / 145 / 0.6 / 41,399 / 1 / 0 | 1,556 / 0 / 0.6 / 41,399 / 0 / 0 | 615 / 104 / 3.7 / - / - / - | 1,478 / 47 / 1.2 / 41,397 / - / - | 1,551 / 143 / 1.2 / 41,401 / 28 / 3 | 3,231 / 0 / 6.1 / - / - / - |
| q03 | 2,467 / 0 / 1.8 / - / - / - | 2,932 / 0 / 3.0 / - / - / - | 1,555 / 106 / 0.6 / 41,399 / - / - | 1,556 / 0 / 0.6 / 41,399 / - / - | 615 / 104 / 3.7 / - / - / - | 1,478 / 489 / 1.2 / 41,397 / 21 / 0 | 1,551 / 0 / 1.3 / 41,401 / - / - | 3,752 / 0 / 6.1 / - / - / - |
| q04 | 2,467 / 0 / 1.9 / - / - / - | 2,932 / 0 / 3.1 / - / - / - | 1,555 / 106 / 0.6 / 41,399 / - / - | 1,556 / 0 / 0.6 / 41,399 / - / - | 615 / 0 / 3.7 / - / - / - | 1,478 / 442 / 1.2 / 41,397 / - / - | 1,551 / 0 / 1.3 / 41,401 / 3 / 0 | 3,752 / 0 / 5.7 / - / - / - |
| q05 | 2,546 / 0 / 1.8 / - / - / - | 2,967 / 0 / 2.8 / - / - / - | 1,555 / 106 / 0.6 / 41,399 / 0 / 0 | 1,556 / 0 / 0.6 / 41,399 / 0 / 0 | 615 / 0 / 3.6 / - / - / - | 1,478 / 442 / 1.2 / 41,397 / 10 / 1 | 1,551 / 0 / 1.3 / 41,401 / - / - | 3,752 / 0 / 5.4 / - / - / - |
| q06 | 2,584 / 0 / 1.6 / - / - / - | 2,967 / 0 / 2.6 / - / - / - | 1,555 / 79 / 0.6 / 41,399 / 0 / 0 | 1,556 / 0 / 0.6 / 41,399 / 2 / 0 | 615 / 0 / 3.6 / - / - / - | 1,478 / 442 / 1.2 / 41,397 / - / - | 1,551 / 0 / 1.3 / 41,401 / - / - | 3,752 / 0 / 5.4 / - / - / - |
| q07 | 2,584 / 0 / 1.6 / - / - / - | 2,987 / 0 / 2.6 / - / - / - | 1,554 / 79 / 0.6 / 41,399 / - / - | 1,555 / 0 / 0.6 / 41,399 / - / - | 615 / 0 / 3.6 / - / - / - | 1,478 / 442 / 1.2 / 41,397 / - / - | 1,551 / 0 / 1.3 / 41,401 / - / - | 3,956 / 0 / 5.4 / - / - / - |
| q08 | 3,062 / 0 / 2.8 / - / - / - | 3,260 / 0 / 5.0 / - / - / - | 1,554 / 231 / 0.7 / 41,399 / 0 / 0 | 1,556 / 0 / 0.7 / 41,399 / 0 / 0 | 615 / 0 / 3.6 / - / - / - | 1,478 / 442 / 1.2 / 41,397 / - / - | 1,551 / 0 / 1.3 / 41,401 / - / - | 3,956 / 0 / 6.7 / - / - / - |
| q09 | 3,062 / 1 / 4.2 / - / - / - | 3,274 / 0 / 3.8 / - / - / - | 1,554 / 152 / 0.7 / 41,399 / 18 / 1 | 1,556 / 0 / 0.8 / 41,399 / 0 / 0 | 615 / 0 / 3.6 / - / - / - | 1,478 / 442 / 1.2 / 41,397 / - / - | 1,551 / 0 / 1.3 / 41,401 / - / - | 3,956 / 0 / 6.7 / - / - / - |
| q10 | 3,125 / 1 / 2.1 / - / - / - | 3,274 / 0 / 2.6 / - / - / - | 1,555 / 152 / 0.7 / 41,399 / 3 / 0 | 1,556 / 0 / 0.7 / 41,399 / 8 / 0 | 615 / 0 / 3.6 / - / - / - | 1,478 / 442 / 1.2 / 41,397 / - / - | 1,551 / 0 / 1.3 / 41,401 / - / - | 3,956 / 0 / 6.7 / - / - / - |
| q11 | 3,125 / 0 / 2.4 / - / - / - | 3,347 / 0 / 2.4 / - / - / - | 1,554 / 70 / 0.5 / 41,399 / - / - | 1,556 / 0 / 0.6 / 41,399 / 14 / 0 | 615 / 0 / 3.6 / - / - / - | 1,478 / 442 / 1.2 / 41,397 / - / - | 1,551 / 0 / 1.3 / 41,401 / - / - | 3,956 / 0 / 6.7 / - / - / - |
| q12 | 3,125 / 0 / 2.4 / - / - / - | 3,347 / 0 / 2.2 / - / - / - | 1,554 / 70 / 0.5 / 41,399 / - / - | 1,556 / 0 / 0.6 / 41,399 / - / - | 615 / 0 / 3.6 / - / - / - | 1,478 / 442 / 1.2 / 41,397 / - / - | 1,551 / 0 / 1.3 / 41,401 / - / - | 3,956 / 0 / 3.4 / - / - / - |
| q13 | 3,125 / 0 / 2.1 / - / - / - | 3,347 / 0 / 1.8 / - / - / - | 1,554 / 70 / 0.5 / 41,399 / - / - | 1,557 / 0 / 0.6 / 41,399 / 6 / 1 | 710 / 0 / 3.9 / - / - / - | 1,479 / 442 / 1.2 / 41,397 / - / - | 1,551 / 0 / 1.3 / 41,401 / - / - | 3,956 / 0 / 3.4 / - / - / - |
| q14 | 2,965 / 0 / 2.4 / - / - / - | 3,347 / 0 / 3.1 / - / - / - | 1,554 / 210 / 0.5 / 41,399 / 6 / 0 | 1,554 / 0 / 0.6 / 41,399 / - / - | 710 / 0 / 4.1 / - / - / - | 1,517 / 442 / 1.2 / 41,397 / 8 / 1 | 1,551 / 0 / 1.3 / 41,401 / - / - | 3,956 / 0 / 3.4 / - / - / - |
| q15 | 2,965 / 0 / 2.3 / - / - / - | 3,185 / 0 / 3.4 / - / - / - | 1,554 / 140 / 0.6 / 41,399 / 0 / 0 | 1,554 / 0 / 0.6 / 41,399 / 6 / 0 | 710 / 0 / 4.1 / - / - / - | 1,517 / 730 / 1.2 / 41,397 / 22 / 1 | 1,551 / 0 / 1.3 / 41,401 / - / - | 3,956 / 0 / 3.4 / - / - / - |
| q16 | 3,065 / 0 / 2.1 / - / - / - | 3,360 / 0 / 4.2 / - / - / - | 1,554 / 140 / 0.6 / 41,399 / - / - | 1,554 / 0 / 0.6 / 41,399 / - / - | 710 / 0 / 4.1 / - / - / - | 1,517 / 287 / 1.2 / 41,397 / - / - | 1,551 / 0 / 1.3 / 41,401 / 4 / 0 | 3,956 / 0 / 3.4 / - / - / - |
| q17 | 3,275 / 0 / 5.3 / - / - / - | 3,360 / 0 / 5.2 / - / - / - | 1,555 / 140 / 0.6 / 41,399 / 3 / 0 | 1,557 / 0 / 0.6 / 41,399 / 10 / 0 | 710 / 0 / 4.1 / - / - / - | 1,517 / 287 / 1.2 / 41,397 / - / - | 1,551 / 0 / 1.3 / 41,401 / - / - | 4,454 / 0 / 3.4 / - / - / - |
| q18 | 3,275 / 0 / 5.3 / - / - / - | 3,360 / 0 / 5.0 / - / - / - | 1,555 / 109 / 0.6 / 41,399 / 0 / 0 | 1,557 / 0 / 0.6 / 41,399 / 8 / 1 | 710 / 0 / 4.1 / - / - / - | 1,517 / 287 / 1.2 / 41,397 / - / - | 1,551 / 0 / 1.3 / 41,401 / - / - | 4,454 / 0 / 6.0 / - / - / - |
| q19 | 3,275 / 0 / 1.8 / - / - / - | 3,360 / 0 / 4.1 / - / - / - | 1,554 / 109 / 0.6 / 41,399 / - / - | 1,557 / 0 / 0.6 / 41,399 / - / - | 710 / 0 / 4.1 / - / - / - | 1,517 / 287 / 1.2 / 41,397 / - / - | 1,551 / 0 / 1.3 / 41,401 / - / - | 4,454 / 0 / 6.1 / - / - / - |
| q20 | 3,537 / 0 / 2.2 / - / - / - | 3,409 / 0 / 3.1 / - / - / - | 1,554 / 191 / 0.6 / 41,399 / 2 / 0 | 1,558 / 0 / 0.7 / 41,399 / 6 / 0 | 710 / 0 / 4.1 / - / - / - | 1,517 / 287 / 1.2 / 41,397 / - / - | 1,551 / 0 / 1.3 / 41,401 / - / - | 4,454 / 0 / 6.1 / - / - / - |
| q21 | 3,435 / 0 / 2.3 / - / - / - | 3,848 / 0 / 3.3 / - / - / - | 1,554 / 119 / 0.6 / 41,399 / 13 / 1 | 1,558 / 0 / 0.7 / 41,399 / - / - | 710 / 0 / 4.1 / - / - / - | 1,517 / 287 / 1.2 / 41,397 / - / - | 1,551 / 0 / 1.3 / 41,401 / - / - | 4,454 / 0 / 6.1 / - / - / - |
| q22 | 3,435 / 0 / 2.4 / - / - / - | 3,848 / 0 / 3.3 / - / - / - | 1,554 / 119 / 0.6 / 41,399 / - / - | 1,558 / 0 / 0.7 / 41,399 / 10 / 2 | 710 / 0 / 4.5 / - / - / - | 1,517 / 287 / 1.2 / 41,397 / - / - | 1,551 / 0 / 1.2 / 41,401 / 8 / 3 | 4,454 / 0 / 3.5 / - / - / - |

Bytes read from disk = `/proc/<pid>/io read_bytes` delta over the query (0 on a page-cache hit; O_DIRECT reads always count); sampled every 0.5 s, so sub-second queries are attributed approximately. GPU MiB in use is the RMM pool (reserved up front, not a peak); GPU busy % = nvidia-smi `utilization.gpu` (share of time a kernel was running) and memory-controller busy % = `utilization.memory`, both averaged over the query's samples; `-` when the query was shorter than one sample.

### Environment

#### native (`log/bench-t1/sf1-native`)

```
date: 2026-09-19T11:47:16Z
host: ip-172-31-26-244
instance_type: g6e.8xlarge
kernel: 7.0.0-1012-aws
cpu: AMD EPYC 7R13 Processor x 32
mem_total_kib: 260437876
gpu: NVIDIA L40S, 46068 MiB, 580.178.04
system: native
data: /mnt/nvme/tpch_parquet_sf1 (246M) on /dev/md0       ext4
expected: /home/yy2/gpu/sirius/experimental/doris/tests/expected/tpch-sf1
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f5116c6c docs(doris): T0 results with GPU utilization, SF100 purchase list
sirius_dirty: 3 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb (v1.5.5 (Variegata) 3ff87f1e)
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	true	doris-4.1.4-rc04-ad35a140c7f
-- session variables (GLOBAL) --
parallel_pipeline_task_num	0
experimental_enable_local_shuffle	true
enable_parallel_result_sink	true
runtime_filter_mode	GLOBAL
enable_cte_materialize	true
experimental_topn_lazy_materialization_threshold	1024
file_split_size	0
max_file_split_size	67108864
max_initial_file_split_size	33554432
file_split_size_on_be	67108864
file_split_size_on_fe	536870912
max_file_scanners_concurrency	16
enable_file_scanner_v2	true
enable_fold_constant_by_be	false
enable_profile	false
query_timeout	3600
```

#### native-split (`log/bench-t1/sf1-native-split`)

```
date: 2026-09-19T11:48:45Z
host: ip-172-31-26-244
instance_type: g6e.8xlarge
kernel: 7.0.0-1012-aws
cpu: AMD EPYC 7R13 Processor x 32
mem_total_kib: 260437876
gpu: NVIDIA L40S, 46068 MiB, 580.178.04
system: native-split
data: /mnt/nvme/tpch_parquet_sf1 (246M) on /dev/md0       ext4
expected: /home/yy2/gpu/sirius/experimental/doris/tests/expected/tpch-sf1
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f5116c6c docs(doris): T0 results with GPU utilization, SF100 purchase list
sirius_dirty: 3 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb (v1.5.5 (Variegata) 3ff87f1e)
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	true	doris-4.1.4-rc04-ad35a140c7f
-- session variables (GLOBAL) --
parallel_pipeline_task_num	0
experimental_enable_local_shuffle	true
enable_parallel_result_sink	true
runtime_filter_mode	GLOBAL
enable_cte_materialize	true
experimental_topn_lazy_materialization_threshold	1024
file_split_size	0
max_file_split_size	67108864
max_initial_file_split_size	33554432
file_split_size_on_be	0
file_split_size_on_fe	536870912
max_file_scanners_concurrency	16
enable_file_scanner_v2	true
enable_fold_constant_by_be	false
enable_profile	false
query_timeout	3600
```

#### sirius (`log/bench-t1/sf1-sirius`)

```
date: 2026-09-19T11:50:05Z
host: ip-172-31-26-244
instance_type: g6e.8xlarge
kernel: 7.0.0-1012-aws
cpu: AMD EPYC 7R13 Processor x 32
mem_total_kib: 260437876
gpu: NVIDIA L40S, 46068 MiB, 580.178.04
system: sirius
data: /mnt/nvme/tpch_parquet_sf1 (246M) on /dev/md0       ext4
expected: /home/yy2/gpu/sirius/experimental/doris/tests/expected/tpch-sf1
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f5116c6c docs(doris): T0 results with GPU utilization, SF100 purchase list
sirius_dirty: 3 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb ()
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
  c213f463adb2815a81cb3885ce8920f6da29ef3c7acdcb8a192066419466f284  log/bench-t1/sf1-sirius/sirius.yaml
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	false	doris-4.1.4-rc04-ad35a140c7f
  127.0.0.1	9050	true	sirius-doris-be/0.1.0
-- session variables (GLOBAL) --
parallel_pipeline_task_num	1
experimental_enable_local_shuffle	false
enable_parallel_result_sink	false
runtime_filter_mode	OFF
enable_cte_materialize	false
experimental_topn_lazy_materialization_threshold	-1
file_split_size	1099511627776
max_file_split_size	67108864
max_initial_file_split_size	33554432
file_split_size_on_be	0
file_split_size_on_fe	1099511627776
max_file_scanners_concurrency	16
enable_file_scanner_v2	true
enable_fold_constant_by_be	false
enable_profile	false
query_timeout	3600
```

#### sirius-buffered (`log/bench-t1/sf1-sirius-buffered`)

```
date: 2026-09-19T11:51:06Z
host: ip-172-31-26-244
instance_type: g6e.8xlarge
kernel: 7.0.0-1012-aws
cpu: AMD EPYC 7R13 Processor x 32
mem_total_kib: 260437876
gpu: NVIDIA L40S, 46068 MiB, 580.178.04
system: sirius-buffered
data: /mnt/nvme/tpch_parquet_sf1 (246M) on /dev/md0       ext4
expected: /home/yy2/gpu/sirius/experimental/doris/tests/expected/tpch-sf1
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f5116c6c docs(doris): T0 results with GPU utilization, SF100 purchase list
sirius_dirty: 3 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb ()
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
  0f8b9b52f8bce49730d497355212bf62f626a8031f43833a58e421a1d799b1ca  log/bench-t1/sf1-sirius-buffered/sirius.yaml
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	false	doris-4.1.4-rc04-ad35a140c7f
  127.0.0.1	9050	true	sirius-doris-be/0.1.0
-- session variables (GLOBAL) --
parallel_pipeline_task_num	1
experimental_enable_local_shuffle	false
enable_parallel_result_sink	false
runtime_filter_mode	OFF
enable_cte_materialize	false
experimental_topn_lazy_materialization_threshold	-1
file_split_size	1099511627776
max_file_split_size	67108864
max_initial_file_split_size	33554432
file_split_size_on_be	0
file_split_size_on_fe	1099511627776
max_file_scanners_concurrency	16
enable_file_scanner_v2	true
enable_fold_constant_by_be	false
enable_profile	false
query_timeout	3600
```

#### duckdb (`log/bench-t1/sf1-duckdb`)

```
date: 2026-09-19T11:51:56Z
host: ip-172-31-26-244
instance_type: g6e.8xlarge
kernel: 7.0.0-1012-aws
cpu: AMD EPYC 7R13 Processor x 32
mem_total_kib: 260437876
gpu: NVIDIA L40S, 46068 MiB, 580.178.04
system: duckdb
data: /mnt/nvme/tpch_parquet_sf1 (246M) on /dev/md0       ext4
expected: /home/yy2/gpu/sirius/experimental/doris/tests/expected/tpch-sf1
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f5116c6c docs(doris): T0 results with GPU utilization, SF100 purchase list
sirius_dirty: 3 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb (v1.5.5 (Variegata) 3ff87f1e)
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	false	doris-4.1.4-rc04-ad35a140c7f
  127.0.0.1	9050	true	sirius-doris-be/0.1.0
```

#### duckdb-gpu (`log/bench-t1/sf1-duckdb-gpu`)

```
date: 2026-09-19T11:52:16Z
host: ip-172-31-26-244
instance_type: g6e.8xlarge
kernel: 7.0.0-1012-aws
cpu: AMD EPYC 7R13 Processor x 32
mem_total_kib: 260437876
gpu: NVIDIA L40S, 46068 MiB, 580.178.04
system: duckdb-gpu
data: /mnt/nvme/tpch_parquet_sf1 (246M) on /dev/md0       ext4
expected: /home/yy2/gpu/sirius/experimental/doris/tests/expected/tpch-sf1
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f5116c6c docs(doris): T0 results with GPU utilization, SF100 purchase list
sirius_dirty: 3 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb (v1.5.5 (Variegata) 3ff87f1e)
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
  7a608eb92341984db13d0cd69f8402212e02dc7037c366e66946c4dc2cb7c579  log/bench-t1/sf1-duckdb-gpu/sirius.yaml
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	false	doris-4.1.4-rc04-ad35a140c7f
  127.0.0.1	9050	false	sirius-doris-be/0.1.0
```

#### duckdb-gpu-pinned (`log/bench-t1/sf1-duckdb-gpu-pinned`)

```
date: 2026-09-19T11:52:42Z
host: ip-172-31-26-244
instance_type: g6e.8xlarge
kernel: 7.0.0-1012-aws
cpu: AMD EPYC 7R13 Processor x 32
mem_total_kib: 260437876
gpu: NVIDIA L40S, 46068 MiB, 580.178.04
system: duckdb-gpu-pinned
data: /mnt/nvme/tpch_parquet_sf1 (246M) on /dev/md0       ext4
expected: /home/yy2/gpu/sirius/experimental/doris/tests/expected/tpch-sf1
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f5116c6c docs(doris): T0 results with GPU utilization, SF100 purchase list
sirius_dirty: 3 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb (v1.5.5 (Variegata) 3ff87f1e)
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
  50ca6ecfd4c7bb3c313d3092edb66cf48df418088d187e12c7b20df729e582d3  log/bench-t1/sf1-duckdb-gpu-pinned/sirius.yaml
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	false	doris-4.1.4-rc04-ad35a140c7f
  127.0.0.1	9050	false	sirius-doris-be/0.1.0
```

#### native-olap (`log/bench-t1/sf1-native-olap`)

```
date: 2026-09-19T11:53:15Z
host: ip-172-31-26-244
instance_type: g6e.8xlarge
kernel: 7.0.0-1012-aws
cpu: AMD EPYC 7R13 Processor x 32
mem_total_kib: 260437876
gpu: NVIDIA L40S, 46068 MiB, 580.178.04
system: native-olap
data: /mnt/nvme/tpch_parquet_sf1 (246M) on /dev/md0       ext4
expected: /home/yy2/gpu/sirius/experimental/doris/tests/expected/tpch-sf1
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f5116c6c docs(doris): T0 results with GPU utilization, SF100 purchase list
sirius_dirty: 3 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb (v1.5.5 (Variegata) 3ff87f1e)
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	true	doris-4.1.4-rc04-ad35a140c7f
-- session variables (GLOBAL) --
parallel_pipeline_task_num	0
experimental_enable_local_shuffle	true
enable_parallel_result_sink	true
runtime_filter_mode	GLOBAL
enable_cte_materialize	true
experimental_topn_lazy_materialization_threshold	1024
file_split_size	0
max_file_split_size	67108864
max_initial_file_split_size	33554432
file_split_size_on_be	67108864
file_split_size_on_fe	536870912
max_file_scanners_concurrency	16
enable_file_scanner_v2	true
enable_fold_constant_by_be	false
enable_profile	false
query_timeout	3600
```


---

# 附录 · T0（g4dn.2xlarge，T4 / 8 vCPU，2026-09-19）——跑通用的数字，方法与 T1 相同

## T0 · Doris vs Doris + Sirius · TPC-H SF10（g4dn.2xlarge，2026-09-19）

> **这是 T0（跑通用）的数字，不是结论。** 机器：AWS g4dn.2xlarge = Tesla T4 16 GB（CC 7.5，Sirius 支持的下限，显存带宽 320 GB/s）、8 vCPU（4 物理核 Xeon 8259CL）、30 GB 内存、实例盘 NVMe 实测顺序读只有 **≈0.4 GB/s**（`dd iflag=direct` 单流 411 MB/s，4/8 流并发 357/318 MiB/s）。主结论要等 T1（g6e.4xlarge，L40S 48 GB / 16 vCPU / 128 GB）+ SF100，方法见 `plan.md`。
> 方法：同一个 FE 4.1.4、同一份 SF10 parquet（3.6 GB，一表一文件）、同一批 22 条 SQL（Doris tpch-tools 版）；每个系统 1 冷 + 3 热，热 = 中位数；每一轮的 22 个结果都过 DuckDB 基线校验（7 个系统 × 88 条全部 OK，Q1 的 `avg` 两边都差 1 ulp）。原始数据：`t0-g4dn/<system>/rounds.csv`（每轮每条的 wall / engine / FE 审计 / 采样），环境快照 `env.txt`，会话变量 `variables.txt`。跑法：`experimental/doris/README.md`「Benchmark」，一条 `bench-all.sh`。

### 1. 一眼看完（热跑，22 条合计，秒）

| 系统 | 是什么 | 22 条合计 | 相对 A-split | 用了几个核 |
|---|---|---|---|---|
| **A `native`** | Doris 官方 BE 4.1.4，外表 `local()` 读 parquet，**stock 默认**会话变量 | **52.0** | 0.90× | ≈3.8 |
| **A-split `native-split`** | 同上，只多 `file_split_size_on_be = 0`（FE 侧切文件，plan §10.12） | **46.7** | 1× | ≈6.0 |
| C `native-olap` | Doris 内表（官方 DDL 分桶 + colocate + ANALYZE），Doris 主场 | **11.4** | 4.1× | — |
| **B `sirius`** | Doris + Sirius 伪 BE，Sirius 默认 **O_DIRECT** 直读 parquet | **54.6** | 0.86× | ≈1.0 |
| **B′ `sirius-buffered`** | 同上，`use_odirect: false` 走 page cache | **21.0** | **2.22×（几何平均 2.03×）** | ≈1.2 |
| R1 `duckdb` | DuckDB 1.5.5，8 线程，单进程 | 17.1 | 2.73× | ≈6.7 |
| R2 `duckdb-gpu` | Sirius 透明路径（DuckDB 规划、GPU 执行、O_DIRECT） | 54.3 | 0.86× | — |

冷跑（第 1 轮）合计：A 53.5、A-split 47.7、C 12.0、B 54.9、B′ 22.4、R1 18.6、R2 54.0——在这台机器上冷热差别不大（数据集 3.6 GB，NVMe 顺序读 0.4 GB/s，Doris 与 DuckDB 的解码/计算比读盘慢）。

### 2. 怎么读这些数字

1. **主表口径 A-split vs B′：GPU 路径快 2.0～2.2×（几何平均 2.03×，power 总时间 2.22×）**，单条从 0.96×（Q22）到 4.73×（Q3）；扫描聚合型（Q1 4.02×、Q3 4.73×、Q13 3.05×、Q18 3.45×）领先最多，小结果/小表 join 型（Q2 1.10×、Q16 1.11×、Q22 0.96×）持平——和论文的趋势一致（Q1 类最大、Q6 类小），量级不能比（论文 4 节点 A100 + SF100）。对 stock 默认的 A 是 2.47×。
2. **B 的默认 O_DIRECT 在这台机器上是磁盘的成绩，不是引擎的**：每条查询都从盘重读它用到的列（一轮 22 条读 18 GB），实测有效读速 260～640 MB/s（Q6 读 604 MB 用 1.63 s；Q21 读 1.72 GB 用 6.5 s），与 `dd` 测出的 0.4 GB/s 一致。同一批查询走 page cache（B′）后引擎时间 Q6 0.42 s、Q9 1.21 s、Q21 2.71 s。**T1 机型要先 `dd iflag=direct` 量一下 NVMe**；SF100（25 GB）在 128 GB 内存的机器上 page cache 也放得下，B 与 B′ 都要跑。
3. **伪 BE 协议和 plan 形状的代价在 SF10 上可以忽略**：B（伪 BE）vs R2（Sirius 自己规划、同样 O_DIRECT）逐条几何平均 0.99×；B′ 的 wall − engine ≈ 150 ms/条（FE 规划 16～67 ms + RPC/取数），引擎时间占 wall 的 84 %（B 是 94 %）。SF1 时 FE 开销占一半以上，SF10 已经不是主项。
4. **T4 上的 Sirius ≈ 8 线程的 DuckDB**（B′ 21.0 s vs R1 17.1 s，几何平均 R1 快 1.30×）：这就是"T4 是下限"的意思——320 GB/s 的显存带宽和 CC 7.5，L40S 是它的 2.7 倍带宽。
5. **Doris 外表路径 ≠ Doris 主场**：内表（C）11.4 s，比外表 stock 快 4.6×，比 B′ 还快 1.84×（几何平均 2.34×）——分桶 + colocate join + 前缀索引/zone map（Q6 73 ms、Q3 205 ms）+ 列存直读，没有 parquet 解码。这一行不进主表，但读者一定会问；T1 上同样要跑。注意 C 必须关 FE 的 `enable_sql_cache`（4.1.4 默认开，重复查询 15 ms 命中缓存，第一次跑的热轮全是缓存，已重跑）。
6. **Doris 4.1.4 单文件外表的 stock 默认扫描并行度受限**（plan §10.12）：SF1 只有 1 个 scanner 干活，SF10 的 2.4 GB 文件被 FE 切成 5 段后能用 ≈4 核；`file_split_size_on_be = 0` 让 FE 切 32/64 MB → ≈6 核，22 条合计 52.0 → 46.7 s。Q1 仍要 3.9 s（6.6 核）——parquet 解码 + 聚合的 CPU 吞吐就是这样。
7. **显存够**：SF10 在 T4 的 13.5 GB 池子里没有触发 host/disk 降级（R2 日志 GPU 池高水位 11.2 GB，host 池 0.48 GB；telemetry 无 spill 事件）。plan §10.2 担心的 Q9/Q21 降级在 SF10 上没发生；SF100 会。
8. **资源**：B/B′ 进程 RSS ≈1.7 GB（不含 16 GiB 的 pinned host 池），CPU ≈1 核；A 4～6 核、RSS 2～8 GB（Q9/Q10 8 GB）；热跑时 A/B′/R1 的 `read_bytes` 为 0（全在 page cache），B/R2 每条 0.2～1.7 GB（O_DIRECT）。GPU 显存列是 RMM 预留的 13.5 GB，不是峰值（T1 要从 Quent telemetry 取每条查询的 tier 字节数）。
9. **T4 大部分时间是空的**（`nvidia-smi utilization.gpu` 按查询窗口取均值）：B′ 22 条的 GPU busy 中位数 **20 %**（Q22 66 %、Q1 47 %、Q10/Q21 36 %、Q13 32 %；Q2/Q6/Q12/Q14/Q19 ≈0 %），显存控制器忙 2～3 %；B 12 %、R2 14 %（盘在喂）。也就是说 SF10 在这台机器上引擎时间主要花在数据搬运和调度上（page cache → pinned host → PCIe 3.0 H2D、扫描元数据、4 个 pipeline 线程），不是 GPU 算——单换更快的 GPU 帮助有限，PCIe 4.0（L40S）、`enable_prefetch_cache`、`pin_table`（表常驻显存，R2 的 `-pinned` 行）才对症；也解释了为什么 T4 ≈ 8 线程 DuckDB。SF100 数据装不下显存时 host tier 的搬运会更重，T1 要看这两列。

### 3. 这次跑通过程中修掉的方法问题（都已进脚本）

- 伪 BE 注册在 FE 上会把原生 BE 的自动并行度压成 1（`bench.sh` 跑原生系统前 `DROPP BACKEND`）；
- 4.1.4 的两级文件切分在 SF10 上把 lineitem 切成 512 MB 段，伪 BE 拒绝（`session.sql` 钉 `file_split_size_on_be = 0`、`file_split_size_on_fe = 1 TB`）；
- FE 的 `enable_sql_cache` 默认开（三个 session 文件都关）；
- 原生 BE 的 `storage_root_path` 不能在 FE 见过它之后再变（FE 内部统计表的副本会变坏，连带内表查询规划失败）；本机 BE 现在挂两个 root；
- 刚 stop 的 BE 在 FE 上还 Alive 几秒，`be-native.sh` 现在 stop 等 `Alive=false`、start 等 pid 文件；
- 没有 BE alive 时 `SELECT 1` 都会失败，可达性检查用 `SHOW BACKENDS`。

### 4. 下一步（T1）

按 `plan.md` §8 步骤 10：g6e.4xlarge 上 `environment.md` 搭环境 → `bench-all.sh --data …sf10` 验证 → SF100（`tpchgen-cli -s 100`，基线到 NVMe）→ 7 个系统 + `duckdb-gpu-pinned`；T1′ c7i.12xlarge 只跑 `native`/`native-split`（`--price` 两台的价）。先量 NVMe 读速；`conf/sirius-bench.yaml` 的 host tier 自动按 RAM 算（128 GB → 114 GiB）。

---

以下为 `scripts/bench-report.py report` 自动生成的完整表（英文）。

## Doris vs Doris + Sirius · TPC-H SF10 · g4dn.2xlarge (T4, 8 vCPU) · 2026-09-19

Systems: `native` (4 round(s)), `native-split` (4 round(s)), `native-olap` (4 round(s)), `sirius` (4 round(s)), `sirius-buffered` (4 round(s)), `duckdb` (4 round(s)), `duckdb-gpu` (4 round(s)). Round 1 is cold (freshly started process, page cache evicted), the others hot; **hot** = median of the hot rounds, (min) in parentheses; ms of client round trip (`wall_ms`). Queries that did not validate against the DuckDB baseline in every round are marked and excluded from speedups and totals.

### Hot runs (median wall ms, min in parentheses)

| q | native | native-split | native-olap | sirius | sirius-buffered | duckdb | duckdb-gpu | speedup native-split/sirius-buffered | sirius-buffered engine ms | notes |
|---|---|---|---|---|---|---|---|---|---|---|
| q01 | 4,641 (4,617) | 3,919 (3,916) | 2,505 (2,126) | 1,047 (1,038) | 976 (962) | 1,067 (1,049) | 1,263 (1,262) | **4.02×** | 890 |  |
| q02 | 1,627 (1,588) | 644 (637) | 262 (208) | 600 (599) | 587 (585) | 176 (171) | 659 (657) | **1.10×** | 293 |  |
| q03 | 3,646 (3,521) | 3,731 (3,730) | 205 (163) | 2,830 (2,821) | 788 (778) | 808 (804) | 2,937 (2,936) | **4.73×** | 679 |  |
| q04 | 1,698 (1,665) | 1,626 (1,561) | 377 (322) | 1,387 (1,381) | 609 (579) | 532 (530) | 1,450 (1,450) | **2.67×** | 536 |  |
| q05 | 2,425 (2,360) | 2,521 (2,513) | 515 (413) | 3,322 (3,312) | 1,104 (1,082) | 807 (795) | 3,353 (3,348) | **2.28×** | 921 |  |
| q06 | 1,418 (1,362) | 1,267 (1,261) | 73 (67) | 1,682 (1,679) | 471 (464) | 410 (406) | 1,790 (1,780) | **2.69×** | 422 |  |
| q07 | 2,662 (2,557) | 1,895 (1,889) | 362 (284) | 3,637 (3,625) | 1,212 (1,165) | 712 (701) | 3,509 (3,505) | **1.56×** | 1,006 |  |
| q08 | 2,994 (2,862) | 2,073 (2,057) | 709 (645) | 4,627 (4,625) | 1,481 (1,473) | 885 (869) | 4,579 (4,578) | **1.40×** | 1,204 |  |
| q09 | 3,637 (3,590) | 3,787 (3,785) | 907 (780) | 4,756 (4,705) | 1,412 (1,409) | 1,701 (1,644) | 4,786 (4,785) | **2.68×** | 1,209 |  |
| q10 | 2,430 (2,430) | 2,475 (2,447) | 616 (559) | 2,811 (2,783) | 996 (990) | 907 (871) | 2,880 (2,813) | **2.48×** | 852 |  |
| q11 | 1,045 (1,025) | 665 (655) | 336 (304) | 690 (685) | 553 (549) | 270 (270) | 810 (809) | **1.20×** | 238 |  |
| q12 | 1,600 (1,552) | 1,281 (1,281) | 278 (250) | 1,580 (1,570) | 681 (676) | 618 (606) | 1,628 (1,627) | **1.88×** | 595 |  |
| q13 | 3,619 (3,615) | 1,422 (1,402) | 1,054 (972) | 1,713 (1,653) | 466 (465) | 1,149 (1,133) | 1,640 (1,636) | **3.05×** | 402 |  |
| q14 | 1,218 (1,201) | 1,219 (1,217) | 91 (90) | 2,594 (2,586) | 726 (723) | 575 (564) | 2,787 (2,783) | **1.68×** | 641 |  |
| q15 | 2,378 (2,084) | 2,578 (2,536) | 206 (193) | 2,535 (2,522) | 1,168 (1,157) | 476 (475) | 2,522 (2,519) | **2.21×** | 1,033 |  |
| q16 | 565 (560) | 345 (330) | 328 (313) | 363 (346) | 311 (308) | 238 (228) | 244 (242) | **1.11×** | 186 |  |
| q17 | 2,494 (2,452) | 3,088 (3,048) | 140 (140) | 3,491 (3,444) | 1,102 (1,073) | 653 (651) | 3,725 (3,720) | **2.80×** | 991 |  |
| q18 | 3,785 (3,724) | 4,620 (4,611) | 870 (853) | 2,242 (2,233) | 1,338 (1,336) | 1,360 (1,355) | 2,317 (2,315) | **3.45×** | 1,181 |  |
| q19 | 1,737 (1,710) | 1,504 (1,501) | 237 (233) | 2,771 (2,769) | 782 (758) | 722 (710) | 2,815 (2,812) | **1.92×** | 672 |  |
| q20 | 1,557 (1,509) | 1,499 (1,491) | 199 (186) | 2,747 (2,741) | 968 (935) | 584 (574) | 2,807 (2,803) | **1.55×** | 794 |  |
| q21 | 4,078 (4,004) | 4,127 (4,090) | 915 (872) | 6,734 (6,727) | 2,919 (2,855) | 2,202 (2,127) | 5,440 (5,430) | **1.41×** | 2,706 |  |
| q22 | 755 (743) | 365 (337) | 183 (176) | 394 (388) | 381 (374) | 269 (268) | 385 (373) | **0.96×** | 277 |  |
| **power total** | **52,009** (22 q) | **46,651** (22 q) | **11,368** (22 q) | **54,553** (22 q) | **21,031** (22 q) | **17,121** (22 q) | **54,326** (22 q) | **geomean 2.03×**, total 2.22× | 17,730 |  |

Cost-normalized (plan §7): native-split at $0.752/h vs sirius-buffered at $0.752/h → geomean speedup per dollar **2.03×**.

### Cold run (round 1, wall ms)

| q | native | native-split | native-olap | sirius | sirius-buffered | duckdb | duckdb-gpu |
|---|---|---|---|---|---|---|---|
| q01 | 5,057 | 4,334 | 2,852 | 1,790 | 1,917 | 1,257 | 1,264 |
| q02 | 1,864 | 738 | 345 | 704 | 722 | 440 | 357 |
| q03 | 3,860 | 3,904 | 441 | 2,249 | 905 | 1,461 | 2,858 |
| q04 | 1,772 | 1,591 | 490 | 1,504 | 748 | 596 | 1,491 |
| q05 | 2,604 | 2,591 | 665 | 3,236 | 1,152 | 873 | 3,340 |
| q06 | 1,332 | 1,238 | 76 | 1,659 | 490 | 410 | 1,732 |
| q07 | 2,634 | 1,944 | 304 | 3,641 | 1,189 | 735 | 3,549 |
| q08 | 2,986 | 2,132 | 695 | 4,673 | 1,556 | 979 | 4,597 |
| q09 | 3,654 | 3,805 | 790 | 4,766 | 1,363 | 1,757 | 4,843 |
| q10 | 2,550 | 2,530 | 606 | 2,798 | 1,015 | 914 | 2,841 |
| q11 | 1,094 | 694 | 306 | 712 | 578 | 284 | 820 |
| q12 | 1,600 | 1,250 | 263 | 1,584 | 704 | 614 | 1,600 |
| q13 | 3,947 | 1,464 | 992 | 1,626 | 555 | 1,195 | 1,707 |
| q14 | 1,197 | 1,226 | 88 | 2,639 | 682 | 566 | 2,712 |
| q15 | 2,327 | 2,533 | 204 | 2,550 | 1,132 | 496 | 2,527 |
| q16 | 591 | 341 | 311 | 419 | 372 | 247 | 305 |
| q17 | 2,420 | 3,158 | 139 | 3,394 | 1,038 | 662 | 3,660 |
| q18 | 3,855 | 4,604 | 944 | 2,242 | 1,326 | 1,385 | 2,312 |
| q19 | 1,647 | 1,541 | 235 | 2,791 | 764 | 727 | 2,843 |
| q20 | 1,540 | 1,559 | 188 | 2,727 | 894 | 584 | 2,765 |
| q21 | 4,193 | 4,211 | 940 | 6,779 | 2,880 | 2,177 | 5,441 |
| q22 | 765 | 332 | 171 | 408 | 402 | 269 | 391 |
| **total** | 53,489 | 47,720 | 12,045 | 54,891 | 22,384 | 18,628 | 53,955 |

### FE audit (hot medians, ms): fe = FE end-to-end, plan = Nereids planning, rpc1 = first exec RPC

| q | native fe / plan / rpc1 | native-split fe / plan / rpc1 | native-olap fe / plan / rpc1 | sirius fe / plan / rpc1 | sirius-buffered fe / plan / rpc1 |
|---|---|---|---|---|---|
| q01 | 4,626 / 27 / 3 | 3,905 / 26 / 5 | 2,111 / -1 / 10 | 1,032 / 15 / 1,012 | 962 / 16 / 942 |
| q02 | 1,612 / 71 / 10 | 630 / 69 / 11 | 194 / 16 / 12 | 586 / 63 / 519 | 572 / 64 / 510 |
| q03 | 3,632 / 42 / 5 | 3,717 / 44 / 7 | 189 / 9 / 20 | 2,815 / 29 / 2,784 | 773 / 30 / 740 |
| q04 | 1,683 / 36 / 4 | 1,611 / 35 / 5 | 359 / 6 / 18 | 1,372 / 25 / 1,345 | 594 / 25 / 569 |
| q05 | 2,409 / 62 / 7 | 2,507 / 63 / 10 | 399 / 29 / 21 | 3,307 / 47 / 3,257 | 1,090 / 49 / 1,035 |
| q06 | 1,403 / 26 / 2 | 1,254 / 26 / 3 | 59 / 4 / 3 | 1,668 / 16 / 1,649 | 457 / 15 / 438 |
| q07 | 2,647 / 69 / 8 | 1,882 / 61 / 10 | 347 / 31 / 32 | 3,621 / 49 / 3,563 | 1,198 / 52 / 1,141 |
| q08 | 2,978 / 76 / 9 | 2,058 / 72 / 11 | 694 / 67 / 26 | 4,612 / 61 / 4,549 | 1,466 / 65 / 1,394 |
| q09 | 3,622 / 65 / 8 | 3,773 / 61 / 9 | 766 / 30 / 21 | 4,742 / 46 / 4,695 | 1,397 / 47 / 1,347 |
| q10 | 2,416 / 53 / 6 | 2,460 / 50 / 8 | 308 / -1 / 9 | 2,797 / 36 / 2,757 | 976 / 36 / 937 |
| q11 | 987 / 47 / 8 | 607 / 46 / 9 | 246 / 12 / 12 | 628 / 42 / 555 | 491 / 40 / 415 |
| q12 | 1,585 / 37 / 5 | 1,266 / 37 / 6 | 263 / 8 / 22 | 1,565 / 23 / 1,540 | 667 / 24 / 639 |
| q13 | 3,605 / 21 / 6 | 1,400 / 19 / 6 | 957 / 6 / 10 | 1,699 / 16 / 1,681 | 451 / 17 / 432 |
| q14 | 1,204 / 38 / 4 | 1,206 / 35 / 5 | 77 / 6 / 6 | 2,579 / 24 / 2,553 | 710 / 24 / 684 |
| q15 | 2,365 / 61 / 5 | 2,563 / 62 / 7 | 178 / 12 / 10 | 2,520 / 38 / 2,480 | 1,152 / 42 / 1,108 |
| q16 | 535 / 27 / 6 | 316 / 25 / 8 | 299 / 9 / 11 | 334 / 24 / 301 | 281 / 24 / 249 |
| q17 | 2,477 / 59 / 5 | 3,074 / 57 / 7 | 126 / 8 / 5 | 3,477 / 43 / 3,435 | 1,088 / 38 / 1,047 |
| q18 | 3,772 / 67 / 6 | 4,606 / 70 / 9 | 856 / 13 / 27 | 2,228 / 43 / 2,179 | 1,323 / 44 / 1,274 |
| q19 | 1,722 / 41 / 6 | 1,489 / 39 / 5 | 221 / 14 / 7 | 2,756 / 27 / 2,727 | 767 / 28 / 734 |
| q20 | 1,541 / 58 / 8 | 1,484 / 57 / 9 | 183 / 13 / 14 | 2,725 / 44 / 2,678 | 952 / 44 / 904 |
| q21 | 4,063 / 104 / 8 | 4,113 / 103 / 13 | 901 / 40 / 34 | 6,719 / 66 / 6,651 | 2,904 / 68 / 2,832 |
| q22 | 740 / 32 / 6 | 350 / 31 / 7 | 161 / 10 / 11 | 377 / 28 / 344 | 367 / 27 / 337 |

### Resources (hot medians): peak RSS MiB / bytes read from disk MiB / CPU cores busy / GPU MiB in use / GPU busy % / GPU memory-controller busy %

| q | native | native-split | native-olap | sirius | sirius-buffered | duckdb | duckdb-gpu |
|---|---|---|---|---|---|---|---|
| q01 | 1,927 / 0 / 4.1 / - / - / - | 3,309 / 0 / 6.6 / - / - / - | 6,905 / 1 / 6.4 / - / - / - | 1,710 / 613 / 1.4 / 13,583 / 42 / 20 | 1,703 / 0 / 1.5 / 13,583 / 47 / 23 | 662 / 0 / 6.6 / - / - / - | 1,355 / 746 / 1.2 / 13,567 / 49 / 10 |
| q02 | 1,921 / 0 / 1.4 / - / - / - | 3,217 / 0 / 4.6 / - / - / - | 6,905 / 0 / 4.4 / - / - / - | 1,710 / 245 / 1.1 / 13,583 / 0 / 0 | 1,703 / 0 / 1.1 / 13,583 / 0 / 0 | 662 / 0 / 6.3 / - / - / - | 1,391 / 339 / 0.8 / 13,569 / 49 / 15 |
| q03 | 3,673 / 0 / 3.8 / - / - / - | 4,703 / 0 / 5.2 / - / - / - | 6,905 / 0 / 4.6 / - / - / - | 1,712 / 1,119 / 0.4 / 13,583 / 13 / 3 | 1,704 / 0 / 1.2 / 13,583 / 15 / 3 | 662 / 0 / 6.7 / - / - / - | 1,403 / 986 / 0.3 / 13,573 / 8 / 2 |
| q04 | 3,752 / 0 / 4.0 / - / - / - | 4,813 / 0 / 5.8 / - / - / - | 6,905 / 0 / 5.0 / - / - / - | 1,709 / 537 / 0.6 / 13,583 / 30 / 7 | 1,704 / 0 / 1.0 / 13,583 / 8 / 0 | 690 / 0 / 6.8 / - / - / - | 1,479 / 692 / 0.6 / 13,575 / 18 / 2 |
| q05 | 3,752 / 0 / 4.1 / - / - / - | 4,813 / 0 / 5.8 / - / - / - | 6,993 / 1 / 5.4 / - / - / - | 1,744 / 1,070 / 0.5 / 13,583 / 10 / 2 | 1,742 / 0 / 1.2 / 13,583 / 26 / 5 | 691 / 0 / 6.7 / - / - / - | 1,497 / 1,204 / 0.3 / 13,575 / 22 / 4 |
| q06 | 2,871 / 0 / 3.1 / - / - / - | 4,042 / 0 / 6.8 / - / - / - | 6,993 / 0 / 5.0 / - / - / - | 1,744 / 604 / 0.5 / 13,583 / 6 / 1 | 1,739 / 0 / 1.2 / 13,583 / 0 / 0 | 691 / 0 / 6.8 / - / - / - | 1,497 / 613 / 0.5 / 13,575 / 20 / 6 |
| q07 | 2,322 / 0 / 2.8 / - / - / - | 3,526 / 0 / 6.4 / - / - / - | 7,088 / 0 / 5.0 / - / - / - | 1,736 / 1,188 / 0.5 / 13,583 / 14 / 4 | 1,739 / 0 / 1.3 / 13,583 / 24 / 2 | 798 / 0 / 6.7 / - / - / - | 1,529 / 1,374 / 1.2 / 13,575 / 13 / 1 |
| q08 | 2,692 / 0 / 3.5 / - / - / - | 3,333 / 0 / 6.5 / - / - / - | 7,247 / 0 / 5.4 / - / - / - | 1,743 / 1,389 / 0.5 / 13,583 / 12 / 2 | 1,724 / 0 / 1.2 / 13,583 / 26 / 3 | 924 / 0 / 6.5 / - / - / - | 1,546 / 1,544 / 1.2 / 13,575 / 15 / 2 |
| q09 | 6,316 / 0 / 5.0 / - / - / - | 8,162 / 0 / 6.2 / - / - / - | 7,438 / 0 / 6.2 / - / - / - | 1,743 / 1,471 / 0.4 / 13,583 / 16 / 2 | 1,724 / 0 / 1.2 / 13,583 / 29 / 4 | 1,766 / 0 / 7.2 / - / - / - | 1,546 / 1,728 / 1.2 / 13,575 / 22 / 4 |
| q10 | 6,316 / 0 / 4.0 / - / - / - | 8,162 / 0 / 5.5 / - / - / - | 7,438 / 0 / 5.9 / - / - / - | 1,743 / 959 / 0.5 / 13,583 / 20 / 7 | 1,713 / 0 / 1.1 / 13,583 / 36 / 7 | 1,766 / 0 / 6.5 / - / - / - | 1,539 / 1,089 / 0.5 / 13,577 / 8 / 1 |
| q11 | 4,083 / 0 / 2.4 / - / - / - | 5,678 / 0 / 5.0 / - / - / - | 7,410 / 0 / 5.0 / - / - / - | 1,697 / 235 / 0.6 / 13,583 / 30 / 4 | 1,709 / 0 / 1.0 / 13,583 / 1 / 0 | 1,431 / 0 / 5.4 / - / - / - | 1,534 / 238 / 1.1 / 13,579 / 9 / 0 |
| q12 | 3,018 / 0 / 3.1 / - / - / - | 4,472 / 0 / 6.3 / - / - / - | 7,245 / 0 / 5.7 / - / - / - | 1,706 / 701 / 0.5 / 13,583 / 19 / 3 | 1,709 / 0 / 1.1 / 13,583 / 0 / 0 | 1,366 / 0 / 6.4 / - / - / - | 1,559 / 678 / 0.6 / 13,579 / 13 / 4 |
| q13 | 2,497 / 0 / 2.0 / - / - / - | 3,673 / 0 / 6.5 / - / - / - | 7,245 / 0 / 6.2 / - / - / - | 1,706 / 493 / 0.5 / 13,583 / 7 / 0 | 1,709 / 0 / 1.3 / 13,583 / 32 / 12 | 1,115 / 0 / 7.2 / - / - / - | 1,594 / 696 / 0.5 / 13,579 / 10 / 1 |
| q14 | 1,981 / 0 / 3.7 / - / - / - | 3,059 / 0 / 6.6 / - / - / - | 7,034 / 0 / 5.3 / - / - / - | 1,726 / 875 / 0.6 / 13,583 / 11 / 5 | 1,697 / 0 / 1.2 / 13,583 / 0 / 0 | 1,115 / 0 / 6.9 / - / - / - | 1,594 / 943 / 0.6 / 13,579 / 13 / 3 |
| q15 | 2,047 / 0 / 5.2 / - / - / - | 3,339 / 0 / 6.8 / - / - / - | 7,034 / 0 / 5.1 / - / - / - | 1,747 / 778 / 0.7 / 13,583 / 9 / 2 | 1,737 / 0 / 1.2 / 13,583 / 10 / 0 | 1,097 / 0 / 6.6 / - / - / - | 1,645 / 938 / 0.6 / 13,583 / 20 / 4 |
| q16 | 2,029 / 0 / 2.8 / - / - / - | 3,339 / 0 / 4.9 / - / - / - | 7,244 / 0 / 5.0 / - / - / - | 1,747 / 84 / 0.7 / 13,583 / 68 / 20 | 1,737 / 0 / 1.1 / 13,583 / 22 / 3 | 1,013 / 0 / 6.6 / - / - / - | 1,645 / 86 / 1.5 / 13,583 / - / - |
| q17 | 2,416 / 0 / 6.1 / - / - / - | 4,238 / 0 / 6.4 / - / - / - | 7,244 / 0 / 4.9 / - / - / - | 1,770 / 1,268 / 0.5 / 13,583 / 12 / 3 | 1,747 / 0 / 1.1 / 13,583 / 6 / 1 | 925 / 0 / 6.7 / - / - / - | 1,722 / 1,377 / 0.4 / 13,583 / 12 / 3 |
| q18 | 6,379 / 0 / 4.6 / - / - / - | 8,424 / 0 / 4.8 / - / - / - | 8,066 / 0 / 6.1 / - / - / - | 1,770 / 722 / 0.8 / 13,583 / 4 / 0 | 1,758 / 0 / 1.2 / 13,583 / 19 / 3 | 1,349 / 0 / 7.2 / - / - / - | 1,722 / 866 / 0.5 / 13,583 / 14 / 4 |
| q19 | 6,348 / 0 / 3.5 / - / - / - | 8,276 / 0 / 5.8 / - / - / - | 8,066 / 0 / 5.4 / - / - / - | 1,752 / 902 / 0.5 / 13,583 / 10 / 1 | 1,758 / 0 / 1.5 / 13,583 / 0 / 0 | 1,349 / 0 / 7.1 / - / - / - | 1,685 / 998 / 0.4 / 13,583 / 9 / 1 |
| q20 | 5,042 / 0 / 4.2 / - / - / - | 5,636 / 0 / 6.0 / - / - / - | 8,224 / 0 / 4.5 / - / - / - | 1,712 / 890 / 0.5 / 13,583 / 11 / 1 | 1,727 / 0 / 1.1 / 13,583 / 20 / 2 | 955 / 0 / 6.7 / - / - / - | 1,680 / 956 / 0.3 / 13,583 / 11 / 2 |
| q21 | 3,167 / 0 / 4.2 / - / - / - | 4,575 / 0 / 6.8 / - / - / - | 8,178 / 0 / 5.3 / - / - / - | 1,763 / 1,717 / 0.7 / 13,583 / 10 / 3 | 1,775 / 0 / 1.4 / 13,583 / 36 / 12 | 1,025 / 0 / 6.7 / - / - / - | 1,692 / 1,866 / 0.3 / 13,583 / 14 / 4 |
| q22 | 2,359 / 0 / 1.4 / - / - / - | 4,341 / 0 / 4.4 / - / - / - | 7,702 / 0 / 3.5 / - / - / - | 1,762 / 152 / 0.6 / 13,583 / 99 / 81 | 1,776 / 0 / 1.1 / 13,583 / 66 / 55 | 944 / 0 / 5.3 / - / - / - | 1,692 / 215 / 0.8 / 13,583 / 66 / 11 |

Bytes read from disk = `/proc/<pid>/io read_bytes` delta over the query (0 on a page-cache hit; O_DIRECT reads always count); sampled every 0.5 s, so sub-second queries are attributed approximately. GPU MiB in use is the RMM pool (reserved up front, not a peak); GPU busy % = nvidia-smi `utilization.gpu` (share of time a kernel was running) and memory-controller busy % = `utilization.memory`, both averaged over the query's samples; `-` when the query was shorter than one sample.

### Environment

#### native (`log/bench/sf10-native`)

```
date: 2026-09-19T04:42:51Z
host: ip-172-31-67-209
instance_type: g4dn.2xlarge
kernel: 6.17.0-1017-aws
cpu: Intel(R) Xeon(R) Platinum 8259CL CPU @ 2.50GHz x 8
mem_total_kib: 32481256
gpu: Tesla T4, 15360 MiB, 580.178.04
system: native
data: /mnt/nvme/tpch_parquet_sf10 (3.6G) on /dev/nvme1n1   ext4
expected: /home/yy2/gpu/sirius/experimental/doris/tests/expected/tpch-sf10
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f7f3b396 docs(doris): benchmark plan — SF10 only to shake down on the T4 box, SF100 for
sirius_dirty: 18 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb (v1.5.5 (Variegata) 3ff87f1e)
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  16916ce2e856f83d6b8694f9a00edf1afbb72270c5b2703af6d81bb5d9b48ec7  conf/fe.conf
  fd87521fb03decd065481ce0f8c660e2ca3908d28d1cf8ceec19982e8ed5af49  sql/session.sql
  213883c09fbc8a758232b5f7ee29b63889cd4bb62cbcc853bc49ba2266e247d7  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	true	doris-4.1.4-rc04-ad35a140c7f
-- session variables (GLOBAL) --
parallel_pipeline_task_num	0
experimental_enable_local_shuffle	true
enable_parallel_result_sink	true
runtime_filter_mode	GLOBAL
enable_cte_materialize	true
experimental_topn_lazy_materialization_threshold	1024
file_split_size	0
max_file_split_size	67108864
max_initial_file_split_size	33554432
file_split_size_on_be	67108864
file_split_size_on_fe	536870912
max_file_scanners_concurrency	16
enable_file_scanner_v2	true
enable_fold_constant_by_be	false
enable_profile	false
query_timeout	3600
```

#### native-split (`log/bench/sf10-native-split`)

```
date: 2026-09-19T05:18:22Z
host: ip-172-31-67-209
instance_type: g4dn.2xlarge
kernel: 6.17.0-1017-aws
cpu: Intel(R) Xeon(R) Platinum 8259CL CPU @ 2.50GHz x 8
mem_total_kib: 32481256
gpu: Tesla T4, 15360 MiB, 580.178.04
system: native-split
data: /mnt/nvme/tpch_parquet_sf10 (3.6G) on /dev/nvme1n1   ext4
expected: /home/yy2/gpu/sirius/experimental/doris/tests/expected/tpch-sf10
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f7f3b396 docs(doris): benchmark plan — SF10 only to shake down on the T4 box, SF100 for
sirius_dirty: 21 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb (v1.5.5 (Variegata) 3ff87f1e)
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  af8ddac15bc86c1590130b5320297a52802b072a97f59506d464b07a8e141a00  sql/session.sql
  94660fca7a589535025c19443b183e9f45803e3de0b4283d05bb06f8afea716e  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	true	doris-4.1.4-rc04-ad35a140c7f
-- session variables (GLOBAL) --
parallel_pipeline_task_num	0
experimental_enable_local_shuffle	true
enable_parallel_result_sink	true
runtime_filter_mode	GLOBAL
enable_cte_materialize	true
experimental_topn_lazy_materialization_threshold	1024
file_split_size	0
max_file_split_size	67108864
max_initial_file_split_size	33554432
file_split_size_on_be	0
file_split_size_on_fe	536870912
max_file_scanners_concurrency	16
enable_file_scanner_v2	true
enable_fold_constant_by_be	false
enable_profile	false
query_timeout	3600
```

#### native-olap (`log/bench/sf10-native-olap`)

```
date: 2026-09-19T05:29:33Z
host: ip-172-31-67-209
instance_type: g4dn.2xlarge
kernel: 6.17.0-1017-aws
cpu: Intel(R) Xeon(R) Platinum 8259CL CPU @ 2.50GHz x 8
mem_total_kib: 32481256
gpu: Tesla T4, 15360 MiB, 580.178.04
system: native-olap
data: /mnt/nvme/tpch_parquet_sf10 (3.6G) on /dev/nvme1n1   ext4
expected: /home/yy2/gpu/sirius/experimental/doris/tests/expected/tpch-sf10
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f7f3b396 docs(doris): benchmark plan — SF10 only to shake down on the T4 box, SF100 for
sirius_dirty: 21 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb (v1.5.5 (Variegata) 3ff87f1e)
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	true	doris-4.1.4-rc04-ad35a140c7f
-- session variables (GLOBAL) --
parallel_pipeline_task_num	0
experimental_enable_local_shuffle	true
enable_parallel_result_sink	true
runtime_filter_mode	GLOBAL
enable_cte_materialize	true
experimental_topn_lazy_materialization_threshold	1024
file_split_size	0
max_file_split_size	67108864
max_initial_file_split_size	33554432
file_split_size_on_be	67108864
file_split_size_on_fe	536870912
max_file_scanners_concurrency	16
enable_file_scanner_v2	true
enable_fold_constant_by_be	false
enable_profile	false
query_timeout	3600
```

#### sirius (`log/bench/sf10-sirius`)

```
date: 2026-09-19T06:13:31Z
host: ip-172-31-67-209
instance_type: g4dn.2xlarge
kernel: 6.17.0-1017-aws
cpu: Intel(R) Xeon(R) Platinum 8259CL CPU @ 2.50GHz x 8
mem_total_kib: 32481256
gpu: Tesla T4, 15360 MiB, 580.178.04
system: sirius
data: /mnt/nvme/tpch_parquet_sf10 (3.6G) on /dev/nvme1n1   ext4
expected: /home/yy2/gpu/sirius/experimental/doris/tests/expected/tpch-sf10
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: 39c8945d docs(doris): SF10 benchmark shaken down on the T4 box — T0 results, plan decis
sirius_dirty: 3 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb ()
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
  78f3b82152d783026ead0a75e3ff8196cfd83605731d3c8f19c952d860f40f49  log/bench/sf10-sirius/sirius.yaml
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	false	doris-4.1.4-rc04-ad35a140c7f
  127.0.0.1	9050	true	sirius-doris-be/0.1.0
-- session variables (GLOBAL) --
parallel_pipeline_task_num	1
experimental_enable_local_shuffle	false
enable_parallel_result_sink	false
runtime_filter_mode	OFF
enable_cte_materialize	false
experimental_topn_lazy_materialization_threshold	-1
file_split_size	1099511627776
max_file_split_size	67108864
max_initial_file_split_size	33554432
file_split_size_on_be	0
file_split_size_on_fe	1099511627776
max_file_scanners_concurrency	16
enable_file_scanner_v2	true
enable_fold_constant_by_be	false
enable_profile	false
query_timeout	3600
```

#### sirius-buffered (`log/bench/sf10-sirius-buffered`)

```
date: 2026-09-19T06:11:24Z
host: ip-172-31-67-209
instance_type: g4dn.2xlarge
kernel: 6.17.0-1017-aws
cpu: Intel(R) Xeon(R) Platinum 8259CL CPU @ 2.50GHz x 8
mem_total_kib: 32481256
gpu: Tesla T4, 15360 MiB, 580.178.04
system: sirius-buffered
data: /mnt/nvme/tpch_parquet_sf10 (3.6G) on /dev/nvme1n1   ext4
expected: /home/yy2/gpu/sirius/experimental/doris/tests/expected/tpch-sf10
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: 39c8945d docs(doris): SF10 benchmark shaken down on the T4 box — T0 results, plan decis
sirius_dirty: 2 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb ()
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
  d906329c74b4432503e35c2e9a06cc020650162c31f383e6449d0086655b1a65  log/bench/sf10-sirius-buffered/sirius.yaml
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	false	doris-4.1.4-rc04-ad35a140c7f
  127.0.0.1	9050	true	sirius-doris-be/0.1.0
-- session variables (GLOBAL) --
parallel_pipeline_task_num	1
experimental_enable_local_shuffle	false
enable_parallel_result_sink	false
runtime_filter_mode	OFF
enable_cte_materialize	false
experimental_topn_lazy_materialization_threshold	-1
file_split_size	1099511627776
max_file_split_size	67108864
max_initial_file_split_size	33554432
file_split_size_on_be	0
file_split_size_on_fe	1099511627776
max_file_scanners_concurrency	16
enable_file_scanner_v2	true
enable_fold_constant_by_be	false
enable_profile	false
query_timeout	3600
```

#### duckdb (`log/bench/sf10-duckdb`)

```
date: 2026-09-19T04:51:45Z
host: ip-172-31-67-209
instance_type: g4dn.2xlarge
kernel: 6.17.0-1017-aws
cpu: Intel(R) Xeon(R) Platinum 8259CL CPU @ 2.50GHz x 8
mem_total_kib: 32481256
gpu: Tesla T4, 15360 MiB, 580.178.04
system: duckdb
data: /mnt/nvme/tpch_parquet_sf10 (3.6G) on /dev/nvme1n1   ext4
expected: /home/yy2/gpu/sirius/experimental/doris/tests/expected/tpch-sf10
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: f7f3b396 docs(doris): benchmark plan — SF10 only to shake down on the T4 box, SF100 for
sirius_dirty: 21 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb (v1.5.5 (Variegata) 3ff87f1e)
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  af8ddac15bc86c1590130b5320297a52802b072a97f59506d464b07a8e141a00  sql/session.sql
  94660fca7a589535025c19443b183e9f45803e3de0b4283d05bb06f8afea716e  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	false	doris-4.1.4-rc04-ad35a140c7f
  127.0.0.1	9050	true	sirius-doris-be/0.1.0
```

#### duckdb-gpu (`log/bench/sf10-duckdb-gpu`)

```
date: 2026-09-19T06:17:49Z
host: ip-172-31-67-209
instance_type: g4dn.2xlarge
kernel: 6.17.0-1017-aws
cpu: Intel(R) Xeon(R) Platinum 8259CL CPU @ 2.50GHz x 8
mem_total_kib: 32481256
gpu: Tesla T4, 15360 MiB, 580.178.04
system: duckdb-gpu
data: /mnt/nvme/tpch_parquet_sf10 (3.6G) on /dev/nvme1n1   ext4
expected: /home/yy2/gpu/sirius/experimental/doris/tests/expected/tpch-sf10
rounds: 4 (evict before round 1: true)
queries: 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22
sirius_commit: 39c8945d docs(doris): SF10 benchmark shaken down on the T4 box — T0 results, plan decis
sirius_dirty: 3 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb (v1.5.5 (Variegata) 3ff87f1e)
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  ee2c4c64bc5869a0f198c6c50325c2533d659054bd597eff9b52ab8b17a222d4  sql/session.sql
  eb618adff0d106547610ad940548361363ae6ae1f6d35de4156863ca196f5e81  sql/session-native.sql
  6ab7149b230321f7f9629e5f0d244ead1c2698742be87ab945f1c93b67075876  sql/tpch-views.sql
  d5647d16e1bdf60012751f3612a0dc35ad6c7f85f01876bcdabc409d42543416  log/bench/sf10-duckdb-gpu/sirius.yaml
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	false	doris-4.1.4-rc04-ad35a140c7f
  127.0.0.1	9050	true	sirius-doris-be/0.1.0
```

