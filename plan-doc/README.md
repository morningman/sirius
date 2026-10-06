# Doris × Sirius GPU 卸载 — 项目文档空间

把 Apache Doris 接入 Sirius GPU 引擎的工程文档。**开工前先读 `handoff.md`。**

## 一句话

在 Doris BE 进程内做 fragment 子树卸载：Doris 继续负责扫描与调度，把计算最重的一段翻译成
Substrait 交给 Sirius 在 GPU 上跑，结果以 Arrow 回来。契约只有 Substrait 和 Arrow 两样。

## 文档职责

| 文档 | 回答什么问题 | 性质 |
|---|---|---|
| **[handoff.md](handoff.md)** | 现在做到哪了？下一步第一件事是什么？ | 🔄 活文档，**每次 session 结束必须更新** |
| **[tasklist.md](tasklist.md)** | 要做什么，什么顺序，怎么算做完？ | 🔄 活文档，勾选进度 |
| **[design.md](design.md)** | 为什么这么设计？架构长什么样？ | 📌 相对稳定，重大改动才动 |
| **[embeddability-study.md](embeddability-study.md)** | 把 Sirius 变成可嵌入运行时库要做多少事、风险在哪、值不值得？（P0 产出，含实测） | 📌 调研报告，结论进 ADR-010 |
| **[pseudo-be-feasibility.md](pseudo-be-feasibility.md)** | 照 `experimental/starrocks` 做 Doris 伪 BE（轨 1）要做多少事？SR 到哪了、社区/aocsa 在做什么、MVP 是什么？（2026-09-09） | 📌 调研报告，待 ADR-011 |
| **[doris-pseudo-be-plan.md](doris-pseudo-be-plan.md)** | 轨 1 怎么落地？怎么跑、两侧改什么、环境、P0→MVP-B 步骤与验收、待拍板项（2026-09-18） | 📌 执行方案，随进度小改 |
| **[experiments/](experiments/)** | P0.4 符号隔离实验的脚本与结果摘要（Docker 内复现，不需要 GPU） | 📚 可复现 |
| **[environment.md](environment.md)** | 代码在哪？怎么编？哪台机器能干什么？ | 📌 环境变化时更新 |
| **[decisions.md](decisions.md)** | 这个选择当初为什么这么定的？ | ➕ 只追加，不改写历史 |
| **[reference/doris-anatomy.md](reference/doris-anatomy.md)** | Doris 侧那段代码在哪个文件第几行？ | 📚 查阅 |
| **[reference/sirius-ffi.md](reference/sirius-ffi.md)** | Sirius 的接口怎么用？能力边界在哪？ | 📚 查阅 |
| **[reference/semantics-gaps.md](reference/semantics-gaps.md)** | 这个函数/类型能不能放行？ | 🔄 活文档，**发现一条加一条** |

## 阅读顺序

**第一次接手**（约 30 分钟）
1. `handoff.md` — 当前状态，5 分钟
2. `environment.md` — 尤其是「能在哪台机器上做什么」一节，5 分钟
3. `design.md` §0–§3 — 结论、事实基线、为什么是子树卸载、边界统一化，15 分钟
4. `tasklist.md` — 找到当前任务，5 分钟

**已经熟悉，日常开工**
1. `handoff.md` → 找到「下一步」
2. `tasklist.md` → 确认验收标准
3. 干活

**写翻译器时常开两个 tab**
`reference/doris-anatomy.md`（输入侧长什么样）+ `reference/semantics-gaps.md`（什么必须拒绝）

## 更新纪律

- **每次 session 结束**：更新 `handoff.md` 的「当前状态」「下一步」「已知坑」，勾掉 `tasklist.md` 里完成的项。这两件事不做，下一个 session 要重新摸索半小时。
- **做了架构级选择**：在 `decisions.md` 追加一条，写清「选了什么 / 为什么 / 放弃了什么」。不要改旧条目，要推翻就追加一条新的并标注取代关系。
- **发现语义差异**：立刻加进 `reference/semantics-gaps.md`。这份清单是 eligibility gate 的直接依据，漏一条就是一个可能跑出错误结果的查询。
- **`design.md` 是论证不是流水账**：实现细节的变动写进 handoff / tasklist，只有架构判断变了才改 design。

## 相关

- 分享页（设计概览，可发给团队）：https://claude.ai/code/artifact/a4470fd3-f870-42e1-98ca-b532af18a2d2
