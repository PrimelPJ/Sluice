import base64
import json
from datetime import datetime, timezone
from unittest.mock import MagicMock, patch


def _fh_record(rid, body):
    return {"recordId": rid, "data": base64.b64encode(json.dumps(body).encode()).decode()}


def _good_body():
    now = datetime.now(timezone.utc)
    return {
        "product_id": "BTC-USD",
        "price": "60000.5",
        "bid": "60000",
        "ask": "60001",
        "volume_24h": "10",
        "source_ts": now.isoformat(),
        "ingest_ts": now.isoformat(),
    }


def test_transform_marks_good_and_bad_records():
    from transform import handler as h

    event = {
        "records": [
            _fh_record("r1", _good_body()),
            _fh_record("r2", {"product_id": "X"}),  # missing fields -> fail
        ]
    }
    out = h.handler(event, None)["records"]
    by_id = {r["recordId"]: r for r in out}
    assert by_id["r1"]["result"] == "Ok"
    assert by_id["r1"]["metadata"]["partitionKeys"]["dt"]
    assert by_id["r2"]["result"] == "ProcessingFailed"

    decoded = json.loads(base64.b64decode(by_id["r1"]["data"]).decode())
    assert decoded["spread"] == 1.0


def test_producer_puts_records_and_dlqs_failures():
    from producer import handler as h

    ticker = {"price": "60000.5", "bid": "60000", "ask": "60001", "volume": "10",
              "time": datetime.now(timezone.utc).isoformat()}

    with patch.object(h, "_fetch_ticker", side_effect=[ticker, RuntimeError("boom")]), \
         patch.object(h, "_kinesis") as kin, patch.object(h, "_sqs") as sqs, \
         patch.object(h, "producer_config") as cfg:
        cfg.return_value = MagicMock(
            products=("BTC-USD", "ETH-USD"),
            source_base_url="https://x",
            stream_name="s",
            dlq_url="d",
        )
        kin.put_records.return_value = {"FailedRecordCount": 0, "Records": [{}]}
        result = h.handler({}, None)

    assert result["put"] == 1
    assert result["failures"] == 1
    sqs.send_message.assert_called_once()


def test_serving_routes():
    from serving import handler as h

    with patch.object(h, "_dynamo") as dynamo:
        table = MagicMock()
        table.get_item.return_value = {"Item": {"product_id": "BTC-USD", "close": 1}}
        dynamo.Table.return_value = table

        health = h.handler({"routeKey": "GET /health"}, None)
        assert health["statusCode"] == 200

        got = h.handler(
            {"routeKey": "GET /products/{product_id}",
             "pathParameters": {"product_id": "BTC-USD"}},
            None,
        )
        assert got["statusCode"] == 200
        assert json.loads(got["body"])["product_id"] == "BTC-USD"

        table.get_item.return_value = {}
        missing = h.handler(
            {"routeKey": "GET /products/{product_id}",
             "pathParameters": {"product_id": "NOPE"}},
            None,
        )
        assert missing["statusCode"] == 404
