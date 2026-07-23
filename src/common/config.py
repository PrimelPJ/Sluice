"""Centralized environment-driven configuration.

Every Lambda reads its wiring from environment variables set by Terraform.
Keeping this in one place means a renamed resource is a one-line change and
the handlers stay free of os.environ lookups scattered through the logic.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from functools import lru_cache


def _require(name: str) -> str:
    val = os.environ.get(name)
    if not val:
        raise RuntimeError(f"missing required environment variable: {name}")
    return val


@dataclass(frozen=True)
class ProducerConfig:
    stream_name: str
    products: tuple[str, ...]
    source_base_url: str
    dlq_url: str


@dataclass(frozen=True)
class TransformConfig:
    schema_version: int
    max_staleness_seconds: int


@dataclass(frozen=True)
class LoaderConfig:
    table_name: str
    athena_database: str
    athena_workgroup: str
    curated_table: str
    output_location: str


@dataclass(frozen=True)
class ServingConfig:
    table_name: str


@lru_cache(maxsize=1)
def producer_config() -> ProducerConfig:
    raw = os.environ.get("PRODUCTS", "BTC-USD,ETH-USD,SOL-USD")
    return ProducerConfig(
        stream_name=_require("STREAM_NAME"),
        products=tuple(p.strip() for p in raw.split(",") if p.strip()),
        source_base_url=os.environ.get(
            "SOURCE_BASE_URL", "https://api.exchange.coinbase.com"
        ),
        dlq_url=_require("DLQ_URL"),
    )


@lru_cache(maxsize=1)
def transform_config() -> TransformConfig:
    return TransformConfig(
        schema_version=int(os.environ.get("SCHEMA_VERSION", "1")),
        max_staleness_seconds=int(os.environ.get("MAX_STALENESS_SECONDS", "120")),
    )


@lru_cache(maxsize=1)
def loader_config() -> LoaderConfig:
    return LoaderConfig(
        table_name=_require("SERVING_TABLE"),
        athena_database=_require("ATHENA_DATABASE"),
        athena_workgroup=_require("ATHENA_WORKGROUP"),
        curated_table=os.environ.get("CURATED_TABLE", "ticks_ohlcv_hourly"),
        output_location=_require("ATHENA_OUTPUT_LOCATION"),
    )


@lru_cache(maxsize=1)
def serving_config() -> ServingConfig:
    return ServingConfig(table_name=_require("SERVING_TABLE"))
