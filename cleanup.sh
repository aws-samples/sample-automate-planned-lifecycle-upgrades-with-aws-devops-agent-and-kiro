#!/usr/bin/env bash
#
# cleanup.sh — tear down everything bootstrap.sh created.
#
# Reverses the bootstrap order:
#   1. Delete CFN stack (DevOpsAgentStack) — removes AWS DevOps Agent space,
#      AWS IAM roles, Amazon EventBridge rules, both lambdas, the
#      upgrade-failure detector, plus both Secrets Manager secrets.
#   2. Force-delete the secrets (no recovery window) so the names are
#      immediately reusable if you re-run bootstrap.sh later.
#   3. Delete CDK stack (EksUpgradePocStack) — removes the EKS cluster,
#      addons, node group, and VPC. This is the slow step (~10-15 min).
#
# NOT touched (intentional):
#   - CDK bootstrap stack (CDKToolkit). Account-wide, likely shared.
#   - GitHub repo secrets (KIRO_API_KEY, AWS_DEPLOY_ROLE_ARN). Manage via
#     GitHub UI or `gh secret delete`.
#   - Uploaded DevOps Agent skills. Removed automatically when the agent
#     space is deleted.
#
# Usage:
#   ./cleanup.sh                    # uses current AWS CLI profile/region
#   NAME_SUFFIX=alice ./cleanup.sh  # tear down a suffixed deployment
#   AWS_PROFILE=my-profile ./cleanup.sh
#   AWS_REGION=us-east-1 ./cleanup.sh
#   STACK_NAME=MyDevOpsAgentStack ./cleanup.sh
#   SKIP_CFN=1 ./cleanup.sh         # skip CFN teardown (already gone)
#   SKIP_CDK=1 ./cleanup.sh         # skip CDK teardown (already gone)

set -euo pipefail

NAME_SUFFIX="${NAME_SUFFIX:-}"

# --- helpers -----------------------------------------------------------------

log()  { printf '\033[1;34m[cleanup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[cleanup]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[cleanup]\033[0m %s\n' "$*" >&2; exit 1; }

# ANSI color codes for the confirmation banner. Pre-computed so the heredoc
# below references plain variables instead of inline command substitutions.
RED_BOLD=$'\033[1;31m'
YELLOW_BOLD=$'\033[1;33m'
COLOR_RESET=$'\033[0m'

require() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

# --- preflight ---------------------------------------------------------------

log "Checking prerequisites..."
require aws

aws sts get-caller-identity >/dev/null 2>&1 \
  || die "AWS CLI is not configured. Run 'aws configure' or export AWS_PROFILE."

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region || echo '')}}"
[[ -n "$REGION" ]] || die "No AWS region set. Export AWS_REGION or configure a default."

# Validate suffix with the same rules bootstrap.sh uses
if [[ -n "$NAME_SUFFIX" ]]; then
  if ! [[ "$NAME_SUFFIX" =~ ^[a-z0-9-]{1,20}$ ]]; then
    die "Invalid NAME_SUFFIX '$NAME_SUFFIX'. Use 1-20 chars, lowercase alphanumeric or hyphens."
  fi
fi

# Resolve target names (matching bootstrap.sh conventions)
if [[ -n "$NAME_SUFFIX" ]]; then
  CFN_STACK_NAME="${STACK_NAME:-DevOpsAgentStack-$NAME_SUFFIX}"
  CDK_STACK_NAME="EksUpgradePocStack-$NAME_SUFFIX"
  WEBHOOK_SECRET="devops-agent/webhook-credentials-$NAME_SUFFIX"
  PAT_SECRET="devops-agent/github-pat-$NAME_SUFFIX"
else
  CFN_STACK_NAME="${STACK_NAME:-DevOpsAgentStack}"
  CDK_STACK_NAME="EksUpgradePocStack"
  WEBHOOK_SECRET="devops-agent/webhook-credentials"
  PAT_SECRET="devops-agent/github-pat"
fi

# --- confirmation ------------------------------------------------------------

printf '\n%s\n\n' "${RED_BOLD}⚠  This will permanently delete:${COLOR_RESET}"
cat <<EOF
  Account:        $ACCOUNT_ID
  Region:         $REGION
  Suffix:         ${NAME_SUFFIX:-<none>}

  CFN stack:      $CFN_STACK_NAME
                  └─ DevOps Agent space, IAM roles, EventBridge rules,
                     3 lambdas (health/trigger/upgrade-failure), secrets

  CDK stack:      $CDK_STACK_NAME
                  └─ EKS cluster, addons, node group, VPC, ALB controller

  Secrets:        $WEBHOOK_SECRET
                  $PAT_SECRET
                  (force-deleted, no recovery window)
EOF
printf '\n%s\n\n' "${YELLOW_BOLD}This is irreversible. The EKS cluster deletion alone takes ~10-15 min.${COLOR_RESET}"

read -r -p "Type 'yes' to proceed: " confirm
if [[ "$confirm" != "yes" ]]; then
  warn "Aborted — nothing was deleted."
  exit 0
fi

# --- step 1: delete CFN stack ------------------------------------------------

if [[ "${SKIP_CFN:-0}" == "1" ]]; then
  warn "SKIP_CFN=1 set, skipping CloudFormation teardown."
else
  if aws cloudformation describe-stacks \
       --stack-name "$CFN_STACK_NAME" \
       --region "$REGION" >/dev/null 2>&1; then
    log "Step 1/3: deleting CFN stack $CFN_STACK_NAME"
    aws cloudformation delete-stack \
      --stack-name "$CFN_STACK_NAME" \
      --region "$REGION"
    log "  waiting for delete (may take a few minutes)..."
    aws cloudformation wait stack-delete-complete \
      --stack-name "$CFN_STACK_NAME" \
      --region "$REGION" \
      || warn "  stack-delete-complete wait returned non-zero (may already be deleted)"
    log "  CFN stack deleted."
  else
    log "Step 1/3: CFN stack $CFN_STACK_NAME not found, skipping."
  fi
fi

# --- step 2: force-delete secrets -------------------------------------------
# The CFN deletion above schedules secrets for deletion in 30 days by default.
# Force-delete them now so the names are immediately reusable.

log "Step 2/3: force-deleting Secrets Manager secrets"
for secret in "$WEBHOOK_SECRET" "$PAT_SECRET"; do
  # describe-secret returns 200 even for secrets scheduled for deletion, so we
  # check both "exists" and "not already gone".
  if aws secretsmanager describe-secret \
       --secret-id "$secret" \
       --region "$REGION" >/dev/null 2>&1; then
    log "  force-deleting $secret"
    aws secretsmanager delete-secret \
      --secret-id "$secret" \
      --force-delete-without-recovery \
      --region "$REGION" \
      --query 'Name' --output text >/dev/null \
      || warn "    delete failed (continuing)"
  else
    log "  $secret not found, skipping."
  fi
done

# --- step 3: delete CDK stack ------------------------------------------------

if [[ "${SKIP_CDK:-0}" == "1" ]]; then
  warn "SKIP_CDK=1 set, skipping CDK teardown."
else
  if aws cloudformation describe-stacks \
       --stack-name "$CDK_STACK_NAME" \
       --region "$REGION" >/dev/null 2>&1; then
    log "Step 3/3: deleting CDK stack $CDK_STACK_NAME (EKS cluster teardown, ~10-15 min)"
    # Use cdk destroy when available — it handles CDK-specific quirks. Fall
    # back to raw CFN delete if cdk isn't on the PATH.
    if [[ -f package.json ]] && command -v npx >/dev/null 2>&1; then
      cdk_args=(--force)
      if [[ -n "$NAME_SUFFIX" ]]; then
        cdk_args+=(-c "nameSuffix=$NAME_SUFFIX")
      fi
      npx cdk destroy "${cdk_args[@]}" "$CDK_STACK_NAME" \
        || warn "  cdk destroy failed; falling back to cloudformation delete-stack"
    else
      aws cloudformation delete-stack \
        --stack-name "$CDK_STACK_NAME" \
        --region "$REGION"
      log "  waiting for delete (this is the slow step)..."
      aws cloudformation wait stack-delete-complete \
        --stack-name "$CDK_STACK_NAME" \
        --region "$REGION" \
        || warn "  stack-delete-complete wait returned non-zero (may already be deleted)"
    fi
    log "  CDK stack deleted."
  else
    log "Step 3/3: CDK stack $CDK_STACK_NAME not found, skipping."
  fi
fi

# --- done --------------------------------------------------------------------

log "Cleanup complete."
cat <<EOF

What was NOT touched (manage separately if needed):

  • CDK bootstrap stack (CDKToolkit) — account-wide, likely shared with
    other projects.
  • GitHub repo secrets (KIRO_API_KEY, AWS_DEPLOY_ROLE_ARN) — delete via
    the GitHub UI or 'gh secret delete <name>'.
  • Merged upgrade PRs on your fork — standard git cleanup applies.

If you plan to redeploy later, just run './bootstrap.sh' again. Secrets and
stack names are immediately reusable.

EOF
