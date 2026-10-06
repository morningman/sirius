# 会议议程（精简版）· 2026-09-09 · Sirius × Doris

> 六个议题，建议 60 分钟。每项分「我说」和「我问」。
> 详版背景见 `meeting-2026-09-09.md`；事实核对于 2026-09-08。

---

## 开场（2 min）

「今天想过六件事：我们的方案和可行性、你们的排期和现状、能不能快速复刻一版 SR 那样的东西、
没有 GPU 怎么开发、开个 Slack 频道、以及你们接下来的宣传计划我们怎么一起参与。」

---

## 议题 1 · 我们的提案与可行性（10 min）

### 我说

**方案一句话**：在 Doris BE 进程内，把一个 fragment 里**最大的可翻译连续子树**换成一个算子——
子树进去是 **Substrait plan bytes**，出来是 **Arrow C Data Interface**。
Doris 的扫描、调度、shuffle、runtime filter、内存管理、错误处理全部原样保留；
Doris 侧只包含一个头文件，**Sirius 完全不知道 Doris 存在**。

**为什么不照搬 SR 的伪 CN**：Doris 用户的主力场景是内表，伪 BE 读不到 Doris 存储；
而且 Doris BE 的对外面（`PBackendService` 60+ RPC + AgentService + 心跳汇报 + runtime filter
merge/publish + load stream）比 StarRocks CN 厚得多。

**我们已经做了什么**：把真实的 `sirius.duckdb_extension` 预加载进真实的 `doris_be` 做符号绑定实测，
加 90 例合成矩阵。结论：**进程内可行**；唯一真实冲突面是 **libstdc++**
（protobuf / abseil / arrow 实测绑定数为 0）。

**需要你们侧的三样东西，合计 ≈1.3k 行，全在 FFI 和构建层，不动引擎内部**：

| | 规模 | 说明 |
|---|---|---|
| `Fragment::push_arrow(...)` | ~150 生产 + ~230 测试 | 纯 FFI 胶水；`cudf::from_arrow_host` 已在依赖闭包里，只是没人用；不动 cuCascade |
| libsirius 四条链接约束 | ~150–250 CMake/YAML | ① 全静态 + `-fvisibility=hidden` + `--exclude-libs,ALL` ② **`-static-libstdc++ -static-libgcc`** ③ version script 只导出 `sirius_*` ④ libgomp 静态、cuVS 可选 |
| C ABI `sirius_c.h` + shim | ~800 生产 | C++ 异常跨两套运行时**实测必崩**，所以是必需品不是优化 |

**证据（被质疑时给）**：Doris BE 导出 475,722 个符号（`ENABLE_EXPORTS`，为 native UDF 服务，
不会取消），其中静态 libstdc++ 50,662 个；真实产物预加载进去，**687 个符号绑到 BE，549 个是 libstdc++**。
所以**今天的 `sirius.duckdb_extension` 不能直接当 libsirius 用**。

**最重要的一句**：这些补丁**我们出人写，你们只需要 review**。

### 我问

1. 这个方案在你们看来可行吗？有没有我们没看到的坑？
2. 四条链接约束能接受成为交付标准吗？谁来 owner？
3. 我们提 PR，你们 review——可以吗？希望怎么拆？
4. **线程契约**（最关键的一条）：

> Can `push_arrow` be called during `run()`, from a thread other than the one that called
> `build()`? It only touches `stream_session`, which is mutex-protected — never the DuckDB
> connection or the rest of `Context`. If you'd rather settle that together with the
> `start()`/`join()` split, store-and-forward is workable for us, but we need to know which one
> to build against.

---

## 议题 2 · 前置工作的排期与现状（10 min）

### 我说（我们查到的现状，说出来让他们纠正）

- **#1590 的前置是 #1644**（T5b：`export_packed` / `push_packed` / `StagingArena`），
  draft，+17.5k 行，**8 月 27 日后没再动过**。
- #1590 列的四项——非阻塞 `run()` 的 `start()/join()` 拆分、`push`/`pull`/`wait`/`drained` 上 FFI、
  放开「同时只能有一个 fragment 在 build 和 run 之间」、`export_packed`/`push_packed` 移植——
  **据我们看都还没做**。
- **TPC-H：引擎侧看起来是全的**——`test/sql/tpch-sirius.test` 里 Q1–Q22 全在，有 answer CSV，
  没有 skip 标记；ClickBench 也是全套，你们文档说 8 月起领先 ClickBench 热跑。
- **但 StarRocks 的 deck 只报了 15 条。** 所以缺口看起来在集成层，不在引擎。

### 我问

1. **#1644 / T5b 现实的落地窗口是什么时候？** `push_arrow` 应该排在它之上、之下，还是可以独立提？
2. **引擎侧 22 条全过，StarRocks 只跑了 15 条——另外 7 条卡在哪？**
   是 plan 翻译、算子缺失，还是 DuckDB substrait 消费端的问题？
   *（这一条对我们特别重要：我们会撞上同一堵墙。）*
3. **并发**：一个 `Context` 同时只能跑一个 query（#1303）。对 benchmark 无所谓，
   但 Doris 是多租户并发系统，这是上线的硬门槛。#1583 那条线的时间表是？
4. 有没有一份公开的 roadmap 或里程碑？我们想把自己的排期挂上去。
5. 未来两个月你们团队的优先级排序是什么？（从外面看，StarRocks CN 那一摞把人都占满了）

---

## 议题 3 · 能不能在 Doris 上快速复刻一版 SR 的方式（15 min）★ 重点

### 我说 —— 开场直接把牌摊开

**这件事你们已经做过了。** `origin/doris` 分支，作者 mbrobbel，**231 个 commit，最后提交 2026-06-03**。
里面是一套完整的东西，不是 demo：

- `crates/`：`sirius-doris-be`（Rust 伪 BE）、`doris-thrift`、`doris-rpc`、`doris-proto`、
  `plan-translator`、`result-formatter`、`sirius-ffi`、`nixl-test`
- `docker/`：`docker-compose.yml`（Doris FE + Sirius BE）、`fe-custom.conf`、`sirius.yaml`
- `BUILD_DEPLOY_TEST_GUIDE.md`、`ARCHITECTURE.md`、`FINDINGS.md`

**`FINDINGS.md`（2026-02-26 的快照）里已经跑出了结果**：Doris FE 4.0.3 + Sirius BE，
TPC-H 走 `local()` TVF 读 parquet，**SF1 / SF10 / SF100 / SF1000（247 GB）都跑过**，
SF1 约 11 条 PASS。

**但有两个卡点，正是我们今天想问清楚的**：

1. **全程 `--force-cpu`。** GPU 管线在 Docker CDI 环境下起不来：
   `cudaMemcpyBatchAsync` 返回 `cudaErrorInvalidValue`，GPU 后台线程 SIGSEGV 把进程带走。
   所有查询都退回 DuckDB 的 `from_substrait` 在 CPU 上跑。
2. **剩下的失败大多不是 Sirius 的问题，是 duckdb-substrait 消费端的**：
   列序错（`Root.names` 顺序）、`ORDER BY` 丢失、`SetRel` 不支持 >2 输入、
   `count(DISTINCT)` 结果错、Q7/Q11/Q22 直接 hang。

所以我们的问题不是「能不能复刻」，而是「**为什么停了，重新启动它需要什么**」。
**我们可以出人做这件事。**

### 我问

1. **为什么 6 月停的？** 是优先级转移，还是撞上了什么硬问题？
2. 从 2 月的 FINDINGS 到 6 月最后一个 commit，**GPU 那条路后来跑通了吗？**
   `cudaMemcpyBatchAsync` 在 CDI 下的问题解决了没有？
3. StarRocks CN 这几个月新增的能力里——两阶段聚合、`EXCHANGE_NODE` 作为 stream 读、
   parquet byte-range 归属、common-expr slots、CLONE_EXPR 解包——**哪些是宿主无关、可以直接搬到
   Doris 侧的？** 哪些是纯 StarRocks 特有的？
4. **Doris 4.0.3-rc03 → 现在的 4.1.x / master，thrift 漂移有多大？** 我们可以评估并补齐。
5. **落在哪里？** 你们仓库的 `experimental/doris/`（和 `experimental/starrocks/` 对齐），
   还是我们这边？我们倾向前者——对齐已有结构，也让你们能 review。
6. **最小目标定成什么合适**：Doris FE + Sirius 伪 BE，TPC-H 在 **GPU** 上跑通 N 条，
   大概需要多久？我们能投入多少人配合？

### 一句必须说清的定位（避免社区误读）

> 「这条线对我们是**加速验证和 benchmark 的载体**，不是 Doris 的正式集成路径。
> 正式路径还是议题 1 那条（BE 进程内、覆盖内表）。两条并行，不互相替代。」

---

## 议题 4 · 没有 GPU 的开发环境推荐（5 min）

### 我说（先摆事实，问题就清楚了）

- `pixi.toml` 的平台只有 **linux-64 / linux-aarch64（CUDA 12 或 13）——macOS 完全不在支持列表里**。
  我这边是 Mac，所以只能进容器或用远程机器。
- **构建需要 CUDA toolkit，但不需要 GPU**：你们 CI 就是 `cpu-xl` 自托管 runner 构建、
  `gpu-2xt4` 跑测试。
- 仓库里**没有 Dockerfile / devcontainer**；但 `origin/doris` 的 `doris/docker/` 里有 compose。

### 我问

1. 没有 GPU 的开发者，你们推荐什么工作方式？**有没有官方的 dev 容器镜像**（或者能不能出一个）？
2. **linux-aarch64 容器**能完整构建吗（Mac 上跑 Docker Desktop）？你们内部有人这么干吗？
3. 哪些测试是纯 CPU 的？没有 GPU 的情况下，能跑到多少覆盖率？
4. **云上单卡开发机你们推荐哪家？** 你们 benchmark 用的是 massedcompute 的 A100×8（$13.25/hr），
   开发用的话有没有更便宜的推荐？
5. **能不能借一台，或者给我们 CI 的权限？** 外部贡献者的 PR 会跑 `gpu-2xt4` 吗？
   *（这是我们目前唯一的硬阻塞：ELF 层面的实验已经做完了，再往前每一步都要真 GPU。）*

---

## 议题 5 · 开一个 Slack 频道（2 min）

### 我说

你们 README 上就有 Slack 邀请链接，建议直接在 `sirius-db` 的 workspace 里开一个 **`#doris`** 频道。

- **谁进**：双方各 2–3 人
- **用途**：日常问答 + 双周同步（30 分钟就够）
- **一条规矩**：**重要结论回帖到 GitHub issue。** 口头和 Slack 里的共识两周就蒸发了

### 我问

- 有没有公开的 dev sync 会议我们可以旁听？
- 你们更希望技术讨论走 Slack 还是 GitHub issue？

---

## 议题 6 · 你们的宣传计划，以及我们怎么一起参与（8 min）

### 我问（这一段以听为主，先别急着提我们的方案）

1. **未来 1–2 个月，你们有哪些计划中的线上/线下活动？** GTC、NVIDIA 开发者活动、
   meetup、webinar、论文投稿？
2. **StarRocks 那条线打算什么时候公开？** 形式是什么——技术博客、发布会，还是 GTC session？
3. 有哪些是我们可以一起参与的？

### 我说（他们问「你们能出什么」时）

- **渠道**：Apache Doris 官网博客、公众号、`dev@doris.apache.org` 邮件列表、Doris Summit、
  中国区线下 meetup，以及一个很大的中文用户基座
- **形式建议**：**第一篇联合内容讲架构、不讲数字**——GPU 真跑通之前不出任何倍数。
  等有了数字，直接沿用你们 deck 里的框架（cost break-even 1.50×、逐查询对比、
  **包含跑输的查询**，你们 q01 是 1.14× 也照样放在图上——这个做法是对的，我们照抄）
- **可以主动提的两个**：
  - **GTC 2027**（3 月）：CFP 一般秋季开放，一个联合 session 是有 deadline 的强推力
  - **论文角度**：你们 `sirius-for-research.md` 里的 16 个开放问题，「计算下推」和
    「GPU-native I/O」正好覆盖我们的路线；**Doris 内表 GPU 直读**（GPU 解码真实生产 OLAP 存储格式 +
    MOW delete bitmap）是一个真论文题，UW-Madison 那边可能有兴趣

### 一条自己守住的红线

Doris 官方渠道的内容必须技术中立、不做厂商背书；不替对方承诺时间表。

---

## 收尾（3 min）· 行动项

| # | 事项 | Owner | 时间 |
|---|---|---|---|
| 1 | `push_arrow` 线程契约的书面结论（回到 #1590） | | |
| 2 | #1644 / T5b 的落地窗口 | | |
| 3 | libsirius 四条链接约束：谁 owner，走 issue 还是 PR | | |
| 4 | `origin/doris` 是否重启、落在哪、我们投多少人 | | |
| 5 | dev 容器镜像 / GPU 机器或 CI 权限 | | |
| 6 | `#doris` Slack 频道 + 双周同步时间 | | |
| 7 | 双方各自的宣传日历互通 | | |

**会后 24 小时内**：把口头结论在 #1590 上发一条公开总结——不写下来，两周后就没了。

---

## 一页速查（被问到数字时）

| | |
|---|---|
| 我们的实测 | 687 个符号绑到 BE（549 libstdc++）；protobuf/abseil/arrow = 0；Doris BE 导出 475,722 个符号 |
| Sirius 侧工作量 | push_arrow ~150+230 · C ABI ~800 · libsirius target ~150–250 · 合计 ≈1.3k 生产，2–3 工程周 |
| `origin/doris` | mbrobbel · 231 commits · 停在 2026-06-03 · TPC-H over parquet 到 SF1000 · 全程 `--force-cpu` |
| TPC-H | 引擎侧 Q1–Q22 全在测试里；StarRocks 集成只报 15 条 |
| 他们的数字 | SF500 · 8×A100 80GB · 4.43× · break-even 1.50× · q01 = 1.14×（跑输也照放） |
| 平台 | 只支持 linux-64 / linux-aarch64 + CUDA 12/13；**无 macOS**；构建不需要 GPU |
| CI | 构建 `cpu-xl`，测试 `gpu-2xt4`（self-hosted） |
| 运行要求 | glibc ≥ 2.28 · CC 7.5+ · CUDA 13.x（驱动 ≥580.65.06）或 12.x · io_uring · O_DIRECT |
