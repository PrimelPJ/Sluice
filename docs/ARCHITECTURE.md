# Architecture

## Data flow, end to end

1. **Ingestion.** EventBridge invokes the producer Lambda on a schedule. For each
   configured product it fetches the exchange ticker over HTTPS and puts a record
   on the Kinesis stream, keyed by `product_id` so a symbol's ticks stay ordered
   on one shard. Fetch or put failures go to an SQS dead-letter queue.

2. **Delivery + transform.** Firehose consumes the stream and invokes the
   transform Lambda per batch. The Lambda decodes each record, coerces types,
   runs business validation, computes derived fields (spread, spread in basis
   points, mid, ingest latency), and returns `dt`/`hr` partition keys as record
   metadata. Firehose converts the accepted JSON to Parquet using the Glue table
   schema and writes to `enriched/dt=YYYY-MM-DD/hr=HH/`. Rejected records land
   under `errors/`.

3. **Curation.** An hourly EventBridge rule starts a Step Functions state
   machine. Step one runs the OHLCV aggregation in Athena (`.sync`, so the state
   machine blocks until the query finishes). Step two invokes the loader Lambda,
   which queries the latest row per product from the curated table and upserts a
   compact snapshot into DynamoDB.

4. **Serving.** API Gateway (HTTP API) proxies to the serving Lambda, which reads
   the snapshot from DynamoDB. No computation on the request path.

5. **Analytics.** The raw enriched table is queryable directly in Athena for
   ad-hoc work, independent of the curated serving path.

## Contracts

`src/common/models.py` is the single source of truth for the record shape.
`EnrichedTick` produces the JSON written to S3; `GLUE_COLUMNS` mirrors it and is
what the Terraform `catalog` module encodes into the Glue table used for Parquet
conversion. Change a field in one place and the tests catch the mismatch.

## Failure modes and how they are handled

| Failure                                  | Handling                                                        |
|------------------------------------------|----------------------------------------------------------------|
| Upstream API down / times out            | Producer catches it, sends context to the SQS DLQ, keeps going  |
| Individual Kinesis `PutRecords` failure  | Per-record error codes inspected; failures re-driven to the DLQ |
| Malformed or crossed-book / stale record | Transform returns `ProcessingFailed`; Firehose isolates to `errors/` |
| Ingestion stalls                         | CloudWatch alarm on Kinesis `IncomingRecords` (breaching on missing data) |
| Athena aggregation transient error       | Step Functions retry with exponential backoff                   |
| Loader throttled                         | Step Functions retry on `Lambda.TooManyRequestsException`       |
| Poison message in the stream             | Bounded blast radius: one record fails, the batch still delivers |

## Deliberate simplifications

These are called out honestly rather than hidden:

- **Curation idempotency.** The rollup uses `INSERT INTO` over the current day's
  partition. A production version would delete-then-insert (or CTAS to a swapped
  location) so a mid-hour rerun cannot double-count. The Step Functions structure
  leaves a clean place to add that delete step.
- **`/products` uses a filtered scan.** Fine for a few dozen symbols. At scale it
  moves to a GSI on a constant partition key.
- **Single region, single account.** No cross-region replication or multi-account
  separation; the Terraform is structured so a `prod` workspace is a tfvars change.
- **Provisioned Kinesis.** One shard by default. On-demand mode is a one-line
  change if traffic is spiky.

## Extension points

- Attach a second Kinesis consumer for real-time anomaly detection (the raw tap
  exists precisely so this does not disturb delivery).
- Add a SageMaker batch-inference step to the curation workflow to score the
  enriched stream.
- Add a Glue/Iceberg table for time-travel and compaction if the raw lake grows.
