# devops-agent-sdk Lambda layer

Lightweight layer containing only the botocore service model JSON for the
AWS DevOps Agent service (`boto3.client('devops-agent')`). The Lambda
runtime's bundled boto3/botocore discovers the model at runtime via the
`AWS_DATA_PATH` environment variable pointing at `/opt/botocore-models`.

## How it works

Botocore's `Loader` class checks the paths listed in `AWS_DATA_PATH` (colon-
separated) before its built-in data directory. This layer deploys the service
model files to `/opt/botocore-models/devops-agent/2026-01-01/` — when the
Lambda function has `AWS_DATA_PATH=/opt/botocore-models`, the runtime's own
boto3 can create the `devops-agent` client without needing a full boto3
upgrade.

Layer size: ~26 KB (vs ~40 MB for a full boto3 bundle).

## Files

- `service-model/` — the three botocore model files (committed to source)
  - `service-2.json` — API shapes, operations, metadata
  - `endpoint-rule-set-1.json` — endpoint resolution rules
  - `paginators-1.json` — pagination configs
- `build.sh` — packs the model files into `layer.zip`
- `layer.zip` — the artifact CloudFormation uploads to Lambda

## Building

```bash
./build.sh
```

The Lambda function **must** have the environment variable:
```
AWS_DATA_PATH=/opt/botocore-models
```

## Updating the service model

When AWS adds operations or shapes to the DevOps Agent API:

1. Install the latest boto3 that has the update:
   ```bash
   pip install boto3==<new-version>
   ```
2. Copy the updated model files:
   ```bash
   cp $(python3 -c "import botocore; print(botocore.__path__[0])")/data/devops-agent/2026-01-01/*.json service-model/
   ```
   (If the API version changes from `2026-01-01`, create a new directory accordingly.)
3. Rebuild: `./build.sh`
4. Commit `service-model/` and `layer.zip`.
5. Re-run `./bootstrap.sh` — CloudFormation creates a new layer version.

## When to remove this layer

Once the Lambda runtime's bundled boto3 includes the `devops-agent` service
definition (check with `aws lambda get-function-configuration` → runtime
version), this layer and the `AWS_DATA_PATH` env var can be deleted entirely.
No code changes needed — boto3 will find the model in its built-in data path.
