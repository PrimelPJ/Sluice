"""Loader Lambda.

Invoked as the final task of the curation Step Functions workflow, after Athena
has rebuilt the hourly OHLCV curated table. It queries the latest aggregate row
per product and upserts a compact "current snapshot" item into the DynamoDB
serving table that the API reads. This is the batch-to-serving handoff.

The Athena query is executed synchronously with a bounded poll loop; the state
machine already enforces an overall timeout, so this stays simple.
"""
from __future__ import annotations

import logging
import time
from decimal import Decimal
from typing import Any

import boto3

from common.config import loader_config
from common.logging import get_logger, log_event

log = get_logger("sluice.loader")
_athena = boto3.client("athena")
_dynamo = boto3.resource("dynamodb")

_POLL_SECONDS = 1.5
_MAX_POLLS = 40

_LATEST_QUERY = """
SELECT product_id, bucket_hour, open, high, low, close, volume, tick_count
FROM (
    SELECT *,
           row_number() OVER (PARTITION BY product_id ORDER BY bucket_hour DESC) AS rn
    FROM "{database}"."{table}"
)
WHERE rn = 1
"""


def _run_query(cfg) -> str:
    resp = _athena.start_query_execution(
        QueryString=_LATEST_QUERY.format(database=cfg.athena_database, table=cfg.curated_table),
        WorkGroup=cfg.athena_workgroup,
        ResultConfiguration={"OutputLocation": cfg.output_location},
    )
    qid = resp["QueryExecutionId"]
    for _ in range(_MAX_POLLS):
        state = _athena.get_query_execution(QueryExecutionId=qid)["QueryExecution"]["Status"]
        status = state["State"]
        if status == "SUCCEEDED":
            return qid
        if status in ("FAILED", "CANCELLED"):
            raise RuntimeError(f"athena {status}: {state.get('StateChangeReason')}")
        time.sleep(_POLL_SECONDS)
    raise TimeoutError("athena query did not complete in time")


def _rows(qid: str):
    paginator = _athena.get_paginator("get_query_results")
    first = True
    for page in paginator.paginate(QueryExecutionId=qid):
        rows = page["ResultSet"]["Rows"]
        if first:
            rows = rows[1:]  # drop header row
            first = False
        for row in rows:
            yield [c.get("VarCharValue") for c in row["Data"]]


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    cfg = loader_config()
    qid = _run_query(cfg)
    table = _dynamo.Table(cfg.table_name)

    written = 0
    with table.batch_writer(overwrite_by_pkeys=["pk", "sk"]) as batch:
        for product_id, bucket_hour, o, h, l, c, vol, n in _rows(qid):
            batch.put_item(
                Item={
                    "pk": f"PRODUCT#{product_id}",
                    "sk": "SNAPSHOT#LATEST",
                    "product_id": product_id,
                    "bucket_hour": bucket_hour,
                    "open": Decimal(o),
                    "high": Decimal(h),
                    "low": Decimal(l),
                    "close": Decimal(c),
                    "volume": Decimal(vol),
                    "tick_count": int(n),
                    "updated_at": int(time.time()),
                }
            )
            written += 1

    log_event(log, logging.INFO, "loader complete", written=written, query_id=qid)
    return {"written": written, "query_id": qid}
