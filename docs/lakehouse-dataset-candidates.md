# Lakehouse dataset candidates

This document records dataset candidates for the first Iceberg learning
iteration across the siteA, siteB, and siteC Lakehouse authorities.

The capacity numbers are placement and failure-domain intent, not a claim that
the first materialized Iceberg tables will occupy exactly those bytes. Actual
compressed Parquet/Iceberg size must be measured with a pilot load before any
full-capacity run.

| Site | Capacity intent | Dataset role |
|---|---:|---|
| siteA | 100 TB | Main generation, ingestion, compaction, and cross-site join authority |
| siteB | 10 TB | Related partition slice and remote authority validation |
| siteC | 10 TB | Related partition slice and remote authority validation |

## Recommendation

Use TPC-DS first.

Trino's TPC-DS connector is the best first dataset because it is deterministic,
requires no external data acquisition, and exposes fixed scale schemas including
`sf100000`. Trino documents that each scale factor unit corresponds to one
gigabyte of generated data, so `sf100000` is the correct logical starting point
for a 100 TB capacity-intent exercise. The generated rows should be copied into
Iceberg tables and measured there; do not assume the generated scale factor maps
one-to-one to compressed Iceberg bytes.

Initial strategy:

1. Run a small pilot, for example `sf100` or `sf1000`, into Iceberg.
2. Measure physical bytes, file counts, manifest counts, and query behavior.
3. Choose the full-run scale from observed compression and object layout.
4. Partition by stable business keys and time-like columns where available.
5. Keep siteA as the full authority, then place related siteB/siteC slices that
   still join back to siteA facts and dimensions.

Example cross-site split for learning:

| Authority | Suggested TPC-DS role |
|---|---|
| siteA | Full fact tables and shared dimensions at the chosen full scale |
| siteB | A deterministic customer/store/channel slice for remote joins |
| siteC | A deterministic catalog/web/channel slice for remote joins |

## Candidates

| Candidate | Fit | Scale posture | Use after pilot? |
|---|---|---|---|
| TPC-DS synthetic via Trino | Best first Iceberg learning dataset: deterministic, repeatable, no acquisition gate, relational benchmark shape | Logical scale up to `sf100000`; physical Iceberg bytes require measurement | Yes, first |
| OpenAlex snapshot + fulltext + Crossref | Real scholarly graph: DOI/OpenAlex joins, metadata quality checks, content/TEI enrichment | OpenAlex snapshot is hundreds of GB compressed; OpenAlex fulltext is tens to hundreds of TB; Crossref public data is hundreds of GB | Yes, after table/metadata mechanics are stable |
| Common Crawl WARC/WET/index | Web-scale object ingestion, text extraction, and file-layout pressure testing | Common Crawl describes crawl archives as multi-billion-page and hundreds of TB | Later, when ingestion and compaction automation are ready |
| GDELT + Wikimedia | Smaller enrichment streams and public knowledge dimensions | GDELT is frequent, relational-ish event/news data; Wikimedia dumps are monthly project snapshots | Yes, as enrichment tables |

## Candidate notes

### TPC-DS synthetic

Use Trino's TPC-DS connector to generate relational source data, then write the
result into Iceberg. This is the cleanest way to learn:

- Iceberg table creation and schema evolution
- partition design
- snapshot/manifest metadata growth
- compaction behavior
- Trino and Spark read/write compatibility
- DataFederation namespace behavior across related tables

Official source:

- [Trino TPC-DS connector](https://trino.io/docs/current/connector/tpcds.html)

### OpenAlex + Crossref scholarly corpus

Use this after TPC-DS because it adds real-world messiness: nested records,
identifier reconciliation, DOI normalization, content licensing, and partial
record quality.

Useful joins:

- OpenAlex works `doi` / `id` to Crossref DOI metadata
- OpenAlex works to fulltext manifest by `openalex_id`
- OpenAlex authors, institutions, sources, topics, and funders as dimensions
- Crossref references and relation metadata as quality/completeness checks

Capacity mapping:

- siteA owns the full scholarly metadata and selected content ingest.
- siteB owns a DOI/topic/year slice that joins to siteA works.
- siteC owns an institution/source/topic slice that joins to siteA works.

Official sources:

- [OpenAlex snapshot](https://help.openalex.org/access/snapshot/)
- [OpenAlex fulltext](https://help.openalex.org/access/fulltext/)
- [Crossref bulk downloads and snapshots](https://www.crossref.org/documentation/retrieve-metadata/bulk-downloads/)
- [Crossref public data file](https://www.crossref.org/services/metadata-retrieval/public-data-file/)

### Common Crawl

Use Common Crawl when the goal is raw scale and object-layout stress. WARC files
preserve raw crawl responses, WAT files contain metadata, and WET files contain
extracted plain text. The Common Crawl Index can narrow selection before
downloading or transforming large archive regions.

Capacity mapping:

- siteA owns raw selected crawl ranges and canonical text extraction.
- siteB/siteC own filtered language/domain/time slices for remote query tests.

Official source:

- [Common Crawl Get Started](https://commoncrawl.org/get-started)

### GDELT and Wikimedia

Use these as enrichment tables rather than the first 100 TB target.

GDELT is useful for event, mention, theme, language, and geospatial enrichment.
Wikimedia is useful for public knowledge text, page metadata, and entity
enrichment. Both are operationally easier than a full Common Crawl pass.

Official sources:

- [GDELT data downloads and documentation](https://www.gdeltproject.org/data.html)
- [Wikimedia downloads](https://dumps.wikimedia.org/)
- [Wikimedia Enterprise documentation](https://enterprise.wikimedia.com/docs/)

## Stop condition before full-size materialization

Do not start a 100 TB / 10 TB / 10 TB materialization run until a pilot records:

- source scale factor or source slice definition
- produced Iceberg data bytes
- metadata bytes and manifest count
- average file size
- compaction command and result
- representative Trino and Spark query timings
- recoverability behavior after one failed/retried write
