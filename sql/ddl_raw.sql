-- Raw enriched tick table over the S3 data lake.
-- Uses partition projection so no Glue crawler is needed: Athena derives
-- partitions from the query predicate. Terraform creates the Glue table from
-- these same column definitions; this file is the readable source of truth.

CREATE EXTERNAL TABLE IF NOT EXISTS sluice.ticks_enriched (
    product_id      string,
    price           double,
    bid             double,
    ask             double,
    spread          double,
    spread_bps      double,
    mid             double,
    volume_24h      double,
    source_ts       string,
    ingest_ts       string,
    latency_ms      int,
    schema_version  int,
    record_id       string
)
PARTITIONED BY (dt string, hr string)
STORED AS PARQUET
LOCATION 's3://__DATA_BUCKET__/enriched/'
TBLPROPERTIES (
    'projection.enabled'          = 'true',
    'projection.dt.type'          = 'date',
    'projection.dt.format'        = 'yyyy-MM-dd',
    'projection.dt.range'         = '2024-01-01,NOW',
    'projection.dt.interval'      = '1',
    'projection.dt.interval.unit' = 'DAYS',
    'projection.hr.type'          = 'integer',
    'projection.hr.range'         = '0,23',
    'projection.hr.digits'        = '2',
    'storage.location.template'   = 's3://__DATA_BUCKET__/enriched/dt=${dt}/hr=${hr}/'
);
