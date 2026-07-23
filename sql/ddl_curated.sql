-- Curated hourly OHLCV table, rebuilt by the aggregation query.
CREATE EXTERNAL TABLE IF NOT EXISTS sluice.ticks_ohlcv_hourly (
    product_id     string,
    bucket_hour    string,
    open           double,
    high           double,
    low            double,
    close          double,
    volume         double,
    avg_spread_bps double,
    tick_count     bigint
)
STORED AS PARQUET
LOCATION 's3://__DATA_BUCKET__/curated/ticks_ohlcv_hourly/'
TBLPROPERTIES ('parquet.compression' = 'SNAPPY');
