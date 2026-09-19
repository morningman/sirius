# Doris vs Doris + Sirius · TPC-H SF10 · T0 结果（g4dn.2xlarge，2026-09-19）

> **这是 T0（跑通用）的数字，不是结论。** 机器：AWS g4dn.2xlarge = Tesla T4 16 GB（CC 7.5，Sirius 支持的下限，显存带宽 320 GB/s）、8 vCPU（4 物理核 Xeon 8259CL）、30 GB 内存、实例盘 NVMe 实测顺序读只有 **≈0.4 GB/s**（`dd iflag=direct` 单流 411 MB/s，4/8 流并发 357/318 MiB/s）。主结论要等 T1（g6e.4xlarge，L40S 48 GB / 16 vCPU / 128 GB）+ SF100，方法见 `plan.md`。
> 方法：同一个 FE 4.1.4、同一份 SF10 parquet（3.6 GB，一表一文件）、同一批 22 条 SQL（Doris tpch-tools 版）；每个系统 1 冷 + 3 热，热 = 中位数；每一轮的 22 个结果都过 DuckDB 基线校验（7 个系统 × 88 条全部 OK，Q1 的 `avg` 两边都差 1 ulp）。原始数据：`t0-g4dn/<system>/rounds.csv`（每轮每条的 wall / engine / FE 审计 / 采样），环境快照 `env.txt`，会话变量 `variables.txt`。跑法：`experimental/doris/README.md`「Benchmark」，一条 `bench-all.sh`。

## 1. 一眼看完（热跑，22 条合计，秒）

| 系统 | 是什么 | 22 条合计 | 相对 A-split | 用了几个核 |
|---|---|---|---|---|
| **A `native`** | Doris 官方 BE 4.1.4，外表 `local()` 读 parquet，**stock 默认**会话变量 | **52.0** | 0.90× | ≈3.8 |
| **A-split `native-split`** | 同上，只多 `file_split_size_on_be = 0`（FE 侧切文件，plan §10.12） | **46.7** | 1× | ≈6.0 |
| C `native-olap` | Doris 内表（官方 DDL 分桶 + colocate + ANALYZE），Doris 主场 | **11.4** | 4.1× | — |
| **B `sirius`** | Doris + Sirius 伪 BE，Sirius 默认 **O_DIRECT** 直读 parquet | **54.5** | 0.86× | ≈1.0 |
| **B′ `sirius-buffered`** | 同上，`use_odirect: false` 走 page cache | **20.9** | **2.23×（几何平均 2.04×）** | ≈1.2 |
| R1 `duckdb` | DuckDB 1.5.5，8 线程，单进程 | 17.1 | 2.73× | ≈6.7 |
| R2 `duckdb-gpu` | Sirius 透明路径（DuckDB 规划、GPU 执行、O_DIRECT） | 54.3 | 0.86× | — |

冷跑（第 1 轮）合计：A 53.5、A-split 47.7、C 12.0、B 55.1、B′ 23.1、R1 18.6、R2 54.1——在这台机器上冷热差别不大（数据集 3.6 GB，NVMe 顺序读 0.4 GB/s，Doris 与 DuckDB 的解码/计算比读盘慢）。

## 2. 怎么读这些数字

1. **主表口径 A-split vs B′：GPU 路径快 2.0～2.2×（几何平均 2.04×，power 总时间 2.23×）**，单条从 0.96×（Q22）到 4.77×（Q3）；扫描聚合型（Q1 3.96×、Q3 4.77×、Q13 3.10×、Q18 3.49×）领先最多，小结果/小表 join 型（Q2 1.10×、Q16 1.12×、Q22 0.96×）持平——和论文的趋势一致（Q1 类最大、Q6 类小），量级不能比（论文 4 节点 A100 + SF100）。对 stock 默认的 A 是 2.49×。
2. **B 的默认 O_DIRECT 在这台机器上是磁盘的成绩，不是引擎的**：每条查询都从盘重读它用到的列（一轮 22 条读 18 GB），实测有效读速 258～641 MB/s（Q6 读 620 MB 用 1.64 s；Q21 读 1.69 GB 用 6.5 s），与 `dd` 测出的 0.4 GB/s 一致。同一批查询走 page cache（B′）后引擎时间 Q6 0.42 s、Q9 1.20 s、Q21 2.75 s。**T1 机型要先 `dd iflag=direct` 量一下 NVMe**；SF100（25 GB）在 128 GB 内存的机器上 page cache 也放得下，B 与 B′ 都要跑。
3. **伪 BE 协议和 plan 形状的代价在 SF10 上可以忽略**：B（伪 BE）vs R2（Sirius 自己规划、同样 O_DIRECT）逐条几何平均 0.99×；B′ 的 wall − engine ≈ 148 ms/条（FE 规划 16～67 ms + RPC/取数），引擎时间占 wall 的 84.5 %（B 是 93.9 %）。SF1 时 FE 开销占一半以上，SF10 已经不是主项。
4. **T4 上的 Sirius ≈ 8 线程的 DuckDB**（B′ 20.9 s vs R1 17.1 s，几何平均 R1 快 1.28×）：这就是"T4 是下限"的意思——320 GB/s 的显存带宽和 CC 7.5，L40S 是它的 2.7 倍带宽。
5. **Doris 外表路径 ≠ Doris 主场**：内表（C）11.4 s，比外表 stock 快 4.6×，比 B′ 还快 1.84×（几何平均 2.32×）——分桶 + colocate join + 前缀索引/zone map（Q6 73 ms、Q3 205 ms）+ 列存直读，没有 parquet 解码。这一行不进主表，但读者一定会问；T1 上同样要跑。注意 C 必须关 FE 的 `enable_sql_cache`（4.1.4 默认开，重复查询 15 ms 命中缓存，第一次跑的热轮全是缓存，已重跑）。
6. **Doris 4.1.4 单文件外表的 stock 默认扫描并行度受限**（plan §10.12）：SF1 只有 1 个 scanner 干活，SF10 的 2.4 GB 文件被 FE 切成 5 段后能用 ≈4 核；`file_split_size_on_be = 0` 让 FE 切 32/64 MB → ≈6 核，22 条合计 52.0 → 46.7 s。Q1 仍要 3.9 s（6.6 核）——parquet 解码 + 聚合的 CPU 吞吐就是这样。
7. **显存够**：SF10 在 T4 的 13.5 GB 池子里没有触发 host/disk 降级（R2 日志 GPU 池高水位 11.2 GB，host 池 0.48 GB；telemetry 无 spill 事件）。plan §10.2 担心的 Q9/Q21 降级在 SF10 上没发生；SF100 会。
8. **资源**：B/B′ 进程 RSS ≈1.7 GB（不含 16 GiB 的 pinned host 池），CPU ≈1 核；A 4～6 核、RSS 2～8 GB（Q9/Q10 8 GB）；热跑时 A/B′/R1 的 `read_bytes` 为 0（全在 page cache），B/R2 每条 0.2～1.7 GB（O_DIRECT）。GPU 显存列是 RMM 预留的 13.5 GB，不是峰值（T1 要从 Quent telemetry 取每条查询的 tier 字节数）。

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
| q01 | 4,641 (4,617) | 3,919 (3,916) | 2,505 (2,126) | 1,041 (1,038) | 989 (986) | 1,067 (1,049) | 1,262 (1,254) | **3.96×** | 904 |  |
| q02 | 1,627 (1,588) | 644 (637) | 262 (208) | 605 (598) | 583 (581) | 176 (171) | 665 (653) | **1.10×** | 292 |  |
| q03 | 3,646 (3,521) | 3,731 (3,730) | 205 (163) | 2,820 (2,808) | 782 (771) | 808 (804) | 2,937 (2,936) | **4.77×** | 676 |  |
| q04 | 1,698 (1,665) | 1,626 (1,561) | 377 (322) | 1,388 (1,386) | 616 (585) | 532 (530) | 1,452 (1,449) | **2.64×** | 542 |  |
| q05 | 2,425 (2,360) | 2,521 (2,513) | 515 (413) | 3,322 (3,315) | 1,107 (1,097) | 807 (795) | 3,355 (3,345) | **2.28×** | 929 |  |
| q06 | 1,418 (1,362) | 1,267 (1,261) | 73 (67) | 1,691 (1,685) | 468 (467) | 410 (406) | 1,794 (1,788) | **2.71×** | 420 |  |
| q07 | 2,662 (2,557) | 1,895 (1,889) | 362 (284) | 3,627 (3,598) | 1,198 (1,171) | 712 (701) | 3,502 (3,498) | **1.58×** | 995 |  |
| q08 | 2,994 (2,862) | 2,073 (2,057) | 709 (645) | 4,632 (4,616) | 1,486 (1,459) | 885 (869) | 4,574 (4,567) | **1.40×** | 1,217 |  |
| q09 | 3,637 (3,590) | 3,787 (3,785) | 907 (780) | 4,782 (4,703) | 1,400 (1,396) | 1,701 (1,644) | 4,869 (4,865) | **2.71×** | 1,196 |  |
| q10 | 2,430 (2,430) | 2,475 (2,447) | 616 (559) | 2,788 (2,788) | 969 (964) | 907 (871) | 2,807 (2,795) | **2.55×** | 829 |  |
| q11 | 1,045 (1,025) | 665 (655) | 336 (304) | 683 (669) | 541 (537) | 270 (270) | 816 (813) | **1.23×** | 237 |  |
| q12 | 1,600 (1,552) | 1,281 (1,281) | 278 (250) | 1,576 (1,573) | 673 (671) | 618 (606) | 1,626 (1,625) | **1.90×** | 585 |  |
| q13 | 3,619 (3,615) | 1,422 (1,402) | 1,054 (972) | 1,705 (1,650) | 458 (458) | 1,149 (1,133) | 1,632 (1,630) | **3.10×** | 397 |  |
| q14 | 1,218 (1,201) | 1,219 (1,217) | 91 (90) | 2,601 (2,597) | 726 (705) | 575 (564) | 2,793 (2,792) | **1.68×** | 642 |  |
| q15 | 2,378 (2,084) | 2,578 (2,536) | 206 (193) | 2,536 (2,536) | 1,133 (1,131) | 476 (475) | 2,514 (2,513) | **2.28×** | 1,006 |  |
| q16 | 565 (560) | 345 (330) | 328 (313) | 355 (328) | 307 (304) | 238 (228) | 247 (246) | **1.12×** | 184 |  |
| q17 | 2,494 (2,452) | 3,088 (3,048) | 140 (140) | 3,475 (3,467) | 1,067 (1,067) | 653 (651) | 3,723 (3,719) | **2.89×** | 958 |  |
| q18 | 3,785 (3,724) | 4,620 (4,611) | 870 (853) | 2,239 (2,226) | 1,325 (1,320) | 1,360 (1,355) | 2,315 (2,313) | **3.49×** | 1,177 |  |
| q19 | 1,737 (1,710) | 1,504 (1,501) | 237 (233) | 2,756 (2,743) | 766 (745) | 722 (710) | 2,831 (2,814) | **1.96×** | 659 |  |
| q20 | 1,557 (1,509) | 1,499 (1,491) | 199 (186) | 2,768 (2,748) | 948 (939) | 584 (574) | 2,787 (2,770) | **1.58×** | 769 |  |
| q21 | 4,078 (4,004) | 4,127 (4,090) | 915 (872) | 6,756 (6,720) | 2,964 (2,881) | 2,202 (2,127) | 5,444 (5,441) | **1.39×** | 2,748 |  |
| q22 | 755 (743) | 365 (337) | 183 (176) | 393 (388) | 382 (381) | 269 (268) | 380 (371) | **0.96×** | 277 |  |
| **power total** | **52,009** (22 q) | **46,651** (22 q) | **11,368** (22 q) | **54,539** (22 q) | **20,888** (22 q) | **17,121** (22 q) | **54,325** (22 q) | **geomean 2.04×**, total 2.23× | 17,641 |  |

Cost-normalized (plan §7): native-split at $0.752/h vs sirius-buffered at $0.752/h → geomean speedup per dollar **2.04×**.

## Cold run (round 1, wall ms)

| q | native | native-split | native-olap | sirius | sirius-buffered | duckdb | duckdb-gpu |
|---|---|---|---|---|---|---|---|
| q01 | 5,057 | 4,334 | 2,852 | 1,827 | 1,979 | 1,257 | 1,230 |
| q02 | 1,864 | 738 | 345 | 713 | 738 | 440 | 456 |
| q03 | 3,860 | 3,904 | 441 | 2,378 | 938 | 1,461 | 2,916 |
| q04 | 1,772 | 1,591 | 490 | 1,529 | 761 | 596 | 1,490 |
| q05 | 2,604 | 2,591 | 665 | 3,238 | 1,198 | 873 | 3,322 |
| q06 | 1,332 | 1,238 | 76 | 1,667 | 503 | 410 | 1,767 |
| q07 | 2,634 | 1,944 | 304 | 3,640 | 1,182 | 735 | 3,524 |
| q08 | 2,986 | 2,132 | 695 | 4,666 | 1,626 | 979 | 4,585 |
| q09 | 3,654 | 3,805 | 790 | 4,806 | 1,426 | 1,757 | 4,871 |
| q10 | 2,550 | 2,530 | 606 | 2,772 | 1,031 | 914 | 2,797 |
| q11 | 1,094 | 694 | 306 | 705 | 576 | 284 | 832 |
| q12 | 1,600 | 1,250 | 263 | 1,579 | 747 | 614 | 1,599 |
| q13 | 3,947 | 1,464 | 992 | 1,646 | 584 | 1,195 | 1,660 |
| q14 | 1,197 | 1,226 | 88 | 2,647 | 696 | 566 | 2,767 |
| q15 | 2,327 | 2,533 | 204 | 2,576 | 1,156 | 496 | 2,532 |
| q16 | 591 | 341 | 311 | 399 | 376 | 247 | 309 |
| q17 | 2,420 | 3,158 | 139 | 3,393 | 1,084 | 662 | 3,649 |
| q18 | 3,855 | 4,604 | 944 | 2,244 | 1,398 | 1,385 | 2,315 |
| q19 | 1,647 | 1,541 | 235 | 2,757 | 809 | 727 | 2,844 |
| q20 | 1,540 | 1,559 | 188 | 2,762 | 945 | 584 | 2,774 |
| q21 | 4,193 | 4,211 | 940 | 6,756 | 2,952 | 2,177 | 5,434 |
| q22 | 765 | 332 | 171 | 409 | 394 | 269 | 388 |
| **total** | 53,489 | 47,720 | 12,045 | 55,109 | 23,099 | 18,628 | 54,061 |

## FE audit (hot medians, ms): fe = FE end-to-end, plan = Nereids planning, rpc1 = first exec RPC

| q | native fe / plan / rpc1 | native-split fe / plan / rpc1 | native-olap fe / plan / rpc1 | sirius fe / plan / rpc1 | sirius-buffered fe / plan / rpc1 |
|---|---|---|---|---|---|
| q01 | 4,626 / 27 / 3 | 3,905 / 26 / 5 | 2,111 / -1 / 10 | 1,028 / 17 / 1,008 | 975 / 16 / 957 |
| q02 | 1,612 / 71 / 10 | 630 / 69 / 11 | 194 / 16 / 12 | 590 / 65 / 521 | 569 / 59 / 506 |
| q03 | 3,632 / 42 / 5 | 3,717 / 44 / 7 | 189 / 9 / 20 | 2,805 / 32 / 2,771 | 769 / 30 / 737 |
| q04 | 1,683 / 36 / 4 | 1,611 / 35 / 5 | 359 / 6 / 18 | 1,374 / 25 / 1,345 | 602 / 25 / 574 |
| q05 | 2,409 / 62 / 7 | 2,507 / 63 / 10 | 399 / 29 / 21 | 3,308 / 49 / 3,254 | 1,093 / 50 / 1,042 |
| q06 | 1,403 / 26 / 2 | 1,254 / 26 / 3 | 59 / 4 / 3 | 1,677 / 16 / 1,658 | 453 / 15 / 436 |
| q07 | 2,647 / 69 / 8 | 1,882 / 61 / 10 | 347 / 31 / 32 | 3,612 / 52 / 3,557 | 1,185 / 51 / 1,129 |
| q08 | 2,978 / 76 / 9 | 2,058 / 72 / 11 | 694 / 67 / 26 | 4,618 / 62 / 4,547 | 1,472 / 62 / 1,407 |
| q09 | 3,622 / 65 / 8 | 3,773 / 61 / 9 | 766 / 30 / 21 | 4,768 / 51 / 4,717 | 1,386 / 46 / 1,336 |
| q10 | 2,416 / 53 / 6 | 2,460 / 50 / 8 | 308 / -1 / 9 | 2,775 / 37 / 2,735 | 956 / 36 / 913 |
| q11 | 987 / 47 / 8 | 607 / 46 / 9 | 246 / 12 / 12 | 621 / 43 / 542 | 480 / 37 / 410 |
| q12 | 1,585 / 37 / 5 | 1,266 / 37 / 6 | 263 / 8 / 22 | 1,562 / 26 / 1,531 | 657 / 25 / 630 |
| q13 | 3,605 / 21 / 6 | 1,400 / 19 / 6 | 957 / 6 / 10 | 1,691 / 18 / 1,670 | 445 / 16 / 425 |
| q14 | 1,204 / 38 / 4 | 1,206 / 35 / 5 | 77 / 6 / 6 | 2,585 / 26 / 2,555 | 712 / 25 / 684 |
| q15 | 2,365 / 61 / 5 | 2,563 / 62 / 7 | 178 / 12 / 10 | 2,523 / 41 / 2,477 | 1,119 / 37 / 1,078 |
| q16 | 535 / 27 / 6 | 316 / 25 / 8 | 299 / 9 / 11 | 327 / 25 / 293 | 277 / 23 / 245 |
| q17 | 2,477 / 59 / 5 | 3,074 / 57 / 7 | 126 / 8 / 5 | 3,461 / 41 / 3,416 | 1,054 / 37 / 1,013 |
| q18 | 3,772 / 67 / 6 | 4,606 / 70 / 9 | 856 / 13 / 27 | 2,226 / 44 / 2,179 | 1,312 / 41 / 1,267 |
| q19 | 1,722 / 41 / 6 | 1,489 / 39 / 5 | 221 / 14 / 7 | 2,740 / 29 / 2,709 | 751 / 27 / 722 |
| q20 | 1,541 / 58 / 8 | 1,484 / 57 / 9 | 183 / 13 / 14 | 2,754 / 44 / 2,705 | 933 / 40 / 877 |
| q21 | 4,063 / 104 / 8 | 4,113 / 103 / 13 | 901 / 40 / 34 | 6,742 / 67 / 6,666 | 2,948 / 66 / 2,872 |
| q22 | 740 / 32 / 6 | 350 / 31 / 7 | 161 / 10 / 11 | 379 / 28 / 347 | 368 / 28 / 338 |

## Resources (hot medians): peak RSS MiB / bytes read from disk MiB / CPU cores busy / peak GPU MiB

| q | native | native-split | native-olap | sirius | sirius-buffered | duckdb | duckdb-gpu |
|---|---|---|---|---|---|---|---|
| q01 | 1,927 / 0 / 4.1 / - | 3,309 / 0 / 6.6 / - | 6,905 / 1 / 6.4 / - | 1,699 / 613 / 1.4 / 13,583 | 1,694 / 0 / 1.6 / 13,583 | 662 / 0 / 6.6 / - | 1,358 / 746 / 2.0 / 13,567 |
| q02 | 1,921 / 0 / 1.4 / - | 3,217 / 0 / 4.6 / - | 6,905 / 0 / 4.4 / - | 1,699 / 285 / 1.1 / 13,583 | 1,694 / 0 / 1.2 / 13,583 | 662 / 0 / 6.3 / - | 1,392 / 338 / 1.0 / 13,569 |
| q03 | 3,673 / 0 / 3.8 / - | 4,703 / 0 / 5.2 / - | 6,905 / 0 / 4.6 / - | 1,699 / 1,119 / 0.4 / 13,583 | 1,699 / 0 / 1.1 / 13,583 | 662 / 0 / 6.7 / - | 1,399 / 986 / 0.3 / 13,573 |
| q04 | 3,752 / 0 / 4.0 / - | 4,813 / 0 / 5.8 / - | 6,905 / 0 / 5.0 / - | 1,695 / 455 / 0.6 / 13,583 | 1,699 / 0 / 1.0 / 13,583 | 690 / 0 / 6.8 / - | 1,478 / 685 / 0.6 / 13,575 |
| q05 | 3,752 / 0 / 4.1 / - | 4,813 / 0 / 5.8 / - | 6,993 / 1 / 5.4 / - | 1,739 / 1,085 / 0.5 / 13,583 | 1,728 / 0 / 1.2 / 13,583 | 691 / 0 / 6.7 / - | 1,500 / 1,194 / 0.4 / 13,575 |
| q06 | 2,871 / 0 / 3.1 / - | 4,042 / 0 / 6.8 / - | 6,993 / 0 / 5.0 / - | 1,739 / 620 / 0.5 / 13,583 | 1,728 / 0 / 1.3 / 13,583 | 691 / 0 / 6.8 / - | 1,500 / 631 / 0.5 / 13,575 |
| q07 | 2,322 / 0 / 2.8 / - | 3,526 / 0 / 6.4 / - | 7,088 / 0 / 5.0 / - | 1,712 / 1,108 / 0.5 / 13,583 | 1,728 / 0 / 1.3 / 13,583 | 798 / 0 / 6.7 / - | 1,530 / 1,367 / 1.1 / 13,575 |
| q08 | 2,692 / 0 / 3.5 / - | 3,333 / 0 / 6.5 / - | 7,247 / 0 / 5.4 / - | 1,741 / 1,410 / 0.5 / 13,583 | 1,727 / 0 / 1.2 / 13,583 | 924 / 0 / 6.5 / - | 1,549 / 1,520 / 0.3 / 13,575 |
| q09 | 6,316 / 0 / 5.0 / - | 8,162 / 0 / 6.2 / - | 7,438 / 0 / 6.2 / - | 1,741 / 1,471 / 0.5 / 13,583 | 1,727 / 0 / 1.2 / 13,583 | 1,766 / 0 / 7.2 / - | 1,549 / 1,703 / 0.3 / 13,575 |
| q10 | 6,316 / 0 / 4.0 / - | 8,162 / 0 / 5.5 / - | 7,438 / 0 / 5.9 / - | 1,731 / 1,012 / 0.5 / 13,583 | 1,727 / 0 / 1.1 / 13,583 | 1,766 / 0 / 6.5 / - | 1,545 / 1,037 / 0.5 / 13,577 |
| q11 | 4,083 / 0 / 2.4 / - | 5,678 / 0 / 5.0 / - | 7,410 / 0 / 5.0 / - | 1,697 / 235 / 0.8 / 13,583 | 1,696 / 0 / 0.9 / 13,583 | 1,431 / 0 / 5.4 / - | 1,587 / 502 / 0.6 / 13,579 |
| q12 | 3,018 / 0 / 3.1 / - | 4,472 / 0 / 6.3 / - | 7,245 / 0 / 5.7 / - | 1,710 / 783 / 0.6 / 13,583 | 1,698 / 0 / 1.1 / 13,583 | 1,366 / 0 / 6.4 / - | 1,587 / 732 / 0.4 / 13,579 |
| q13 | 2,497 / 0 / 2.0 / - | 3,673 / 0 / 6.5 / - | 7,245 / 0 / 6.2 / - | 1,710 / 560 / 0.5 / 13,583 | 1,698 / 0 / 1.3 / 13,583 | 1,115 / 0 / 7.2 / - | 1,562 / 686 / 0.3 / 13,579 |
| q14 | 1,981 / 0 / 3.7 / - | 3,059 / 0 / 6.6 / - | 7,034 / 0 / 5.3 / - | 1,720 / 909 / 0.5 / 13,583 | 1,698 / 0 / 1.4 / 13,583 | 1,115 / 0 / 6.9 / - | 1,593 / 1,089 / 0.4 / 13,579 |
| q15 | 2,047 / 0 / 5.2 / - | 3,339 / 0 / 6.8 / - | 7,034 / 0 / 5.1 / - | 1,742 / 915 / 0.6 / 13,583 | 1,723 / 0 / 1.1 / 13,583 | 1,097 / 0 / 6.6 / - | 1,596 / 862 / 0.5 / 13,579 |
| q16 | 2,029 / 0 / 2.8 / - | 3,339 / 0 / 4.9 / - | 7,244 / 0 / 5.0 / - | 1,742 / 90 / 1.0 / 13,583 | 1,723 / 0 / 1.0 / 13,583 | 1,013 / 0 / 6.6 / - | 1,712 / 347 / 1.1 / 13,583 |
| q17 | 2,416 / 0 / 6.1 / - | 4,238 / 0 / 6.4 / - | 7,244 / 0 / 4.9 / - | 1,759 / 1,183 / 0.4 / 13,583 | 1,735 / 0 / 1.1 / 13,583 | 925 / 0 / 6.7 / - | 1,712 / 1,183 / 1.2 / 13,583 |
| q18 | 6,379 / 0 / 4.6 / - | 8,424 / 0 / 4.8 / - | 8,066 / 0 / 6.1 / - | 1,761 / 788 / 0.8 / 13,583 | 1,749 / 0 / 1.3 / 13,583 | 1,349 / 0 / 7.2 / - | 1,680 / 1,017 / 0.6 / 13,583 |
| q19 | 6,348 / 0 / 3.5 / - | 8,276 / 0 / 5.8 / - | 8,066 / 0 / 5.4 / - | 1,755 / 982 / 0.5 / 13,583 | 1,749 / 0 / 1.5 / 13,583 | 1,349 / 0 / 7.1 / - | 1,681 / 1,037 / 1.3 / 13,583 |
| q20 | 5,042 / 0 / 4.2 / - | 5,636 / 0 / 6.0 / - | 8,224 / 0 / 4.5 / - | 1,705 / 857 / 0.4 / 13,583 | 1,731 / 0 / 1.1 / 13,583 | 955 / 0 / 6.7 / - | 1,776 / 989 / 0.5 / 13,583 |
| q21 | 3,167 / 0 / 4.2 / - | 4,575 / 0 / 6.8 / - | 8,178 / 0 / 5.3 / - | 1,773 / 1,687 / 0.7 / 13,583 | 1,777 / 0 / 1.4 / 13,583 | 1,025 / 0 / 6.7 / - | 1,776 / 1,844 / 1.2 / 13,583 |
| q22 | 2,359 / 0 / 1.4 / - | 4,341 / 0 / 4.4 / - | 7,702 / 0 / 3.5 / - | 1,773 / 152 / 0.9 / 13,583 | 1,777 / 0 / 0.8 / 13,583 | 944 / 0 / 5.3 / - | 1,687 / 152 / 1.1 / 13,583 |

Bytes read from disk = `/proc/<pid>/io read_bytes` delta over the query (0 on a page-cache hit; O_DIRECT reads always count); sampled every 0.5 s, so sub-second queries are attributed approximately.

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
date: 2026-09-19T05:08:22Z
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
sirius_commit: f7f3b396 docs(doris): benchmark plan — SF10 only to shake down on the T4 box, SF100 for
sirius_dirty: 21 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb ()
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  af8ddac15bc86c1590130b5320297a52802b072a97f59506d464b07a8e141a00  sql/session.sql
  94660fca7a589535025c19443b183e9f45803e3de0b4283d05bb06f8afea716e  sql/session-native.sql
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
date: 2026-09-19T05:12:52Z
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
sirius_commit: f7f3b396 docs(doris): benchmark plan — SF10 only to shake down on the T4 box, SF100 for
sirius_dirty: 21 file(s)
doris_version: 4.1.4
duckdb_shell: /home/yy2/gpu/sirius/build/release/duckdb ()
config_hashes:
  ef763a6b618d13d6dd933576dc62e09460ca39b38e8a98164e5e2969d24fe2da  conf/be.conf
  d7dad09773fa92d2f80b6945caec3e964e2e83606ce83fa0e9df652782b7d60e  conf/sirius-bench.yaml
  da36e00e1377b133dd79e08903445c7c1cd259160c9c138867803811c761e6a5  conf/fe.conf
  af8ddac15bc86c1590130b5320297a52802b072a97f59506d464b07a8e141a00  sql/session.sql
  94660fca7a589535025c19443b183e9f45803e3de0b4283d05bb06f8afea716e  sql/session-native.sql
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
date: 2026-09-19T04:53:31Z
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
  d5647d16e1bdf60012751f3612a0dc35ad6c7f85f01876bcdabc409d42543416  log/bench/sf10-duckdb-gpu/sirius.yaml
backends:
  Host	HeartbeatPort	Alive	Version
  127.0.0.1	9150	false	doris-4.1.4-rc04-ad35a140c7f
  127.0.0.1	9050	false	sirius-doris-be/0.1.0
```

