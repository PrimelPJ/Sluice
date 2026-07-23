#!/usr/bin/env bash
# Hit the deployed API and print the latest snapshot for each product.
set -euo pipefail
cd "$(dirname "$0")/../infra"
API="$(terraform output -raw api_endpoint)"
echo "health:   $(curl -s "$API/health")"
echo "products: $(curl -s "$API/products")"
for p in $(curl -s "$API/products" | python3 -c 'import sys,json;print(" ".join(json.load(sys.stdin)["products"]))'); do
  echo "$p -> $(curl -s "$API/products/$p")"
done
