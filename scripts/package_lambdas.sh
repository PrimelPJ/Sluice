#!/usr/bin/env bash
# Stage the shared `common` package as a Lambda layer. Terraform's archive_file
# data sources zip build/layer and each src/<fn> directory at plan time.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAYER="$ROOT/build/layer/python"

rm -rf "$ROOT/build/layer"
mkdir -p "$LAYER"
cp -r "$ROOT/src/common" "$LAYER/common"
# Drop caches so the layer hash is stable across machines.
find "$ROOT/build/layer" -name '__pycache__' -type d -prune -exec rm -rf {} +
echo "staged layer at build/layer (contents: $(ls "$LAYER"))"
