# Doris ↔ Sirius 语义差异清单

> 🔄 **活文档。发现一条加一条，同一个 commit 里补上 gate 判定和负向单测。**

这份清单是 eligibility gate 的**直接依据**。因为执行期不回退（`../decisions.md` ADR-005），
漏一条 = 一个会失败或跑出错误结果的查询。

## 处置图例

| 标记 | 含义 |
|---|---|
| 🔴 **硬拒绝** | 放行会产生**错误结果**（不是报错）。最高优先级 |
| ⛔ 拒绝 | Sirius 不支持，放行会抛错 |
| ⚠️ 条件放行 | 满足特定约束才翻译 |
| ❓ 待验证 | 怀疑有差异，尚未用差分测试确认。**验证前一律拒绝** |

---

## 已确认

| # | 主题 | Doris 行为 | DuckDB / Sirius 行为 | 处置 | 出处 |
|---|---|---|---|---|---|
| G-01 | `LARGEINT` (int128) | 精确 128 位 | 映射 INT64，**静默截断** | 🔴 硬拒绝 | `sirius/src/include/cudf/cudf_utils.hpp:169` |
| G-02 | `concat` 遇 NULL | 返回 NULL（NULL-strict） | `concat()` 忽略 NULL 参数；但 `\|\|` 算子（Sirius `concat_operator`）传播 NULL | 🔴 硬拒绝（已做：`expr_translator.rs` 指名拒绝）。将来要放行的话映射成两两嵌套的 `\|\|`，不是 `concat` | `starrocks-plan-translator/src/expr_translator.rs:552`；`sirius/src/expression/function_id.cpp` 的 `concat`/`\|\|` 两条 |
| G-03 | `LIKE` 转义 | 反斜杠为默认转义符 | GPU 求值器不处理转义；DuckDB `LIKE` 无 `ESCAPE` 时也不转义 | ⚠️ 仅当模式是常量且不含 `\`（已做，负向单测） | 同上 :515 |
| G-04 | `substring` | 支持负起点、两参形式、`pos=0` 返回空串（MySQL 语义） | 仅 `(col, 常量正 start, 常量正 len)`；DuckDB `substr` 对 `pos<=0` 是 PostgreSQL 语义 | ⚠️ 仅满足约束时（已做，负向单测） | 同上 :530 |
| G-05 | `DECIMAL256` | 支持 | 不支持 | ⛔ 拒绝 | `cudf_utils.hpp:161` |
| G-06 | `DECIMAL(p ≤ 4)` | 正常 | 抛错（DuckDB 用 INT16 存） | ⛔ 拒绝（slot 级已做：`type_mapper.rs`）。**注意**：语料里 Q17 的 `0.2` 是 `DECIMAL32(2,1)`、Q20 的 `0.5` 是 `DECIMAL32(1,1)`、Q11 `0.0001` 是 `DECIMAL32(6,6)`——字面量层怎么处理（拓宽声明精度还是直接拒）P1.2 定 | 同上 :203；`sirius/src/include/cudf/cudf_utils.hpp` `get_cudf_type` DECIMAL 分支 |
| G-07 | `HLL` / `BITMAP` / `QUANTILE_STATE` / `AGG_STATE` | Doris 特有聚合中间态 | 无实现 | ⛔ 拒绝 | — |
| G-08 | `JSONB` / `VARIANT` | 结构化语义 | Sirius 当字符串处理 | ⛔ 拒绝 | `starrocks-plan-translator/src/lib.rs` 类型章节 |
| G-09 | `IPV4` / `IPV6` / `VARBINARY` / `TIMESTAMPTZ` | 支持 | 无映射 | ⛔ 拒绝 | — |
| G-10 | `ARRAY` / `MAP` / `STRUCT` 参与运算 | 支持 | 仅透传，WHERE/GROUP BY/JOIN ON/ORDER BY 中被拒 | ⛔ 拒绝（MVP 阶段整列拒绝更安全） | `physical-plan-generation.md:40` |
| G-11 | 窗口函数 | `ANALYTIC_EVAL_NODE`（FE 4.1.4 实测：放在根 fragment、压在 merging exchange 上） | 不支持 | ⛔ 拒绝（已做，09-18：`node_translator.rs` 按节点类型指名拒绝；负向用例 `unsupported_and_malformed_plans_are_named` + 真 FE 派发语料 `tests/fixtures/gaps/g11-window`，`tests/corpus.rs::gap_corpus_verdicts` 钉住） | `sirius_physical_plan_generator.cpp:1111` |
| G-12 | `UNION` / `INTERSECT` / `EXCEPT` | `UNION_NODE`（`UNION` distinct = 两阶段 group-by 压在 `UNION_NODE` 上） | 不支持（消费端 `SetRel` 也只收 2 输入，见 G-27） | ⛔ 拒绝（已做，09-18：三种节点类型指名拒绝；语料 `gaps/g12-union-all`、`gaps/g12-union-distinct`） | 同上 |
| G-13 | `SELECT DISTINCT` | **Nereids 不生成 distinct 算子**：编译成「group by 全部列、零聚合函数」的两阶段 `AGGREGATION_NODE`（实测 4.1.4） | `LOGICAL_DISTINCT` 直接抛；但我们发的是无度量的 `AggregateRel` → DuckDB `LogicalAggregate`，Sirius `sirius_plan_aggregate.cpp` 对「有 group、零聚合表达式」无拒绝分支 | ✅ **放行**（09-18 改判）：拼接器把零函数两阶段聚合折成一个 finalized group-by（`stitcher.rs::is_merge_aggregate` 靠「finalized AGG 直接压在 update 相 AGG 上」识别，因为没有 `is_merge_agg` 可看；`is_first_phase` 对 merge 相和单阶段都是 false，不能用）。语料 `gaps/g13-distinct`、`gaps/g13-distinct-topn` 翻出 `Aggregate[$0 => $0]`。**09-18 晚追加**：`... ORDER BY 全部 key LIMIT n` 时 FE 把 top-N 同时压到 **update 相**（`limit` + `agg_sort_info_by_group_key`），拼接器 `same_top_n_by_group_key` 识别后折叠。**CPU 差分已过**（两条探针经 DuckDB 消费端执行与原 SQL 一致）；**GPU 未验**：零度量 grouped aggregate 在 Sirius 上跑通是 MVP-A0 要看的一项 | 同上 :1201；`sirius/src/planner/sirius_plan_aggregate.cpp:633` |
| G-14 | 多阶段聚合的 merge 阶段 | 两阶段聚合（update `need_finalize=false` → EXCHANGE → merge `is_merge_agg=true`），语料 26 对 | 仅接受非 merge（一阶段） | ⛔ 单 fragment 拒绝（`two_phase_aggregates_are_rejected_by_phase`）；**A0 拼接器折叠**成一阶段后放行（`stitcher.rs`，22 条 TPC-H 全折），MVP-A 真 fragment 时再议 | — |
| G-15 | `upper` / `lower` / `trim` / `round` / `abs` / `replace` | 支持 | 不在 29 个 function_id 里 | ⛔ 拒绝（已做：白名单只有 `if/like/substring/substr/year/month/day/length/char_length/is_null_pred/is_not_null_pred`，其余 `UnsupportedFunction`） | `sirius/src/expression/function_id.cpp:34` |
| G-16 | `stddev` / `median` / `approx_count_distinct` / `multi_distinct_sum` | 支持 | 只有 8 个聚合 id（sum/sum_no_overflow/count/count_star/min/max/avg/first）；**`count(DISTINCT)` 是支持的**（`COLLECT_SET` 路径，`aggregate_op_util.cpp:104`），其它 DISTINCT 聚合不支持 | ⛔ 拒绝（已做：白名单 `sum/count/min/max/avg/multi_distinct_count`，多列 distinct 拒） | `sirius/src/expression/aggregate_id.cpp:34` |
| G-17 | `DATE` / `DATETIME`（v1）、`DECIMALV2` | 老类型，语义与 v2 不同 | — | ⛔ 拒绝（只走 DATEV2 / DATETIMEV2 / DECIMAL32/64/128I） | — |
| G-18 | 输出类型含 `NULL_TYPE` | 允许（未 cast 的 NULL 字面量） | Sirius 整个 plan 拒绝；且 DuckDB Substrait 消费端把带类型的 `null` 字面量变成**无类型** `SQLNULL` | ⛔ 拒绝 `NULL_TYPE`；有类型的 `NULL_LITERAL` 一律包一层 `Cast` 保住类型（已做） | `sirius_physical_plan_generator.cpp:1091`；`from_substrait.cpp` `TransformLiteralToValue` |

## 待验证（验证前一律拒绝）

| # | 主题 | 怀疑点 | 怎么验 |
|---|---|---|---|
| G-19 | **DECIMAL 运算结果精度推导** | 两侧的精度/scale 推导规则大概率不同。这是**最高风险项** —— 影响 TPC-H 几乎每条查询的金额计算。**09-18 对照 DuckDB 源码**：乘法两边一致（p1+p2 封顶 38，s1+s2；Q1 `(15,2)*(16,2)→(31,4)`、`(31,4)*(16,2)→(38,6)`）；`sum(DECIMAL(p,s))` 两边都是 `(38,s)`；**`avg(DECIMAL)` DuckDB 返回 DOUBLE**（`avg.cpp` `BindDecimalAvg`），Doris 返回 `DECIMAL128I(38,4)`；加减 DuckDB 会多留 1 位精度；除法规则未核对。消费端忽略 `ScalarFunction.output_type`，DuckDB 自己推类型。**09-18 晚 CPU 差分（A0.1）**：tuple 边界的显式 `Cast` 在消费端落地了——Q1 plan 结果类型 `avg_* DECIMAL(38,4)`、Q8 `o_year SMALLINT`、Q12 `BIGINT`，与 Doris 声明一致；22 条数值全部在 `max(1e-9 相对, 半 ulp)` 内（半 ulp 只为 avg 的 DECIMAL(38,4) 舍入） | 翻译器在 tuple 边界（projection/agg 输出）按 Doris 声明类型显式 `Cast`（P1.3 已做，CPU 差分已验）；GPU 上再看 Sirius 的 decimal 算术是否与 DuckDB 一致（专项 decimal 矩阵仍待做） |
| G-20 | `cast` 溢出行为 | Doris 依 `enable_strict_cast`，Sirius 用 throwing 语义 | 分别在 strict/非 strict 下差分 |
| G-21 | 除零 | Doris 默认返回 NULL | 差分 |
| G-22 | 字符串比较与排序 | collation 是否影响 ORDER BY / MIN / MAX 结果顺序 | 差分，含非 ASCII |
| G-23 | `avg` 的中间累加精度 | 整数/decimal 的 avg 中间类型两侧可能不同 | 差分 |
| G-24 | NULL 在排序中的位置 | 需确认 `NULLS FIRST/LAST` 在翻译时是否被显式传递 | 读 SortRel 翻译代码 + 差分 |
| G-25 | **Substrait `Root.names` 按位置套用** | `origin/doris` FINDINGS：DuckDB 优化器重排 join 输出列后，`Root.names` 仍按位置套 → 数据对、列名错（TPC-H Q3/Q10）。我们走同一个 `SubstraitToDuckDB` | 翻译器输出显式 Project 到目标列序（P1.3）。**09-18 晚 CPU 差分：22/22 列名与值都对，未触发**（`validate_tpch_results.py` 比列名） |
| G-26 | SortRel/FetchRel 顺序不保留 | 同上：`from_substrait` 对派生列上的 ORDER BY 不总保留顺序（Q13） | **09-18 晚 CPU 差分：未触发**——15 条带 ORDER BY 的按序比对全部通过（Q11 只有并列换序）。A0.3 后每条只剩一层 Sort（+Fetch），DuckDB 优化器不消重复的 TOP_N/ORDER_BY |
| G-27 | `SetRel` 多于 2 个输入 | 同上：DuckDB Substrait 消费端只支持 2 输入 | 已在 G-12 拒绝 UNION，保持 |
| G-28 | `count(DISTINCT)`（`invocation=DISTINCT`） | 同上：Q16 每行返回 1 | **09-18 更新**：当前 `from_substrait.cpp` `TransformAggregateOp` 正确读 `invocation` 传给 DuckDB，Sirius 也支持 count distinct（见 G-16）→ 翻译器放行 `multi_distinct_count`。**09-18 晚 CPU 差分：Q16 18,314 行全对，未触发**；GPU 上再看 Sirius 的 `COLLECT_SET` 路径 |
| G-29 | 自连接 / 关联子查询让 `from_substrait` 挂起 | 同上：Q7/Q11/Q22 同一 parquet 被引用两次 + NOT EXISTS → 永不返回 | **09-18 晚 CPU 差分：未触发**——A0 的单棵 plan 里同一 parquet 作为两个 `local_files` 读（Q7/Q11/Q22，Q18 lineitem 两次），DuckDB 1.5.5 + 消费端 `a7e045b` 秒回。MVP-A 真 fragment 时翻译器仍拒绝同一 **stream** 被读两次（Sirius `set_built` 也拒） |
| G-30 | DuckDB Substrait 消费端的类型面 | Doris `CHAR(n)`、`DATETIMEV2(scale 1/2/4/5)` | `SubstraitToDuckType` **没有** `FixedChar` 分支（抛 "not yet supported"）；`PrecisionTimestamp` 只收 0/3/6/9 | ⚠️ 已处理（09-18）：CHAR/VARCHAR 都发 `VarChar`（DuckDB 无定长 char，都落 VARCHAR）；DATETIMEV2 scale **向上**取整到 0/3/6（不丢位）。`type_mapper.rs` 有单测 | `substrait/src/from_substrait.cpp` `SubstraitToDuckType` |

---

## 记录新条目的模板

```
| G-NN | <主题> | <Doris 行为> | <DuckDB/Sirius 行为> | <处置> | <代码出处或差分测试用例> |
```

写完立刻做三件事：
1. 在 `eligibility/` 里加上对应判定
2. 加一个**负向单测**（构造触发该条件的表达式/类型，断言被拒绝）
3. 如果是 ❓ 转为已确认，把差分测试用例路径填进出处列
