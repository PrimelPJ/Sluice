#!/usr/bin/env bash
# Manually drive one end-to-end cycle without waiting for the schedules:
# invoke the producer a few times, then start the curation workflow.
set -euo pipefail
cd "$(dirname "$0")/../infra"
PROD="$(terraform output -raw kinesis_stream | sed 's/-ticks$/-producer/')"
SFN="$(terraform output -raw state_machine_arn)"

for i in $(seq 1 5); do
  aws lambda invoke --function-name "$PROD" /dev/stdout >/dev/null && echo "producer tick $i"
  sleep 12
done
echo "waiting for firehose buffer to flush..."
sleep 75
aws stepfunctions start-execution --state-machine-arn "$SFN" >/dev/null
echo "started curation workflow: $SFN"
