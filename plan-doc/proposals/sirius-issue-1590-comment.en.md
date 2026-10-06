Hi Sirius community — greetings from Apache Doris! 👋 We have been following the streaming-fragment work with great interest, and this issue is exactly where our needs land, so we would like to share a proposal and get your thoughts.

**Context.** We are evaluating embedding Sirius *in-process* in the Doris BE as a GPU compute runtime: the BE keeps doing the scans (internal tables included) and the scheduling, translates the compute-heaviest subtree of a fragment to Substrait, hands it to Sirius, feeds the inputs into `sirius_stream_<id>` through the Arrow C Data Interface, and gets the results back as Arrow. The whole contract is Substrait + Arrow, and the host includes a single header.

This is complementary to the `origin/doris` experiment (a Rust pseudo-BE over `local()` parquet, the "prior art" in the exchange design doc): that route has Sirius stand in for a BE; this one puts Sirius inside the real BE, so it covers internal tables and reuses Doris's own scan / shuffle / runtime-filter machinery. It lands exactly on the gap this issue describes ("a genuinely remote sender cannot feed a fragment"), and it is the host-memory twin of the `push_packed` that #1644 adds at the same call site.

**Proposal: `Fragment::push_arrow` — an external Arrow input.**

Today `Fragment` only has `relay_from()`. #1644 (T5b) adds `push_packed()`, but that takes cudf-pack bytes already sitting in device memory plus cudf pack metadata — the right shape for NIXL exchange between Sirius nodes, but a CPU host has neither a device pointer nor a way to produce pack metadata. `push_arrow` would be the host-memory counterpart: same call site, same `session().push()`, different input format.

From reading the code, this is FFI-layer glue only; cuCascade does not need to change:

- `stream_session::push` is thread-safe and needs no DuckDB transaction; `STREAMING_SOURCE` is tier-agnostic (`get_next_task_input_data` is a pass-through, the upgrade happens in `lock_or_prepare_batch`), so pushing a GPU-tier batch is enough.
- `cudf::from_arrow_host(ArrowSchema const*, ArrowDeviceArray const*, stream, mr)` is already in the dependency closure (the cudf 26.06 vcpkg port brings nanoarrow 0.7.0) — it is just unused anywhere in the tree.
- Suggested signature, in the same `uintptr_t` style as `result_to_arrow` / `push_packed`, so the header still needs no Arrow headers:

```cpp
/// Import one host-memory Arrow record batch (Arrow C Data Interface) into input stream
/// `stream_id` as sender `sender_id`. Buffers are copied to the GPU before returning, so the
/// caller may release the Arrow structs immediately after. Does not close the sender — call
/// close_input(stream_id, sender_id) when the producer is done.
/// @throws before build(), on unknown stream id, schema mismatch, or after EOS.
void push_arrow(std::uint64_t stream_id, std::uint32_t sender_id,
                std::uintptr_t array_addr, std::uintptr_t schema_addr);
```

- The implementation mirrors `push_packed`: pick a GPU memory space → `acquire_stream()` → `make_reservation_or_null()` (the result-collector pattern, degrading when it fails) → wrap the caller's `ArrowArray` in an `ArrowDeviceArray{ARROW_DEVICE_CPU}` and hand it to `from_arrow_host` → reconcile against the declared stream schema (decimal width picked by precision as 32/64/128 with negated scale; bool bitmap → BOOL8; string offsets to INT64; reject dictionary, large_list, tz-aware timestamps and int128-shaped columns) → `stream.synchronize()` → `sirius::make_data_batch` → `session().push()`, throwing when it returns `false`, exactly like `relay_from`.
- We think the H2D copy is mandatory; pinning external host memory zero-copy does not fit the tier model (the HOST tier is addressed by offsets inside cuCascade-owned blocks, the host→GPU converter only reads those blocks, spill's `clone` assumes it owns the memory, and with no backpressure a queued batch may be moved to disk). It is the same choice `push_packed` makes with copy-out-on-arrival. Synchronize before returning, the caller frees right after — and Sirius threads never have to call back into the host.
- Rough size: ~150 lines of production code plus ~230 lines of tests (build the input with `cudf::to_arrow_host` → push → run → compare via `result_to_arrow`); zero changes in `stream_session` / `streaming_source` / cuCascade.
- Related: the result path today is four copies (D2H → DataChunk → ColumnDataCollection → Arrow); `cudf::to_arrow_host` could collapse it to one. A natural follow-up in the same direction.

**Two things we would like to align on:**

1. *Threading contract.* `push_packed` is legal "between `build()` and `run()`, exactly where `relay_from` sits", and #1644 states that the `Context` is single-threaded by contract. For a CPU host that means the whole input has to be materialized into the GPU/host tiers before execution starts — scan and compute cannot overlap. The underlying `batch_stream::push` is thread-safe, the S1 invariant exists for exactly this, and the multi-shot source (#836) was meant to be fed while running. We would like `push_arrow` to be explicitly allowed during `run()` from other threads: it only touches the `stream_session` (mutex-protected), not the DuckDB connection or the rest of the `Context` state. If you would rather settle that contract together with the `start()/join()` split, store-and-forward is a workable first step for us.
2. *Sequencing.* `sirius_ffi.{hpp,cpp}` is being reshaped by T5b; anything here should go on top of T5b (or the `stream/*` stack) rather than race it.

Feedback on the shape, and on point 1 in particular, would help us decide how to sequence this on our side. Happy to adjust to whatever T5b settles on.
