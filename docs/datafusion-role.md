# DataFusion role in the Lakehouse stack

DataFusion is not added as an Argo CD application in the current Lakehouse
baseline.

The baseline remains:

- Trino for interactive SQL and federation-facing query validation
- Spark for distributed ingestion, transformation, and Iceberg table writes
- Iceberg for table metadata, snapshots, manifests, and object-store layout

## Decision

Do not deploy core Apache DataFusion as a cluster service now.

Core DataFusion is a single-process, in-process Rust query-engine library and
developer-facing binary set for building customized analytical systems. It is
useful for embedded execution, custom query engines, and future DataFederation
implementation experiments, but it is not a ready-made Lakehouse control-plane
service that should be installed beside Trino and Spark by default.

## Related options

| Option | What it is | Current action |
|---|---|---|
| Core DataFusion | In-process query engine library and CLI surface built on Apache Arrow | Keep as an implementation candidate for DataFederation internals |
| Ballista | Distributed processing extension for DataFusion with scheduler/executor deployment paths, including Kubernetes documentation | Defer until there is a concrete distributed Rust query experiment |
| Comet | Apache Spark accelerator that runs supported Spark queries through DataFusion-native execution and accelerates Parquet/Iceberg scans | Defer until Spark workload profiling shows a clear candidate |

## Why it is not in the Argo app set yet

- Trino and Spark already cover the first Lakehouse learning loop.
- Adding DataFusion without a specific workload would create another runtime to
  operate without proving value.
- Core DataFusion is most relevant as a library inside a future DataFederation
  implementation, not as a standalone GitOps application.
- Ballista and Comet are the deployable paths, but both need workload-specific
  validation before they become cluster apps.

## When to add it

Add a DataFusion-related component only when one of these becomes true:

- DataFederation needs an embedded Rust execution engine for local planning,
  predicate evaluation, file pruning, or custom table providers.
- A distributed Rust query experiment requires Ballista scheduler/executor
  deployment.
- Spark query profiles show Comet can accelerate the actual Iceberg workload
  without breaking compatibility or operations.

## Official sources

- [Apache DataFusion documentation](https://datafusion.apache.org/index.html)
- [Apache DataFusion Ballista documentation](https://datafusion.apache.org/ballista/)
- [Apache DataFusion Comet documentation](https://datafusion.apache.org/comet/)
