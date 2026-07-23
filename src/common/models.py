"""Domain models and validation for market tick records.

A single canonical record shape flows through the whole pipeline. The producer
emits `RawTick`, the transform stage promotes it to `EnrichedTick`, and both the
Glue table schema and the DynamoDB serving item are derived from this module so
the contract never drifts between code and infrastructure.
"""
from __future__ import annotations

import hashlib
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from typing import Any


class ValidationError(ValueError):
    """Raised when an inbound record cannot be coerced into a valid tick."""


def _to_decimal(value: Any, field: str) -> Decimal:
    try:
        d = Decimal(str(value))
    except (InvalidOperation, TypeError) as exc:
        raise ValidationError(f"{field} is not numeric: {value!r}") from exc
    if d.is_nan() or d.is_infinite():
        raise ValidationError(f"{field} is not finite: {value!r}")
    return d


def _parse_ts(value: Any) -> datetime:
    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(float(value), tz=timezone.utc)
    try:
        # Coinbase returns e.g. "2024-05-01T12:00:00.000000Z"
        cleaned = str(value).replace("Z", "+00:00")
        dt = datetime.fromisoformat(cleaned)
    except ValueError as exc:
        raise ValidationError(f"unparseable timestamp: {value!r}") from exc
    return dt.astimezone(timezone.utc) if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


@dataclass(frozen=True)
class RawTick:
    """What the producer scrapes from the upstream exchange, minimally shaped."""

    product_id: str
    price: str
    bid: str
    ask: str
    volume_24h: str
    source_ts: str
    ingest_ts: str

    @staticmethod
    def from_exchange(product_id: str, payload: dict[str, Any]) -> "RawTick":
        now = datetime.now(timezone.utc).isoformat()
        return RawTick(
            product_id=product_id,
            price=str(payload.get("price")),
            bid=str(payload.get("bid")),
            ask=str(payload.get("ask")),
            volume_24h=str(payload.get("volume")),
            source_ts=str(payload.get("time")),
            ingest_ts=now,
        )

    def to_json(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class EnrichedTick:
    """Validated, typed, and enriched. This is the shape written to S3/Parquet."""

    product_id: str
    price: float
    bid: float
    ask: float
    spread: float
    spread_bps: float
    mid: float
    volume_24h: float
    source_ts: str
    ingest_ts: str
    latency_ms: int
    schema_version: int
    dt: str          # partition key: YYYY-MM-DD
    hr: str          # partition key: HH
    record_id: str   # deterministic dedupe key

    @staticmethod
    def from_raw(raw: RawTick, schema_version: int, max_staleness_seconds: int) -> "EnrichedTick":
        price = _to_decimal(raw.price, "price")
        bid = _to_decimal(raw.bid, "bid")
        ask = _to_decimal(raw.ask, "ask")
        volume = _to_decimal(raw.volume_24h, "volume_24h")

        if price <= 0 or bid <= 0 or ask <= 0:
            raise ValidationError("non-positive price/bid/ask")
        if ask < bid:
            raise ValidationError(f"crossed book: ask {ask} < bid {bid}")

        source_dt = _parse_ts(raw.source_ts)
        ingest_dt = _parse_ts(raw.ingest_ts)
        latency = ingest_dt - source_dt
        latency_ms = int(latency.total_seconds() * 1000)

        if latency.total_seconds() > max_staleness_seconds:
            raise ValidationError(
                f"stale record: {latency.total_seconds():.0f}s > {max_staleness_seconds}s"
            )

        spread = ask - bid
        mid = (ask + bid) / Decimal(2)
        spread_bps = (spread / mid) * Decimal(10000) if mid > 0 else Decimal(0)

        record_id = hashlib.sha256(
            f"{raw.product_id}|{raw.source_ts}|{price}".encode()
        ).hexdigest()[:32]

        return EnrichedTick(
            product_id=raw.product_id,
            price=float(price),
            bid=float(bid),
            ask=float(ask),
            spread=float(spread),
            spread_bps=round(float(spread_bps), 4),
            mid=float(mid),
            volume_24h=float(volume),
            source_ts=source_dt.isoformat(),
            ingest_ts=ingest_dt.isoformat(),
            latency_ms=latency_ms,
            schema_version=schema_version,
            dt=source_dt.strftime("%Y-%m-%d"),
            hr=source_dt.strftime("%H"),
            record_id=record_id,
        )

    def to_json(self) -> dict[str, Any]:
        return asdict(self)


# Glue/Athena column definitions derived from EnrichedTick. Firehose uses this
# via the Glue table to convert JSON to Parquet, so the schema has exactly one
# source of truth.
GLUE_COLUMNS: list[tuple[str, str]] = [
    ("product_id", "string"),
    ("price", "double"),
    ("bid", "double"),
    ("ask", "double"),
    ("spread", "double"),
    ("spread_bps", "double"),
    ("mid", "double"),
    ("volume_24h", "double"),
    ("source_ts", "string"),
    ("ingest_ts", "string"),
    ("latency_ms", "int"),
    ("schema_version", "int"),
    ("record_id", "string"),
]

PARTITION_COLUMNS: list[tuple[str, str]] = [
    ("dt", "string"),
    ("hr", "string"),
]
