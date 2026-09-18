# 挂到 sirius-db/sirius#1590 的评论 —— 中文 v3（review 后收敛版）

> **已发出**（2026-09-01，账号 morningman）：https://github.com/sirius-db/sirius/issues/1590#issuecomment-5494647357

> 2026-09-01 review 结论：点名 Doris；本条评论只提方案一（`push_arrow`）；不提拆 issue、不承诺 PR。
> 英文定稿见 `sirius-issue-1590-comment.en.md`。

---

Sirius 社区的各位好——来自 Apache Doris 的问候！👋 我们一直在关注 streaming fragment 这条线，这个 issue 正好是我们需求落点的地方，所以想分享一个提议、听听你们的想法。

**背景。** 我们在评估把 Sirius 作为 GPU 计算运行时**进程内**嵌入 Doris BE：BE 继续负责扫描（含内表）和调度，把 fragment 里计算最重的子树翻成 Substrait 交给 Sirius，输入通过 Arrow C Data Interface 喂进 `sirius_stream_<id>`，结果以 Arrow 回来。两边的契约只有 Substrait + Arrow，宿主只 include 一个头文件。

这和 `origin/doris` 分支的实验（Rust 伪 BE 读 `local()` parquet，exchange-design 里的 prior art）是互补的方向：那条路线让 Sirius 顶替一个 BE，这条让 Sirius 住进真实 BE，所以覆盖内表并复用 Doris 自己的扫描 / shuffle / runtime filter。它正好踩在本 issue 描述的缺口上（"a genuinely remote sender cannot feed a fragment"），也是 #1644 在同一调用位置加的 `push_packed` 的 host 内存孪生。

**提议：`Fragment::push_arrow` —— 外部 Arrow 输入口。**

今天 `Fragment` 只有 `relay_from()`。#1644（T5b）会加 `push_packed()`，但它吃的是已经在设备内存里的 cudf pack 字节 + cudf pack 元数据——对 Sirius 节点间的 NIXL 交换是对的形状，但一个 CPU 宿主既没有设备指针，也产不出 pack 元数据。`push_arrow` 是它的 host 内存对应物：同一个调用位置、同一个 `session().push()`，只是入口数据格式不同。

读代码后的结论：这只是 FFI 层的胶水，cuCascade 不需要动：

- `stream_session::push` 线程安全、不需要 DuckDB 事务；`STREAMING_SOURCE` 对 tier 无要求（`get_next_task_input_data` 是 pass-through，升级在 `lock_or_prepare_batch` 里做），推一个 GPU tier 的 batch 就够。
- `cudf::from_arrow_host(ArrowSchema const*, ArrowDeviceArray const*, stream, mr)` 已经在依赖闭包里（cudf 26.06 的 vcpkg port 带着 nanoarrow 0.7.0），只是仓库里一处都没用。
- 建议签名，沿用 `result_to_arrow` / `push_packed` 的 `uintptr_t` 风格，头文件仍不需要 Arrow 头：

```cpp
/// Import one host-memory Arrow record batch (Arrow C Data Interface) into input stream
/// `stream_id` as sender `sender_id`. Buffers are copied to the GPU before returning, so the
/// caller may release the Arrow structs immediately after. Does not close the sender — call
/// close_input(stream_id, sender_id) when the producer is done.
/// @throws before build(), on unknown stream id, schema mismatch, or after EOS.
void push_arrow(std::uint64_t stream_id, std::uint32_t sender_id,
                std::uintptr_t array_addr, std::uintptr_t schema_addr);
```

- 实现与 `push_packed` 平行：选一个 GPU memory space → `acquire_stream()` → `make_reservation_or_null()`（result collector 的模式，失败时降级）→ 把调用方的 `ArrowArray` 包进 `ArrowDeviceArray{ARROW_DEVICE_CPU}` 交给 `from_arrow_host` → 按声明的流 schema 对账（decimal 按 precision 选 32/64/128 并取负 scale；bool bitmap → BOOL8；string offsets 到 INT64；拒绝 dictionary、large_list、带时区的 timestamp、int128 形状的列）→ `stream.synchronize()` → `sirius::make_data_batch` → `session().push()`，返回 `false` 时抛错，和 `relay_from` 一致。
- 我们认为 H2D 拷贝是必须的；零拷贝 pin 外部 host 内存和 tier 模型不兼容（HOST tier 按 cuCascade 自有块内偏移寻址、host→GPU 转换器只读这些块、spill 的 `clone` 假设自有内存、没有背压意味着排队的 batch 可能被搬到 disk）。这和 `push_packed` 的 copy-out-on-arrival 是同一个选择。返回前同步、返回后调用方立即释放——Sirius 的线程永远不需要回调进宿主。
- 大致体量：≈150 行生产代码 + ≈230 行测试（`cudf::to_arrow_host` 造输入 → push → run → `result_to_arrow` 比对）；`stream_session` / `streaming_source` / cuCascade 零改动。
- 相关：结果路径今天是 4 次拷贝（D2H → DataChunk → ColumnDataCollection → Arrow），`cudf::to_arrow_host` 可以压成 1 次，是同一方向上自然的后续。

**两个想对齐的点：**

1. *线程契约。* `push_packed` 的合法区间是「build() 与 run() 之间，和 `relay_from` 同一位置」，#1644 也写明 `Context` is single-threaded by contract。对 CPU 宿主这意味着整段输入要先物化进 GPU/host tier 再开始执行——扫描和计算无法重叠。底层的 `batch_stream::push` 是线程安全的，S1 不变式就是为此存在的，多 shot source（#836）的初衷也是边跑边喂。我们希望 `push_arrow` 被明确允许在 `run()` 期间从其他线程调用：它只碰 `stream_session`（mutex 保护），不碰 DuckDB 连接和 `Context` 的其余状态。如果你们更希望把这个契约和 `start()/join()` 拆分一起定，store-and-forward 对我们也是可行的第一步。
2. *时序。* `sirius_ffi.{hpp,cpp}` 正被 T5b 重塑；这里的东西应该叠在 T5b（或 `stream/*` 栈）之上，而不是和它赛跑。

对这个形状、尤其是第 1 点的反馈，能帮我们决定后面怎么排。T5b 最终定成什么样，我们都可以照着调整。
