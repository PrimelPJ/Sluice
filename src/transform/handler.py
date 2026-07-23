"""Transform Lambda (Kinesis Firehose data transformation).

Firehose invokes this in batches. Each record is base64-decoded, validated, and
enriched into the canonical EnrichedTick shape. The record is then re-emitted with
a status Firehose understands:

  Ok            -> delivered to S3 (converted to Parquet via the Glue schema)
  ProcessingFailed -> routed by Firehose to the S3 error prefix

Firehose also reads the `dt` and `hr` fields for dynamic partitioning, so the
data lands in Hive-style partitions without a crawler.
"""
from __future__ import annotations

import base64
import json
import logging
from typing import Any

from common.config import transform_config
from common.logging import get_logger, log_event
from common.models import EnrichedTick, RawTick, ValidationError

log = get_logger("sluice.transform")


def _decode(record: dict[str, Any]) -> dict[str, Any]:
    return json.loads(base64.b64decode(record["data"]).decode())


def _encode(payload: dict[str, Any]) -> str:
    # Newline-delimited JSON so Parquet conversion and Athena both parse cleanly.
    return base64.b64encode((json.dumps(payload) + "\n").encode()).decode()


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    cfg = transform_config()
    out: list[dict[str, Any]] = []
    ok = failed = 0

    for record in event["records"]:
        rid = record["recordId"]
        try:
            raw = RawTick(**_decode(record))
            enriched = EnrichedTick.from_raw(
                raw, cfg.schema_version, cfg.max_staleness_seconds
            )
            body = enriched.to_json()
            out.append(
                {
                    "recordId": rid,
                    "result": "Ok",
                    "data": _encode(body),
                    "metadata": {
                        "partitionKeys": {"dt": enriched.dt, "hr": enriched.hr}
                    },
                }
            )
            ok += 1
        except (ValidationError, KeyError, TypeError, json.JSONDecodeError) as exc:
            failed += 1
            log_event(log, logging.WARNING, "record rejected", record_id=rid, error=str(exc))
            out.append({"recordId": rid, "result": "ProcessingFailed", "data": record["data"]})

    log_event(log, logging.INFO, "transform batch complete", ok=ok, failed=failed)
    return {"records": out}
