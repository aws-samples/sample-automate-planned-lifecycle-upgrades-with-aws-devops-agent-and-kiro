#!/usr/bin/env bash
#
# bootstrap.sh — one-shot setup for the EKS upgrade pipeline.
#
# Runs:
#   1. npm install
#   2. cdk bootstrap (only if the target account/region isn't bootstrapped)
#   3. cdk deploy (EKS cluster + addons + ALB controller)
#   4. Build + upload the devops-agent-sdk Lambda layer (botocore service
#      model JSON for the `devops-agent` API), then aws cloudformation
#      deploy (DevOps Agent space + EventBridge + Lambdas + the layer
#      reference).
#
# To deploy multiple copies in the same account/region, pass a unique suffix.
# It's threaded through both CDK and CFN so every named resource stays unique:
#
#   NAME_SUFFIX=alice ./bootstrap.sh
#
# After this finishes, continue with the remaining manual steps in the README
# (webhook, GitHub PAT, Kiro API key, skill upload, smoke test).
#
# Usage:
#   ./bootstrap.sh                           # defaults, one deployment per account/region
#   NAME_SUFFIX=alice ./bootstrap.sh         # suffix all resources with -alice
#   AWS_PROFILE=my-profile ./bootstrap.sh
#   AWS_REGION=us-east-1 ./bootstrap.sh
#   STACK_NAME=MyDevOpsAgentStack ./bootstrap.sh
#   GITHUB_REPO=owner/repo ./bootstrap.sh    # passed to CFN as GitHubRepo parameter
#   SKIP_CDK=1 ./bootstrap.sh                # skip CDK deploy (already deployed)
#   SKIP_CFN=1 ./bootstrap.sh                # skip CFN deploy

set -euo pipefail

NAME_SUFFIX="${NAME_SUFFIX:-}"
CFN_TEMPLATE="${CFN_TEMPLATE:-devops-agent-space.yaml}"
if [[ -z "${GITHUB_REPO:-}" ]]; then
  # Falls back to the origin remote. Set GITHUB_REPO=<owner>/<repo> explicitly
  # if the remote isn't the repo the pipeline should dispatch workflows against.
  GITHUB_REPO=$(git remote get-url origin 2>/dev/null | sed -E 's#.+github\.com[:/]##; s#\.git$##')
fi

# --- helpers -----------------------------------------------------------------

log()  { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bootstrap]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[bootstrap]\033[0m %s\n' "$*" >&2; exit 1; }

require() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

# --- preflight ---------------------------------------------------------------

log "Checking prerequisites..."
require node
require npm
require npx
require aws

aws sts get-caller-identity >/dev/null 2>&1 \
  || die "AWS CLI is not configured. Run 'aws configure' or export AWS_PROFILE."

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region || echo '')}}"
[[ -n "$REGION" ]] || die "No AWS region set. Export AWS_REGION or configure a default."

# Validate NAME_SUFFIX so CDK and CFN agree on the rules.
if [[ -n "$NAME_SUFFIX" ]]; then
  if ! [[ "$NAME_SUFFIX" =~ ^[a-z0-9-]{1,20}$ ]]; then
    die "Invalid NAME_SUFFIX '$NAME_SUFFIX'. Use 1-20 chars, lowercase alphanumeric or hyphens."
  fi
fi

# Resolve the CFN stack name. If the user didn't override STACK_NAME, suffix it.
if [[ -z "${STACK_NAME:-}" ]]; then
  if [[ -n "$NAME_SUFFIX" ]]; then
    STACK_NAME="DevOpsAgentStack-$NAME_SUFFIX"
  else
    STACK_NAME="DevOpsAgentStack"
  fi
fi

log "Target: account=$ACCOUNT_ID region=$REGION"
log "Stack:  $STACK_NAME  suffix=${NAME_SUFFIX:-<none>}"

[[ -f "$CFN_TEMPLATE" ]] || die "CFN template not found: $CFN_TEMPLATE"
[[ -f package.json ]]   || die "package.json not found. Run this from the repo root."

# --- step 1: npm install -----------------------------------------------------

log "Step 1/4: npm install"
# `npm install` (not `npm ci`) is intentional here: this is first-time local
# setup and the same package.json may be edited by the upgrade automation, so
# the lockfile must be allowed to reconcile. Dependency versions are pinned in
# the committed package.json / package-lock.json, which govern what resolves.
npm install

# --- step 2: cdk bootstrap (idempotent) --------------------------------------

log "Step 2/4: checking CDK bootstrap status"
if aws cloudformation describe-stacks \
     --stack-name CDKToolkit \
     --region "$REGION" >/dev/null 2>&1; then
  log "CDK already bootstrapped in $REGION, skipping."
else
  log "Bootstrapping CDK in $ACCOUNT_ID/$REGION"
  npx cdk bootstrap "aws://$ACCOUNT_ID/$REGION"
fi

# --- step 3: cdk deploy ------------------------------------------------------

if [[ "${SKIP_CDK:-0}" == "1" ]]; then
  warn "SKIP_CDK=1 set, skipping CDK deploy."
else
  log "Step 3/4: cdk deploy (this takes ~20 min for the EKS cluster)"
  cdk_args=(--require-approval never)
  if [[ -n "$NAME_SUFFIX" ]]; then
    cdk_args+=(-c "nameSuffix=$NAME_SUFFIX")
  fi
  npx cdk deploy "${cdk_args[@]}"
fi

# --- step 4: cloudformation deploy ------------------------------------------

if [[ "${SKIP_CFN:-0}" == "1" ]]; then
  warn "SKIP_CFN=1 set, skipping CloudFormation deploy."
else
  # ---- 4a: prepare the devops-agent-sdk Lambda layer artifact ----
  # The Lambda runtime's bundled boto3 doesn't include the `devops-agent`
  # service model yet. The layer ships only the botocore model JSON (~26 KB).
  # See lambda-layers/devops-agent-sdk/README.md for details.
  LAYER_DIR="lambda-layers/devops-agent-sdk"
  LAYER_ZIP="$LAYER_DIR/layer.zip"
  if [[ ! -f "$LAYER_ZIP" ]]; then
    log "Step 4a/4: building Lambda layer ($LAYER_ZIP not found)"
    "$LAYER_DIR/build.sh"
  else
    log "Step 4a/4: reusing existing $LAYER_ZIP"
  fi

  # Resolve the CDK assets bucket — it already exists in every account where
  # `cdk bootstrap` has run. Avoids creating a new bucket just for one zip.
  ASSETS_BUCKET="$(aws cloudformation describe-stacks \
    --stack-name CDKToolkit \
    --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" \
    --output text 2>/dev/null || true)"
  if [[ -z "$ASSETS_BUCKET" || "$ASSETS_BUCKET" == "None" ]]; then
    die "Could not resolve the CDK assets bucket from CDKToolkit stack outputs. Run 'npx cdk bootstrap' first."
  fi

  # Content-addressable S3 key — re-uploads are idempotent, and the artifact
  # in S3 can be hash-audited by inspecting the key.
  LAYER_SHA="$(shasum -a 256 "$LAYER_ZIP" | awk '{print $1}')"
  LAYER_KEY="lambda-layers/devops-agent-sdk/layer-${LAYER_SHA}.zip"

  log "Step 4b/4: uploading layer to s3://$ASSETS_BUCKET/$LAYER_KEY"
  aws s3 cp "$LAYER_ZIP" "s3://$ASSETS_BUCKET/$LAYER_KEY" \
    --region "$REGION" \
    --no-progress

  log "Step 4c/4: aws cloudformation deploy ($STACK_NAME)"
  cfn_params=(
    "DevOpsAgentSdkLayerBucket=$ASSETS_BUCKET"
    "DevOpsAgentSdkLayerKey=$LAYER_KEY"
  )
  [[ -n "$NAME_SUFFIX" ]] && cfn_params+=("NameSuffix=$NAME_SUFFIX")
  [[ -n "$GITHUB_REPO" ]]  && cfn_params+=("GitHubRepo=$GITHUB_REPO")

  # The template is well past the 51,200-byte inline limit on the
  # CloudFormation CreateChangeSet/UpdateStack APIs (the inline Lambdas
  # alone are ~30 KB). `aws cloudformation deploy --s3-bucket` auto-uploads
  # the template to S3 and switches to --template-url internally, which
  # raises the cap to 460,800 bytes. Reusing the CDK assets bucket avoids
  # provisioning yet another S3 bucket; the --s3-prefix keeps the CFN
  # template artifact separate from the Lambda layer artifact in the
  # bucket so it's easy to audit.
  cfn_cmd=(aws cloudformation deploy
    --template-file "$CFN_TEMPLATE"
    --stack-name "$STACK_NAME"
    --capabilities CAPABILITY_NAMED_IAM
    --region "$REGION"
    --s3-bucket "$ASSETS_BUCKET"
    --s3-prefix cloudformation-templates
    --parameter-overrides "${cfn_params[@]}")
  "${cfn_cmd[@]}"
fi

# --- resolved names (for the remaining manual steps) ------------------------

if [[ -n "$NAME_SUFFIX" ]]; then
  CLUSTER_NAME="eks-upgrade-poc-$NAME_SUFFIX"
  HEALTH_LAMBDA="devops-agent-health-event-$NAME_SUFFIX"
  WEBHOOK_SECRET="devops-agent/webhook-credentials-$NAME_SUFFIX"
  GITHUB_PAT_SECRET="devops-agent/github-pat-$NAME_SUFFIX"
else
  CLUSTER_NAME="eks-upgrade-poc"
  HEALTH_LAMBDA="devops-agent-health-event"
  WEBHOOK_SECRET="devops-agent/webhook-credentials"
  GITHUB_PAT_SECRET="devops-agent/github-pat"
fi

# --- done --------------------------------------------------------------------

log "Bootstrap complete."
cat <<EOF

Resolved resource names for this deployment:
  Cluster:           $CLUSTER_NAME
  Health Lambda:     $HEALTH_LAMBDA
  Webhook secret:    $WEBHOOK_SECRET
  GitHub PAT secret: $GITHUB_PAT_SECRET

Next steps (still manual — see README for details):

  1. Configure the DevOps Agent webhook (console → Capabilities → Webhook)
     and update the secret:
       aws secretsmanager update-secret \\
         --secret-id $WEBHOOK_SECRET \\
         --secret-string '{"url":"<WEBHOOK_URL>","secret":"<HMAC_SECRET>"}'

  2. Store the GitHub PAT:
       aws secretsmanager update-secret \\
         --secret-id $GITHUB_PAT_SECRET \\
         --secret-string '<YOUR_GITHUB_PAT>'

  3. Add KIRO_API_KEY to GitHub repo secrets.

  4. Upload skills/eks-upgrade-planning.zip to the agent space.

  5. Smoke-test with: aws lambda invoke --function-name $HEALTH_LAMBDA ...

EOF
