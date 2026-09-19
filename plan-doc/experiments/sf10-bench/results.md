# Doris vs Doris + Sirius · TPC-H SF10 · T0 结果（g4dn.2xlarge，2026-09-19）

> **这是 T0（跑通用）的数字，不是结论。** 机器：AWS g4dn.2xlarge = Tesla T4 16 GB（CC 7.5，Sirius 支持的下限，显存带宽 320 GB/s）、8 vCPU（4 物理核 Xeon 8259CL）、30 GB 内存、实例盘 NVMe 实测顺序读只有 **≈0.4 GB/s**（`dd iflag=direct` 单流 411 MB/s，4/8 流并发 357/318 MiB/s）。主结论要等 T1（g6e.4xlarge，L40S 48 GB / 16 vCPU / 128 GB）+ SF100，方法见 `plan.md`。
> 方法：同一个 FE 4.1.4、同一份 SF10 parquet（3.6 GB，一表一文件）、同一批 22 条 SQL（Doris tpch-tools 版）；每个系统 1 冷 + 3 热，热 = 中位数；每一轮的 22 个结果都过 DuckDB 基线校验（7 个系统 × 88 条全部 OK，Q1 的 `avg` 两边都差 1 ulp）。原始数据：`t0-g4dn/<system>/rounds.csv`（每轮每条的 wall / engine / FE 审计 / 采样），环境快照 `env.txt`，会话变量 `variables.txt`。跑法：`experimental/doris/README.md`「Benchmark」，一条 `bench-all.sh`。

## 1. 一眼看完（热跑，22 条合计，秒）

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

## 2. 怎么读这些数字

1. **主表口径 A-split vs B′：GPU 路径快 2.0～2.2×（几何平均 2.03×，power 总时间 2.22×）**，单条从 0.96×（Q22）到 4.73×（Q3）；扫描聚合型（Q1 4.02×、Q3 4.73×、Q13 3.05×、Q18 3.45×）领先最多，小结果/小表 join 型（Q2 1.10×、Q16 1.11×、Q22 0.96×）持平——和论文的趋势一致（Q1 类最大、Q6 类小），量级不能比（论文 4 节点 A100 + SF100）。对 stock 默认的 A 是 2.47×。
2. **B 的默认 O_DIRECT 在这台机器上是磁盘的成绩，不是引擎的**：每条查询都从盘重读它用到的列（一轮 22 条读 18 GB），实测有效读速 260～640 MB/s（Q6 读 604 MB 用 1.63 s；Q21 读 1.72 GB 用 6.5 s），与 `dd` 测出的 0.4 GB/s 一致。同一批查询走 page cache（B′）后引擎时间 Q6 0.42 s、Q9 1.21 s、Q21 2.71 s。**T1 机型要先 `dd iflag=direct` 量一下 NVMe**；SF100（25 GB）在 128 GB 内存的机器上 page cache 也放得下，B 与 B′ 都要跑。
3. **伪 BE 协议和 plan 形状的代价在 SF10 上可以忽略**：B（伪 BE）vs R2（Sirius 自己规划、同样 O_DIRECT）逐条几何平均 0.99×；B′ 的 wall − engine ≈ 150 ms/条（FE 规划 16～67 ms + RPC/取数），引擎时间占 wall 的 84 %（B 是 94 %）。SF1 时 FE 开销占一半以上，SF10 已经不是主项。
4. **T4 上的 Sirius ≈ 8 线程的 DuckDB**（B′ 21.0 s vs R1 17.1 s，几何平均 R1 快 1.30×）：这就是"T4 是下限"的意思——320 GB/s 的显存带宽和 CC 7.5，L40S 是它的 2.7 倍带宽。
5. **Doris 外表路径 ≠ Doris 主场**：内表（C）11.4 s，比外表 stock 快 4.6×，比 B′ 还快 1.84×（几何平均 2.34×）——分桶 + colocate join + 前缀索引/zone map（Q6 73 ms、Q3 205 ms）+ 列存直读，没有 parquet 解码。这一行不进主表，但读者一定会问；T1 上同样要跑。注意 C 必须关 FE 的 `enable_sql_cache`（4.1.4 默认开，重复查询 15 ms 命中缓存，第一次跑的热轮全是缓存，已重跑）。
6. **Doris 4.1.4 单文件外表的 stock 默认扫描并行度受限**（plan §10.12）：SF1 只有 1 个 scanner 干活，SF10 的 2.4 GB 文件被 FE 切成 5 段后能用 ≈4 核；`file_split_size_on_be = 0` 让 FE 切 32/64 MB → ≈6 核，22 条合计 52.0 → 46.7 s。Q1 仍要 3.9 s（6.6 核）——parquet 解码 + 聚合的 CPU 吞吐就是这样。
7. **显存够**：SF10 在 T4 的 13.5 GB 池子里没有触发 host/disk 降级（R2 日志 GPU 池高水位 11.2 GB，host 池 0.48 GB；telemetry 无 spill 事件）。plan §10.2 担心的 Q9/Q21 降级在 SF10 上没发生；SF100 会。
8. **资源**：B/B′ 进程 RSS ≈1.7 GB（不含 16 GiB 的 pinned host 池），CPU ≈1 核；A 4～6 核、RSS 2～8 GB（Q9/Q10 8 GB）；热跑时 A/B′/R1 的 `read_bytes` 为 0（全在 page cache），B/R2 每条 0.2～1.7 GB（O_DIRECT）。GPU 显存列是 RMM 预留的 13.5 GB，不是峰值（T1 要从 Quent telemetry 取每条查询的 tier 字节数）。
9. **T4 大部分时间是空的**（`nvidia-smi utilization.gpu` 按查询窗口取均值）：B′ 22 条的 GPU busy 中位数 **20 %**（Q22 66 %、Q1 47 %、Q10/Q21 36 %、Q13 32 %；Q2/Q6/Q12/Q14/Q19 ≈0 %），显存控制器忙 2～3 %；B 12 %、R2 14 %（盘在喂）。也就是说 SF10 在这台机器上引擎时间主要花在数据搬运和调度上（page cache → pinned host → PCIe 3.0 H2D、扫描元数据、4 个 pipeline 线程），不是 GPU 算——单换更快的 GPU 帮助有限，PCIe 4.0（L40S）、`enable_prefetch_cache`、`pin_table`（表常驻显存，R2 的 `-pinned` 行）才对症；也解释了为什么 T4 ≈ 8 线程 DuckDB。SF100 数据装不下显存时 host tier 的搬运会更重，T1 要看这两列。

## 3. 这次跑通过程中修掉的方法问题（都已进脚本）

- 伪 BE 注册在 FE 上会把原生 BE 的自动并行度压成 1（`bench.sh` 跑原生系统前 `DROPP BACKEND`）；
- 4.1.4 的两级文件切分在 SF10 上把 lineitem 切成 512 MB 段，伪 BE 拒绝（`session.sql` 钉 `file_split_size_on_be = 0`、`file_split_size_on_fe = 1 TB`）；
- FE 的 `enable_sql_cache` 默认开（三个 session 文件都关）；
- 原生 BE 的 `storage_root_path` 不能在 FE 见过它之后再变（FE 内部统计表的副本会变坏，连带内表查询规划失败）；本机 BE 现在挂两个 root；
- 刚 stop 的 BE 在 FE 上还 Alive 几秒，`be-native.sh` 现在 stop 等 `Alive=false`、start 等 pid 文件；
- 没有 BE alive 时 `SELECT 1` 都会失败，可达性检查用 `SHOW BACKENDS`。

## 4. 下一步（T1）

按 `plan.md` §8 步骤 10：g6e.4xlarge 上 `environment.md` 搭环境 → `bench-all.sh --data …sf10` 验证 → SF100（`tpchgen-cli -s 100`，基线到 NVMe）→ 7 个系统 + `duckdb-gpu-pinned`；T1′ c7i.12xlarge 只跑 `native`/`native-split`（`--price` 两台的价）。先量 NVMe 读速；`conf/sirius-bench.yaml` 的 host tier 自动按 RAM 算（128 GB → 114 GiB）。

---

以下为 `scripts/bench-report.py report` 自动生成的完整表（英文）。

# Doris vs Doris + Sirius · TPC-H SF10 · g4dn.2xlarge (T4, 8 vCPU) · 2026-09-19

Systems: `native` (4 round(s)), `native-split` (4 round(s)), `native-olap` (4 round(s)), `sirius` (4 round(s)), `sirius-buffered` (4 round(s)), `duckdb` (4 round(s)), `duckdb-gpu` (4 round(s)). Round 1 is cold (freshly started process, page cache evicted), the others hot; **hot** = median of the hot rounds, (min) in parentheses; ms of client round trip (`wall_ms`). Queries that did not validate against the DuckDB baseline in every round are marked and excluded from speedups and totals.

## Hot runs (median wall ms, min in parentheses)

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

## Cold run (round 1, wall ms)

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

## FE audit (hot medians, ms): fe = FE end-to-end, plan = Nereids planning, rpc1 = first exec RPC

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

## Resources (hot medians): peak RSS MiB / bytes read from disk MiB / CPU cores busy / GPU MiB in use / GPU busy % / GPU memory-controller busy %

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

## Environment

### native (`log/bench/sf10-native`)

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

### native-split (`log/bench/sf10-native-split`)

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

### native-olap (`log/bench/sf10-native-olap`)

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

### sirius (`log/bench/sf10-sirius`)

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

### sirius-buffered (`log/bench/sf10-sirius-buffered`)

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

### duckdb (`log/bench/sf10-duckdb`)

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

### duckdb-gpu (`log/bench/sf10-duckdb-gpu`)

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

