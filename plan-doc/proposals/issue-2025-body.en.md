<!-- Body of https://github.com/sirius-db/sirius/issues/2025 as updated on 2026-10-06 after mbrobbel's answers (the original version is in the issue's edit history). -->

### Describe the problem to solve or your goal to achieve

#1842 added `experimental/doris`, a backend process that joins an unmodified Apache Doris 4.1.4 FE, translates the plan fragments the FE dispatches into one Substrait plan, and runs it through `Context::execute_substrait`. TPC-H 22/22 validate on the GPU: at SF0.1 on the merged head, and at SF1, SF10 and SF100 on an L40S before the rebase, where SF100 took 154.4 s with Doris's own BE and 40.6 s with this backend.

#137 closed when #1842 merged; this issue tracks what comes next. What the backend cannot do yet (from #1842):

- **One node only.** Every fragment of a query must reach this one backend, which stitches them back into a single plan. Nothing runs across backends or GPUs.
- **One query at a time.** Results are materialized before they are encoded, and a running query cannot be interrupted: `execute_substrait` has no interrupt hook.
- **`local()` parquet only**, read as whole files: the session settings stop the FE from splitting files into byte ranges.
- **Translator refusals** (window functions, set operations, functions outside the allowlist, …) are listed in [`experimental/doris/docs/semantics-gaps.md`](https://github.com/sirius-db/sirius/blob/main/experimental/doris/docs/semantics-gaps.md).

The goal is to execute the FE's fragments as engine fragments and to run on several backends, one GPU each, on top of the engine's own exchange (#1807) and library API (#1728) as they land.

### Describe the solution you would like

_Updated 2026-10-06 after the [answers below](https://github.com/sirius-db/sirius/issues/2025#issuecomment-6015233132): no code sharing between the two backends for now, one GPU per backend, and the exchange goes through #1807. Step numbers are kept so the comments still line up._

1. **Re-measure on `main`.** A fresh SF100 run on current `main`, a run with the tables pinned in GPU memory, and a same-price CPU instance for a per-dollar figure. The benchmark harness that was split out of #1842 has been rebased onto `main` and will be proposed together with those numbers. The pinned run needs `pin_table` through the FFI (in #2016).
2. ~~**Several GPUs in one backend.**~~ Dropped: one GPU per backend (question 3).
3. **FE fragments as engine fragments, through #1807.** Once its operators and metadata are defined, the Doris translator maps `DATA_STREAM_SINK` to `ExchangeRel` and `EXCHANGE_NODE` to a `ReadRel`, and every FE fragment runs as its own plan instead of being stitched into one. The Doris side of the mapping is [on #1807](https://github.com/sirius-db/sirius/issues/1807#issuecomment-6017881212). The single-plan path stays as the fast path when one backend receives the whole query.
4. **Several backends, then several hosts**, one GPU per backend process, over the #1807 exchange. This also needs byte-range splits instead of whole files (#1696, #1700, also in #2016), per-process memory budgets, and `FrontendService.report`: until the backend reports a CPU count, the FE's automatic parallelism for Doris's own BEs drops to one instance per fragment while this backend is registered.
5. **Coverage**, alongside the steps above. Lift translator refusals as the engine gains operators: set operations (#1993, #1994), `GROUPING SETS` (#1991), cross products (#1968), window functions (#1802) and more functions (#1971, #1975). Add a TPC-DS translate-only corpus, and semantic regression tests in the `doris` CI job, as suggested in the #1842 review.
6. **Engine API, then later work.** Move the backend from the `ffi` APIs to the `sirius` crate on the #1728 API: cancellation and progress through its execution handle, and concurrent queries in one context (#1303). Later: streaming results, and offload inside a real Doris BE through `push_arrow` (#1590, #1965), the resource management API (#840) and the libsirius packages (#1734).

Not pursued after the discussion: moving the code the two backends have in common (engine actor, local exchange, row encoder) into a shared crate. The `sirius` crate built on the #1728 API is meant to cover what both backends need.

**Questions** (answered [below](https://github.com/sirius-db/sirius/issues/2025#issuecomment-6015233132))

1. Where should Rust code shared by the two backends live? Not now: the `sirius` crate will build on the #1728 API, and the `ffi` APIs stay until then.
2. Can the Rust `Fragment` wrapper and stream cardinality be split out of #2016 and land first? Open for @aocsa; no longer on the Doris critical path.
3. Is `Context::execute_substrait` expected to work with `topology.num_gpus > 1`? Yes, but not automatically in this setup, because it needs coordination with the streaming operators; use one GPU per backend.
4. Is an interrupt hook for a running `execute_substrait` or `Fragment::run` planned? Yes: a plan handed to a context returns a handle for progress and status, cancel and abort (#1728).
5. Will bounded concurrent admission (#2008) cover `ffi::Context`? Concurrent queries in one context are planned in #1303.

### Describe alternatives you have considered

- Building fragment execution and the exchange inside `experimental/doris`, on `ffi::Fragment` with a Rust-side exchange or a copy of the StarRocks one. Dropped: with the exchange in the engine (#1807), that code would be replaced.
- Several GPUs in one backend through `topology.num_gpus` on the single-plan path. Not pursued, see question 3.
- Going straight to several nodes. Running the FE fragments as separate plans on one backend first (step 3) tests exchange translation, two-phase aggregation and failure propagation without a network.

### Sirius component

Integrations

### Additional context

Earlier tracking issue: #137. Merged: #1840, #1841, #1842, #1791. Engine work this depends on: #1807, #1728, #1303, #2016, #1965, #1696, #1700, #840, #1734.

cc @felipeblazing @mbrobbel @aocsa
