<!-- Posted 2026-10-06 as https://github.com/sirius-db/sirius/issues/2025#issuecomment-6017884989 (text below is exactly what was posted). -->

Thanks @mbrobbel, that answers most of it. Adjusting the plan:

- No code sharing between the two backends for now. The Doris backend stays on the `ffi` APIs and moves to the `sirius` crate once the #1728 API is ready.
- One GPU per backend, so step 2 (several GPUs in one backend) is dropped.
- Exchange: instead of building exchange handling into the Doris backend, steps 3 and 4 will follow #1807. Once its operators and metadata are defined, the Doris translator emits `ExchangeRel` / `ReadRel`. I've put the Doris side of the mapping on #1807.
- Cancellation and concurrency: the backend moves to the execution handle (#1728) and to concurrent queries (#1303) when they land.

I'll update the roadmap in the description. @aocsa, with the exchange moving into Sirius, question 2 is no longer on the Doris critical path.
