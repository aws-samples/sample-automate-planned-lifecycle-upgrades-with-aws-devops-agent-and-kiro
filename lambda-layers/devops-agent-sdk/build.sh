#!/usr/bin/env bash
#
# Build the devops-agent-sdk Lambda layer.
#
# Produces ./layer.zip containing only the botocore service model files for
# the `devops-agent` service. The Lambda runtime's bundled boto3/botocore
# discovers the model via the AWS_DATA_PATH environment variable pointing at
# /opt/botocore-models (set on the Lambda function in CloudFormation).
#
# This approach avoids bundling a full boto3 (~40 MB) — the layer is <30 KB
# and contains zero third-party code, only the API schema JSON files.
#
# Usage:
#   ./lambda-layers/devops-agent-sdk/build.sh

set -euo pipefail

cd "$(dirname "$0")"

MODEL_DIR="botocore-models/devops-agent/2026-01-01"

echo "[layer-build] Packing service model layer..."

rm -rf botocore-models layer.zip
mkdir -p "$MODEL_DIR"
cp service-model/service-2.json "$MODEL_DIR/"
cp service-model/endpoint-rule-set-1.json "$MODEL_DIR/"
cp service-model/paginators-1.json "$MODEL_DIR/"

zip -rq -X layer.zip botocore-models
rm -rf botocore-models

ls -lh layer.zip
echo "[layer-build] Done. Upload via bootstrap.sh."
echo "[layer-build] The Lambda function must have AWS_DATA_PATH=/opt/botocore-models"
