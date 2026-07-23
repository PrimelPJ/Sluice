from datetime import datetime, timedelta, timezone

import pytest

from common.models import EnrichedTick, RawTick, ValidationError


def _raw(**overrides):
    now = datetime.now(timezone.utc)
    base = dict(
        product_id="BTC-USD",
        price="60000.50",
        bid="60000.00",
        ask="60001.00",
        volume_24h="1234.5",
        source_ts=now.isoformat(),
        ingest_ts=(now + timedelta(milliseconds=250)).isoformat(),
    )
    base.update(overrides)
    return RawTick(**base)


def test_enrichment_computes_spread_and_partitions():
    tick = EnrichedTick.from_raw(_raw(), schema_version=1, max_staleness_seconds=120)
    assert tick.spread == pytest.approx(1.0)
    assert tick.mid == pytest.approx(60000.5)
    assert tick.spread_bps == pytest.approx(round((1.0 / 60000.5) * 10000, 4), abs=1e-4)
    assert tick.latency_ms >= 0
    assert len(tick.dt) == 10 and len(tick.hr) == 2
    assert len(tick.record_id) == 32


def test_crossed_book_rejected():
    with pytest.raises(ValidationError):
        EnrichedTick.from_raw(_raw(bid="60002", ask="60001"), 1, 120)


def test_non_numeric_price_rejected():
    with pytest.raises(ValidationError):
        EnrichedTick.from_raw(_raw(price="not-a-number"), 1, 120)


def test_stale_record_rejected():
    old = datetime.now(timezone.utc) - timedelta(seconds=600)
    with pytest.raises(ValidationError):
        EnrichedTick.from_raw(
            _raw(source_ts=old.isoformat()), 1, max_staleness_seconds=120
        )


def test_record_id_is_deterministic():
    r = _raw()
    a = EnrichedTick.from_raw(r, 1, 120)
    b = EnrichedTick.from_raw(r, 1, 120)
    assert a.record_id == b.record_id
