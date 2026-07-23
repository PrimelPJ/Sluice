"""Serving Lambda (API Gateway HTTP API proxy integration).

Read-only endpoints backed by the DynamoDB serving table:

  GET /health                    -> liveness
  GET /products                  -> list products with a current snapshot
  GET /products/{product_id}     -> latest OHLCV snapshot for one product

Kept deliberately thin: all heavy computation happened upstream in Athena, so
the request path is a single-digit-millisecond DynamoDB lookup.
"""
from __future__ import annotations

import decimal
import json
import logging
from typing import Any

import boto3
from boto3.dynamodb.conditions import Attr

from common.config import serving_config
from common.logging import get_logger, log_event

log = get_logger("sluice.serving")
_dynamo = boto3.resource("dynamodb")


class _DecimalEncoder(json.JSONEncoder):
    def default(self, o: Any) -> Any:
        if isinstance(o, decimal.Decimal):
            return float(o)
        return super().default(o)


def _response(status: int, body: Any) -> dict[str, Any]:
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body, cls=_DecimalEncoder),
    }


def _get_product(table, product_id: str) -> dict[str, Any]:
    resp = table.get_item(Key={"pk": f"PRODUCT#{product_id}", "sk": "SNAPSHOT#LATEST"})
    item = resp.get("Item")
    if not item:
        return _response(404, {"error": f"unknown product {product_id}"})
    return _response(200, item)


def _list_products(table) -> dict[str, Any]:
    # Small serving table; a filtered scan is acceptable here. For scale this
    # would move to a GSI keyed on a constant partition.
    resp = table.scan(FilterExpression=Attr("sk").eq("SNAPSHOT#LATEST"))
    products = sorted(i["product_id"] for i in resp.get("Items", []))
    return _response(200, {"products": products, "count": len(products)})


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    cfg = serving_config()
    table = _dynamo.Table(cfg.table_name)

    route = event.get("routeKey") or f"{event.get('httpMethod')} {event.get('path')}"
    params = event.get("pathParameters") or {}
    log_event(log, logging.INFO, "request", route=route)

    if route.endswith("/health"):
        return _response(200, {"status": "ok"})
    if route.endswith("/products/{product_id}"):
        return _get_product(table, params["product_id"])
    if route.endswith("/products"):
        return _list_products(table)
    return _response(404, {"error": "not found", "route": route})
