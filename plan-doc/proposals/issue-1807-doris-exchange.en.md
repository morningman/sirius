<!-- Draft comment for https://github.com/sirius-db/sirius/issues/1807 (2026-10-06). Not posted yet.
     Facts checked against the Doris 4.1.4 IDL in experimental/doris/doris/gensrc (Partitions.thrift,
     DataSinks.thrift, PaloInternalService.thrift, PlanNodes.thrift, internal_service.proto). -->

Doris would use the same model (tracked in #2025): every node runs Sirius, and Doris's own exchange protocol is not needed. For a Doris 4.1.4 FE, the exchange metadata would need to carry:

- **Partitioning** (`TDataStreamSink.output_partition`): `UNPARTITIONED` sends every row to every destination (a broadcast, or a gather when there is one destination); `HASH_PARTITIONED` shuffles on a list of exprs; `RANDOM` is round-robin. With Sirius on every node, any consistent hash works for `HASH_PARTITIONED`.
- **Destinations**: each sending fragment gets a list of `{fragment_instance_id, brpc_server}`, and `dest_node_id` names the receiving `EXCHANGE_NODE`. One backend appears several times when a fragment runs several instances on it.
- **End of stream**: each receiver gets `per_exch_num_senders[exchange_node_id]`, and each sender has a `sender_id`.
- **Merging exchange**: the `EXCHANGE_NODE` carries `sort_info` and `offset` (plus the node's limit), so the receiver merges sorted inputs.
- **Dispatch**: the FE sends all fragments for one backend in one request (`exec_plan_fragment`, or `exec_plan_fragment_prepare` followed by `exec_plan_fragment_start` when a query has three or more fragments).

If the metadata identifies peers by an opaque id that the embedding backend resolves to a NIXL agent, both FEs fit without FE-specific fields in Sirius. Happy to review the sub-issues from the Doris side.
