"""Producer Lambda.

Triggered on a schedule by EventBridge. For each configured product it pulls the
current ticker from the exchange REST API and puts a record on the Kinesis data
stream. Anything it cannot fetch or serialize is routed to an SQS dead-letter
queue rather than silently dropped, so ingestion gaps are observable.

The stream partition key is the product_id, which keeps all ticks for one symbol
on the same shard and in order.
"""
from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Any

import boto3

from common.config import producer_config
from common.logging import get_logger, log_event
from common.models import RawTick
import logging

log = get_logger("sluice.producer")
_kinesis = boto3.client("kinesis")
_sqs = boto3.client("sqs")

_HTTP_TIMEOUT = 4


def _fetch_ticker(base_url: str, product_id: str) -> dict[str, Any]:
    url = f"{base_url}/products/{product_id}/ticker"
    req = urllib.request.Request(url, headers={"User-Agent": "sluice/1.0"})
    with urllib.request.urlopen(req, timeout=_HTTP_TIMEOUT) as resp:
        if resp.status != 200:
            raise RuntimeError(f"upstream {resp.status} for {product_id}")
        return json.loads(resp.read().decode())


def _to_dlq(dlq_url: str, product_id: str, reason: str) -> None:
    _sqs.send_message(
        QueueUrl=dlq_url,
        MessageBody=json.dumps({"product_id": product_id, "reason": reason}),
    )


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    cfg = producer_config()
    records = []
    failures = 0

    for product_id in cfg.products:
        try:
            payload = _fetch_ticker(cfg.source_base_url, product_id)
            tick = RawTick.from_exchange(product_id, payload)
            records.append(
                {
                    "Data": (json.dumps(tick.to_json()) + "\n").encode(),
                    "PartitionKey": product_id,
                }
            )
        except (urllib.error.URLError, RuntimeError, ValueError, KeyError) as exc:
            failures += 1
            log_event(log, logging.ERROR, "fetch failed", product=product_id, error=str(exc))
            _to_dlq(cfg.dlq_url, product_id, str(exc))

    put_count = 0
    if records:
        resp = _kinesis.put_records(StreamName=cfg.stream_name, Records=records)
        put_count = len(records) - resp.get("FailedRecordCount", 0)
        # Re-drive individual Kinesis put failures to the DLQ.
        for rec, result in zip(records, resp.get("Records", [])):
            if result.get("ErrorCode"):
                failures += 1
                _to_dlq(
                    cfg.dlq_url,
                    rec["PartitionKey"],
                    f"kinesis:{result.get('ErrorCode')}",
                )

    log_event(
        log,
        logging.INFO,
        "producer run complete",
        fetched=len(records),
        put=put_count,
        failures=failures,
    )
    return {"put": put_count, "failures": failures}
