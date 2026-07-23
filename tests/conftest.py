import os
import sys
from pathlib import Path

# Make `common`, `producer`, etc. importable exactly as they are in Lambda,
# where handlers sit at the root and `common` is provided by a layer on the path.
SRC = Path(__file__).resolve().parents[1] / "src"
for sub in ("", "producer", "transform", "loader", "serving"):
    p = str(SRC / sub) if sub else str(SRC)
    if p not in sys.path:
        sys.path.insert(0, p)

os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
os.environ.setdefault("STREAM_NAME", "test-stream")
os.environ.setdefault("DLQ_URL", "https://sqs.test/dlq")
os.environ.setdefault("PRODUCTS", "BTC-USD,ETH-USD")
os.environ.setdefault("SERVING_TABLE", "test-serving")
os.environ.setdefault("ATHENA_DATABASE", "sluice_dev")
os.environ.setdefault("ATHENA_WORKGROUP", "sluice-dev")
os.environ.setdefault("ATHENA_OUTPUT_LOCATION", "s3://x/query-results/")
