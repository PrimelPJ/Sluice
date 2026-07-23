-- Hourly OHLCV rollup, executed by the curation Step Functions workflow.
-- The workflow deletes the current day's curated partition first, so this
-- INSERT INTO is effectively idempotent for the reprocessed window.
INSERT INTO sluice.ticks_ohlcv_hourly
SELECT
    product_id,
    date_format(from_iso8601_timestamp(source_ts), '%Y-%m-%dT%H:00:00Z') AS bucket_hour,
    element_at(array_agg(price ORDER BY source_ts ASC), 1)  AS open,
    max(price)                                              AS high,
    min(price)                                              AS low,
    element_at(array_agg(price ORDER BY source_ts DESC), 1) AS close,
    max(volume_24h)                                        AS volume,
    avg(spread_bps)                                        AS avg_spread_bps,
    count(*)                                               AS tick_count
FROM sluice.ticks_enriched
WHERE dt = date_format(current_date, '%Y-%m-%d')
GROUP BY
    product_id,
    date_format(from_iso8601_timestamp(source_ts), '%Y-%m-%dT%H:00:00Z');
