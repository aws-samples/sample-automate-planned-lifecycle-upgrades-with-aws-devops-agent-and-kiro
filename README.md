# Amazon EKS Automated Upgrade Pipeline

> **Sample code.** This repository is a proof of concept provided for demonstration and educational purposes. It is not a finished product and must not be deployed as-is — review, security-assess, test, and harden it against your own requirements first. See [DISCLAIMER.txt](DISCLAIMER.txt) for the full text and [Known limitations](#known-limitations) for specific gaps.

Automated Amazon EKS upgrade pipeline: AWS CDK provisions an Amazon EKS cluster → AWS DevOps Agent investigates upgrade feasibility → AWS Lambda bridges results to GitHub Actions via Amazon EventBridge → Kiro CLI headless mode applies CDK changes → PR created for human review.

AWS Health detects that a cluster is approaching end-of-support, the AWS DevOps Agent plans the upgrade using a structured skill, and Kiro CLI opens a pull request with the CDK changes. A human reviews and merges. A daily automated review keeps skills aligned with the latest AWS EKS capabilities.

## Architecture at a glance

```
AWS Health → EventBridge → Health Lambda → DevOps Agent (upgrade-planning investigation)
                                              ↓
                                     EventBridge → Trigger Lambda
                                              ↓ ListJournalRecords
                                     GitHub Actions (eks-upgrade.yml) → Kiro CLI → CDK PR

Real-cluster failure (CFN rollback)
   → Failure Lambda → webhook to SAME agent space (root cause via eks-failure-root-cause skill)
       triage skill ensures no linking to upgrade investigations
       agent produces Root Cause → Investigation Completed event
       → Trigger Lambda → update_backlog_task(PENDING_START) → schedules 3-min check
       → Mitigation Agent runs (~2 min) → produces execution plan + agent-ready spec
       → Scheduled check fires → Trigger Lambda:
         ├─→ Extracts agent-ready spec → dispatches next-steps.yml → Kiro implements in CDK → code fix PR
         └─→ Extracts execution plan → publishes to SNS (formatted email with call-to-action)

Daily skill review (automated maintenance)
   → EventBridge Rule (08:00 UTC cron) → Skill Review Lambda
       fetches current SKILL.md files from GitHub, posts webhook
       → DevOps Agent runs eks-skill-review skill
       → Investigation Completed event → Trigger Lambda:
         IF changes found:
           ├─→ Dispatches skill-update.yml → Kiro applies edits → skill update PR
           └─→ Publishes to SNS (skill-update-notifications topic)
         IF no changes: logs and exits silently
```

See [`docs/architecture-diagram.md`](docs/architecture-diagram.md) for sequence and component diagrams, and [`docs/event-workflow.md`](docs/event-workflow.md) for a full step-by-step walkthrough.

### Known limitations

This is a proof of concept. Three things are worth hardening before running it anywhere that matters:

- **Log groups use default encryption, not a customer-managed key.** Neither `EventBridgeLogGroup` nor the implicit Lambda log groups specify `KmsKeyId`, so they fall back to the AWS-owned key. The contents are operational metadata — cluster names and ARNs, task and execution IDs, and the full matched EventBridge event — rather than secrets, but a regulated environment will want `KmsKeyId` set explicitly.
- **The Kiro CLI install isn't integrity-checked.** The workflows `curl` the installer from `https://cli.kiro.dev/install` and run it, asserting only a minimum version afterwards — a compromised CDN could serve a different binary. Pin a specific version and verify a checksum for production pipelines.
- **The agent's read access is account-wide.** The investigation role grants read-only EKS, CloudFormation, and CloudTrail actions (`eks:Describe*`/`List*`, `cloudformation:Describe*`/`Get*`/`List*`, `cloudtrail:LookupEvents`) against `Resource: '*'`, since the cluster to investigate isn't known until a Health event arrives. Nothing here can mutate infrastructure, but narrow the resource scope before pointing this at an account whose stack templates you don't want the agent reading.

The pipeline ends at PR creation and human merge.

## Repo layout

| Path | Purpose |
|---|---|
| `bin/iteration3.ts` | CDK app entry point |
| `lib/iteration3-stack.ts` | EKS cluster, node group, addons, ALB controller Helm chart |
| `devops-agent-space.yaml` | CFN template: single agent space, IAM, EventBridge rules, inline Lambdas, secrets |
| `lambda-layers/devops-agent-sdk/` | Botocore service model layer (`service-model/` + `build.sh`) so the Trigger Lambda can call the `devops-agent` service. Needed only while the Lambda runtime's bundled boto3 lacks that service model — see the layer's [README](lambda-layers/devops-agent-sdk/README.md#when-to-remove-this-layer) for how to check and how to drop it |
| `skills/eks-upgrade-planning/SKILL.md` | AWS DevOps Agent skill: 7-step upgrade investigation (scoped to Incident RCA) |
| `skills/eks-failure-root-cause/SKILL.md` | AWS DevOps Agent skill: failure root cause analysis (scoped to Incident RCA) |
| `skills/eks-investigation-triage-rules/SKILL.md` | AWS DevOps Agent skill: triage rules preventing cross-linking (scoped to Incident Triage) |
| `skills/eks-skill-review/SKILL.md` | AWS DevOps Agent skill: daily skill review for gaps and outdated info (scoped to Incident RCA) |
| `instructions/global-instructions.md` | Global Instructions for all agent types (upload to Knowledge > Instructions > All agents) |
| `instructions/mitigation-agent-instructions.md` | Incident Mitigation agent-specific instructions (upload to Knowledge > Instructions > Incident Mitigation) |
| `.github/workflows/eks-upgrade.yml` | GitHub Actions workflow: Kiro CLI → CDK upgrade PR |
| `.github/workflows/next-steps.yml` | GitHub Actions workflow: Kiro CLI → agent-ready spec PR (post-failure, post-mitigation) |
| `.github/workflows/skill-update.yml` | GitHub Actions workflow: Kiro CLI → skill update PR (daily review) |
| `.github/workflows/eks-deploy.yml` | GitHub Actions workflow: post-merge `cdk deploy` with investigation tag |
| `kiro-cdk-instructions.md` | Prescriptive instructions for Kiro CLI editing CDK code |


## Zero-to-complete setup

Follow these steps to deploy the complete Amazon EKS automated upgrade pipeline from scratch. The process takes approximately 30 minutes and includes CDK deployment, agent space configuration, and GitHub Actions setup.

### Prerequisites

> **Cost warning:** Deploying this pipeline creates billable AWS resources including an Amazon EKS cluster control plane, Amazon EC2 instances for node groups, AWS Lambda functions, Amazon CloudWatch Logs, AWS Secrets Manager secrets, and other services. Refer to the [AWS Pricing](https://aws.amazon.com/pricing/) pages for current rates. Run `./cleanup.sh` when done to avoid ongoing charges.

- AWS account with CDK bootstrapped (the bootstrap script handles this if needed)
- A GitHub repo you control — fork this one, or clone it and push to your own remote. The pipeline dispatches workflows against *your* copy, so it can't be the upstream repo.
- GitHub PAT with `repo` and `actions` scopes
- Kiro CLI API key (for GitHub Actions)
- AWS CLI configured with a profile that has admin access

### Step 1: Clone your fork

Substitute your own owner and repository name throughout — the pipeline opens pull
requests against the repo you deploy from, so every example below refers to *your*
copy, not the upstream one.

```bash
git clone https://github.com/<your-org>/<your-repo>.git
cd <your-repo>
```

### Step 2: Run the bootstrap script

```bash
./bootstrap.sh
```

This runs steps that used to be manual:

1. `npm install`
2. `cdk bootstrap` (only if the target account/region isn't already bootstrapped)
3. `cdk deploy` — VPC, EKS cluster (v1.30), node group, 3 managed addons (vpc-cni, kube-proxy, coredns), and the AWS Load Balancer Controller Helm chart (~20 min)
4. Builds and uploads the `devops-agent-sdk` Lambda layer (botocore service model JSON for the `devops-agent` API — see `lambda-layers/devops-agent-sdk/README.md`), then `aws cloudformation deploy` — DevOps Agent space, IAM roles, EventBridge rules, three Lambda functions (Health, Trigger, Failure), the Lambda layer, and Secrets Manager secrets. The CFN template is over CloudFormation's 51,200-byte inline limit (mostly because the three Lambdas ship inline), so `bootstrap.sh` passes `--s3-bucket` to `aws cloudformation deploy` and the CLI auto-uploads the template to the CDK assets bucket under `cloudformation-templates/` before invoking the API. No new bucket is provisioned

Optional env vars: `AWS_PROFILE`, `AWS_REGION`, `STACK_NAME` (defaults to `DevOpsAgentStack`), `NAME_SUFFIX` (see below), `GITHUB_REPO` (passed to CFN as `GitHubRepo`), `SKIP_CDK=1`, `SKIP_CFN=1`.

#### Deploying multiple copies in the same account/region

Every named resource (EKS cluster, IAM roles, Lambdas, EventBridge rules, secrets, CFN stack, CDK stack) is suffixed when you set `NAME_SUFFIX`. This lets you run side-by-side deployments without name collisions:

```bash
NAME_SUFFIX=alice ./bootstrap.sh
NAME_SUFFIX=bob   ./bootstrap.sh
```

The suffix must be 1-20 chars, lowercase alphanumeric or hyphens. It's threaded through both CDK (via `-c nameSuffix=...`) and CFN (via the `NameSuffix` parameter). The script prints the resolved resource names at the end so you can copy-paste them into the remaining manual steps.

**Failure events are scoped per deployment.** The `eks-cfn-stack-failure` EventBridge rule subscribes to CloudFormation Stack Status Change events, which are account-wide — the event pattern can't filter by stack. Each deployment gets its own copy of the rule, so a single rollback is delivered to *every* deployment's Failure Lambda. The Failure Lambda therefore drops any rollback whose stack name doesn't exactly match its own `ROOT_STACK_PREFIX` (`EksUpgradePocStack-<suffix>`, set automatically from `NameSuffix`). Without that guard, one failed deploy would open an investigation in every agent space and produce a duplicate mitigation PR from each — the dispatch lock can't dedupe them because each space mints a different `task_id`.

Nothing to configure; it works out of the box. Two things to know:

- If you rename the CDK stack, keep `NameSuffix`/`ROOT_STACK_PREFIX` in step with it or the guard will silently drop every failure event.
- Dropped events log which deployment owns the stack, so a "why didn't my investigation open?" question is one log query away:

  ```
  Ignoring rollback for stack EksUpgradePocStack-t19: this deployment owns
  EksUpgradePocStack-t18. Another deployment's failure detector handles it.
  ```

The health-event path is deliberately *not* scoped this way — `AWS_EKS_PLANNED_LIFECYCLE_EVENT` should reach the agent for any cluster in the account, which is what keeps the pipeline generic across clusters.

### Step 3: Generate and configure the AWS DevOps Agent webhook

The Health Lambda posts a signed incident payload to a **generic webhook** on your agent space. Generic webhooks use HMAC-SHA256 authentication — bearer tokens aren't supported today. ([AWS docs: Invoking DevOps Agent through Webhook](https://docs.aws.amazon.com/devopsagent/latest/userguide/configuring-capabilities-for-aws-devops-agent-invoking-devops-agent-through-webhook.html))

**Generate the webhook in the console**

1. Go to the AWS DevOps Agent console: https://console.aws.amazon.com/devopsagent
2. Select your agent space:
   - Default deployment: `eks-upgrade-poc`
   - Suffixed deployment: `eks-upgrade-poc-<suffix>` (the `bootstrap.sh` output printed the exact name)
3. Open the **Capabilities** tab
4. Find the **Webhook** section and choose **Generate webhook** (or **Add webhook → Generic**)
5. Fill in the form:
   - **Name**: something recognisable, e.g. `eks-health-events`
   - **Agent type**: **Incident** (this is what the Health Lambda payload maps to — `eventType: "incident"`)
   - **Authentication**: **HMAC** (the only option for generic webhooks right now)
6. Choose **Generate**. The console shows two values **once**:
   - **Webhook URL** (HTTPS endpoint the Lambda POSTs to)
   - **HMAC secret** (used to sign the payload)

   Copy both immediately — you can't retrieve the secret later. If you lose it, regenerate the webhook and rerun step 7 below.

**Store the credentials in Secrets Manager**

The CFN template pre-created an empty secret that the Health Lambda reads on every invocation. Update it with the real values.

For a default deployment:

```bash
aws secretsmanager update-secret \
  --secret-id devops-agent/webhook-credentials \
  --secret-string '{"url":"<WEBHOOK_URL>","secret":"<HMAC_SECRET>"}'
```

For a suffixed deployment (`NAME_SUFFIX=alice`):

```bash
aws secretsmanager update-secret \
  --secret-id devops-agent/webhook-credentials-alice \
  --secret-string '{"url":"<WEBHOOK_URL>","secret":"<HMAC_SECRET>"}'
```

`bootstrap.sh` prints the exact secret name at the end of its run. The JSON shape is what `HealthEventLambda` expects (`creds['url']` + `creds['secret']`) — don't rename the keys.

**Verify it's wired up**

Quick sanity-check that Secrets Manager has real values (not the `PLACEHOLDER` string the template ships with):

```bash
aws secretsmanager get-secret-value \
  --secret-id devops-agent/webhook-credentials \
  --query 'SecretString' --output text | python3 -m json.tool
```

You should see a JSON object with a real `https://...` URL and a non-placeholder secret. The end-to-end test in Step 7 will then exercise the full webhook path and the DevOps Agent will appear in your **Backlog** tab with a new investigation.

**How the signing works** (for debugging)

The Health Lambda signs every request like this:

- Header `x-amzn-event-timestamp`: ISO-8601 UTC timestamp
- Header `x-amzn-event-signature`: `base64(HMAC-SHA256(secret, "<timestamp>:<payload>"))`
- Body: `Content-Type: application/json`

If the DevOps Agent returns 401/403 on the webhook call, it's almost always a stale/wrong HMAC secret in Secrets Manager — regenerate the webhook and update the secret again.

### Step 3b: (No longer needed — single webhook)

Both the Health Lambda and Failure Lambda now POST to the **same webhook** on the single agent space. The webhook credentials you configured in Step 3 cover both. The triage skill (`eks-investigation-triage-rules`) ensures the agent never links failure investigations to upgrade-planning investigations within the same space.

### Step 4: Create and store the GitHub PAT

The Trigger Lambda needs a PAT to call `workflow_dispatch` on `eks-upgrade.yml` (CDK PR after upgrade-planning) and on `next-steps.yml` (code fix PR after mitigation). Both workflows live in this repo so a single PAT covers both — but the scopes need to be repo-wide on Actions, not workflow-specific.

**Option A: Fine-grained token (recommended, single repo only)**

1. Go to https://github.com/settings/personal-access-tokens/new
2. **Token name**: `devops-agent-eks-upgrade`
3. **Expiration**: pick something you're comfortable rotating (90 days is a reasonable default)
4. **Repository access**: **Only select repositories** → pick your fork (`<your-org>/<your-repo>`)
5. **Repository permissions** — grant these (Read and write):
   - **Actions**: Read and write (required for `workflow_dispatch` on both `eks-upgrade.yml` and `next-steps.yml`)
   - **Contents**: Read and write (needed by the Kiro CLI step to push a branch)
   - **Pull requests**: Read and write (needed to create the PR)
6. Choose **Generate token** and copy the value (starts with `github_pat_`). You won't see it again.

**Store it in Secrets Manager**

```bash
aws secretsmanager update-secret \
  --secret-id devops-agent/github-pat \
  --secret-string '<PASTE_TOKEN_HERE>'
```

If you deployed with `NAME_SUFFIX`, the secret is `devops-agent/github-pat-<suffix>` — `bootstrap.sh` prints the exact name at the end.

### Step 4a: Subscribe to the mitigation notification SNS topic (optional but recommended)

When a mitigation plan completes, the Trigger Lambda publishes the agent's `## Immediate Steps` section to the SNS topic `eks-upgrade-failure-mitigation` (or `eks-upgrade-failure-mitigation-<suffix>` if you used `NAME_SUFFIX`). The message tells the responder to take the immediate steps first, then review and merge the Next Steps Agent-ready Spec PR that opens on the repo in parallel. Subscribe whatever channel your on-call uses.

The topic ARN is in the `MitigationNotificationTopicArn` CloudFormation output — `bootstrap.sh` prints it at the end. Or look it up:

```bash
aws cloudformation describe-stacks \
  --stack-name DevOpsAgentStack \
  --query 'Stacks[0].Outputs[?OutputKey==`MitigationNotificationTopicArn`].OutputValue' \
  --output text
```

**Email subscription (simplest):**

```bash
aws sns subscribe \
  --topic-arn <topic-arn-from-output> \
  --protocol email \
  --notification-endpoint oncall@example.com
```

You'll receive a confirmation email — click the link to start receiving notifications.

**Slack via webhook (Slack-channel subscription):**

Create an incoming webhook in Slack, then either subscribe a Lambda that reposts to Slack, or use AWS Chatbot if your workspace already has it configured. The default email subscription is enough for most teams while you're getting started.

**SMS / PagerDuty / etc.:** all standard SNS subscription protocols are supported. See the [SNS subscriptions docs](https://docs.aws.amazon.com/sns/latest/dg/sns-create-subscribe-endpoint-to-topic.html).

### Step 5: Create and add the Kiro API key to GitHub

The GitHub Actions workflow runs Kiro CLI in headless mode, which needs an API key.

**Prerequisites:** API keys require a **Kiro Pro, Pro+, or Power** subscription. If your subscription is managed by an administrator, they need to [enable API key generation](https://kiro.dev/docs/cli/enterprise/governance/api-keys/) first.

**Create the key**

1. Sign in to the Kiro portal: https://app.kiro.dev
2. Navigate to the **API Keys** section
3. Choose **Create API key**, give it a meaningful name like `eks-upgrade-pipeline`, and copy the value (starts with `ksk_`). The full key is shown once at creation time only.

**Add it to GitHub**

1. In your GitHub repo → **Settings → Secrets and variables → Actions → New repository secret**
2. **Name**: `KIRO_API_KEY`
3. **Value**: paste the `ksk_...` key
4. Choose **Add secret**

The workflow reads this via `env: KIRO_API_KEY: ${{ secrets.KIRO_API_KEY }}` before calling `kiro-cli chat --no-interactive`. Treat the key like a long-lived credential — rotate it on your usual cadence and revoke it from the Kiro portal if it leaks. ([Kiro docs: API key authentication](https://kiro.dev/docs/cli/authentication#authenticate-with-an-api-key-headless-mode))

### Step 5a: How the upgrade workflow guards against missing findings

The `eks-upgrade.yml` workflow writes the investigation findings to a file and validates the CDK Change Spec **before** running Kiro CLI. It extracts every fenced code block containing `CLUSTER_VERSION`, validates each against a strict contract, and requires exactly one survivor. This guard exists because Kiro runs in `--no-interactive` mode with `--trust-tools=read,write,glob,grep` — it cannot execute shell commands, so it can only read the findings if they're on disk (not in an environment variable). If the spec is missing (the agent didn't emit one, or the findings weren't passed through), the workflow **fails the run** instead of letting Kiro guess a version — a bad investigation never silently produces a guessed upgrade PR.

There's nothing to configure for this guard. When the Trigger Lambda dispatches `eks-upgrade.yml`, **monitor the run in your repo's Actions tab** (GitHub → **Actions** → *EKS Upgrade*):

- **Green run** → the CDK Change Spec was found, Kiro applied it, and an upgrade PR was opened for review.
- **Failed run** → the guard stopped the pipeline. The failed step's log shows the cluster name and investigation task ID; open the DevOps Agent console to inspect the investigation, then re-run the workflow manually once resolved.

Set up GitHub's built-in [workflow notifications](https://docs.github.com/en/account-and-profile/managing-subscriptions-and-notifications-on-github/setting-up-notifications/configuring-notifications#github-actions-notifications) (email/web/mobile on failed runs) if you want to be alerted without watching the Actions tab.

`next-steps.yml` has the equivalent guard for the mitigation path: it looks for a `# Agent-ready spec` block (with `## Change requirements`) first, then falls back to a `## Mitigation Plan` / `# Mitigation Summary` section, and stops the run with `Mitigation pipeline STOPPED — no actionable mitigation spec found in findings` if neither is present.

Where these guards match markdown headings, they match at **start of line only**. Agents echo `SKILL.md` and other instruction-file content that *describes* this contract in prose — "emit a `` `## Mitigation Plan` `` block…" — and an unanchored match latches onto that backtick-quoted reference instead of the real heading, slicing the payload mid-sentence. `next-steps.yml` and the Lambda's `_extract_actionable_content` are two halves of one contract; if you change one, change both. (`eks-upgrade.yml` keys off fenced blocks containing `CLUSTER_VERSION` rather than headings, so it isn't affected.) See [docs/event-workflow.md](docs/event-workflow.md#heading-anchoring-why-markers-must-be-at-start-of-line) for the full reasoning.

### Why the spec is validated before Kiro runs

The same validator also enforces `FEASIBILITY: READY`. This is a **hard gate**: any
other value stops the pipeline before Kiro runs, so no PR is generated. That makes
`FEASIBILITY` the highest-consequence field in the spec, and it is the agent's
judgement call rather than an API lookup — which is exactly why the skill spells
out what may and may not set it.

The failure mode is subtle: the agent resolves every version correctly, then blocks
itself on a real-but-non-blocking observation. It happened with the node group's
AMI type — `NEEDS_REMEDIATION` with `BLOCKERS: Node group AMI type must be migrated
from AL2_x86_64 to AL2023_x86_64_STANDARD before node upgrade`. The advice was
sound (see issue #150) but the verdict was wrong: an AL2 AMI exists for the target
version, and AMI type is orthogonal to the Kubernetes version, so it can change
before or after the upgrade and never has to gate it.

What makes this recur is that `Amazon Linux 2 compatibility` reports `ERROR` on any
AL2 node group whether or not a target AMI exists — it is a lifecycle statement,
not an upgrade-readiness verdict. On a cluster with AL2 nodes that insight is a
permanent `ERROR`, so the same cluster can produce opposite verdicts on two runs an
hour apart.

`skills/eks-upgrade-planning/SKILL.md` Step 8 therefore enumerates what must never
block — node group AMI type and AL2 deprecation, insights in `ERROR`/`UNKNOWN`,
Helm chart version, and `NOT_INSTALLED` components — and gives an escape hatch for
anything unlisted: emit the spec with every version resolved, `FEASIBILITY: READY`,
`RISK: HIGH`, and the concern described in the risks section. A human reviews every
generated PR, so a flagged risk is seen; a `NEEDS_REMEDIATION` halts the pipeline
before a PR exists. If you add a rule here, keep the `BLOCKERS`/`READY` coupling
intact: `BLOCKERS` must be `NONE` whenever `FEASIBILITY` is `READY`.

This is a prompt-level fix, so it is probabilistic — it removes a specific
ambiguity but cannot guarantee the agent never invents a different blocker. The
validation gate stays as the backstop, which is the right trade: a false stop costs
a re-run, a false start would open a PR against an unresolved spec.

### Who owns which file in the upgrade PR

Kiro's remit is **`lib/iteration3-stack.ts` only**, enforced by an allowlist audit
after it runs. `package.json` is changed by a separate workflow step, *after* that
audit, so Kiro's edits are never laundered through the allowlist.

The split exists because the kubectl layer packages are independently versioned
siblings. `@aws-cdk/lambda-layer-kubectl-v30` tops out at `2.0.4` while `-v31`
jumps from `2.0.3` to `2.1.0`, so a version number **never** transfers between
them. Carrying the old pin across produces a version that does not exist:

```
npm error code ETARGET
npm error notarget No matching version found for @aws-cdk/lambda-layer-kubectl-v31@2.0.4.
```

Neither of the two components that could plausibly resolve it is able to:

| Component | Why it cannot resolve the version |
|---|---|
| DevOps Agent | No network-capable tool — AWS APIs and local file reads only. It states this itself during investigations. |
| Kiro CLI | Runs `--trust-tools=read,write,glob,grep`: no shell, no network. The sandbox is load-bearing; it is what makes the allowlist audit meaningful. |

So the spec deliberately carries only the package **name** (`KUBECTL_LAYER_PACKAGE`),
and `npm` resolves the version in the workflow, where it is actually reachable. The
step reads the outgoing package from `package.json` rather than the spec, since it
is whatever kubectl layer is currently pinned.

Two things to preserve if you touch that step:

- **Guard the command substitution explicitly.** `set -e` does *not* abort on a
  failed substitution inside an assignment, so an empty result would turn
  `npm pkg delete dependencies.$OLD` into `npm pkg delete dependencies.` — which
  deletes **every** dependency and exits 0.
- **Do not add a version to the spec** as a way of "fixing" this. The agent has no
  way to resolve one, so it would be a guessed value wearing a validated field's
  clothing.

The mitigation path (`next-steps.yml`) is different by design: its allowlist admits
`lib/iteration3-stack.ts`, `package.json`, and `package-lock.json`, because a
mitigation spec can legitimately require dependency changes that aren't a kubectl
layer swap.

### Step 6: Upload skills and configure instructions

The single agent space uses **Global Instructions**, **agent-type-scoped instructions**, and **four skills** to route and isolate upgrade-planning, failure, and skill-review investigations.

#### Step 6a: Configure Global Instructions

1. Go to the AWS DevOps Agent console: https://console.aws.amazon.com/devopsagent
2. Select your agent space (default: `eks-upgrade-poc`, or `eks-upgrade-poc-<suffix>`)
3. Navigate to **Knowledge → Instructions → All agents**
4. Paste the contents of `instructions/global-instructions.md` (excluding the header comment about where to upload)
5. Save

These rules apply to every session — safety constraints, investigation isolation rules, and output format.

#### Step 6b: Configure Incident Mitigation instructions

1. In the same agent space, navigate to **Knowledge → Instructions → Incident Mitigation**
2. Paste the contents of `instructions/mitigation-agent-instructions.md` (excluding the header comment)
3. Save

These tell the Mitigation Agent what output format downstream automation expects.

#### Step 6c: Upload skills

Upload four skills. Each must be scoped to the correct agent type:

| Skill | Scope to | Purpose |
|---|---|---|
| `skills/eks-upgrade-planning/` | **Incident RCA** | 7-step EKS upgrade investigation producing a CDK Change Spec |
| `skills/eks-investigation-triage-rules/` | **Incident Triage** | Prevents linking upgrade, failure, and review investigations |
| `skills/eks-failure-root-cause/` | **Incident RCA** | Root cause analysis for CloudFormation rollback failures |
| `skills/eks-skill-review/` | **Incident RCA** | Daily review of skills for gaps and outdated information |

For each skill:

1. Zip the skill folder. Delete any existing zip first — `zip -r` *adds to* an
   archive rather than replacing it, so re-running it over an existing zip leaves
   the stale `SKILL.md` inside next to the new one:
   ```bash
   cd skills
   rm -f eks-investigation-triage-rules.zip eks-failure-root-cause.zip eks-skill-review.zip
   zip -qr eks-investigation-triage-rules.zip eks-investigation-triage-rules
   zip -qr eks-failure-root-cause.zip eks-failure-root-cause
   zip -qr eks-skill-review.zip eks-skill-review

   # eks-upgrade-planning.zip stores SKILL.md at the archive ROOT, not nested
   # under a directory — build it from inside the folder to preserve that.
   rm -f eks-upgrade-planning.zip
   cd eks-upgrade-planning && zip -q ../eks-upgrade-planning.zip SKILL.md && cd ..
   cd ..
   ```
   Verify before uploading — `unzip -l <zip>` should list exactly one `SKILL.md`.
2. In the DevOps Agent console → **Settings → Skills → Add Skill → Custom Skill**
3. Upload the zip
4. **Deselect Generic** and select the agent type listed in the table above
5. Save

**If you edit a skill**

`SKILL.md` is the source of truth; the zip is a wrapper. After editing, repack and re-upload — **the agent reads from the uploaded zip, not from the repo**. See the [DevOps Agent Skills docs](https://docs.aws.amazon.com/devopsagent/latest/userguide/about-aws-devops-agent-devops-agent-skills.html) for the full SKILL.md format reference.

### Step 6b: Subscribe to the mitigation SNS topic (optional)

When a failure investigation completes and the Trigger Lambda dispatches `next-steps.yml`, it also publishes the agent's "Immediate Steps" to an SNS topic. Subscribe your email (or a Slack/PagerDuty endpoint) to receive these notifications.

**Find the topic ARN** (printed by `bootstrap.sh`, or query the stack):

```bash
aws cloudformation describe-stacks \
  --stack-name DevOpsAgentStack-t8 \
  --query 'Stacks[0].Outputs[?OutputKey==`MitigationNotificationTopicArn`].OutputValue' \
  --output text --region us-east-1
```

**Subscribe an email address:**

```bash
aws sns subscribe \
  --topic-arn arn:aws:sns:us-east-1:ACCOUNT_ID:eks-upgrade-failure-mitigation-t8 \
  --protocol email \
  --notification-endpoint your-email@example.com \
  --region us-east-1
```

Check your inbox and **confirm the subscription** — AWS sends a confirmation link that you must choose before notifications arrive.

For a Slack channel via AWS Chatbot or a PagerDuty integration, use `--protocol https` with the appropriate webhook URL instead.

### Step 7: Test the pipeline

This step simulates an AWS Health planned-lifecycle event so you can exercise the full chain end-to-end without waiting for EKS to actually approach end-of-support. There are two ways to run it — pick whichever fits your workflow.

**Option A: Drive it with Kiro CLI (fewer moving parts)**

Once Kiro CLI is signed in (or `KIRO_API_KEY` is set), you can hand off the whole test in one prompt:

```bash
kiro-cli chat --trust-tools=shell \
  "Invoke the Lambda function 'devops-agent-health-event' (or 'devops-agent-health-event-<suffix>' if I deployed with a NAME_SUFFIX) with a synthetic AWS Health planned-lifecycle event for the EKS cluster 'eks-upgrade-poc' in us-east-1. Use my AWS account ID. Save the response to /tmp/test-response.json and print it."
```

Kiro CLI figures out the account ID, picks the right Lambda name (default or suffixed), builds the event payload, invokes the function, and shows you the result. If you prefer headless mode (no interactive approvals), swap `--trust-tools=shell` for `--no-interactive --trust-tools=shell` and wrap the prompt in the same quotes.

**Option B: Run the raw `aws lambda invoke` yourself**

```bash
aws lambda invoke \
  --function-name devops-agent-health-event \
  --payload file://<(cat <<'EOF'
{
  "source": "aws.health",
  "detail-type": "AWS Health Event",
  "detail": {
    "eventArn": "arn:aws:health:us-east-1::event/EKS/AWS_EKS_PLANNED_LIFECYCLE_EVENT/TEST_001",
    "service": "EKS",
    "eventTypeCode": "AWS_EKS_PLANNED_LIFECYCLE_EVENT",
    "eventTypeCategory": "scheduledChange",
    "statusCode": "upcoming",
    "eventRegion": "us-east-1",
    "eventDescription": [{"language": "en_US", "latestDescription": "EKS cluster eks-upgrade-poc approaching end of standard support for version 1.30."}],
    "affectedEntities": [{"entityValue": "arn:aws:eks:us-east-1:ACCOUNT_ID:cluster/eks-upgrade-poc", "status": "PENDING"}],
    "affectedAccount": "ACCOUNT_ID"
  }
}
EOF
) /tmp/test-response.json && cat /tmp/test-response.json
```

Replace `ACCOUNT_ID` with your AWS account ID. If you deployed with `NAME_SUFFIX=alice`, change `--function-name` to `devops-agent-health-event-alice`.

**What to expect after it runs**

The Lambda invocation returns almost instantly — but the real signal is downstream. Within a minute or two you should see:

1. A new investigation appear in the DevOps Agent console (Backlog tab)
2. The investigation follow the `eks-upgrade-planning` skill
3. On completion, GitHub Actions start running `eks-upgrade.yml`
4. Kiro CLI inside the workflow edit the CDK code and open a PR

Total runtime is ~15-30 min depending on investigation depth. If nothing happens, check CloudWatch Logs for `devops-agent-health-event` — the most common cause is a stale or placeholder `devops-agent/webhook-credentials` secret from Step 3.

### Step 8: Run the post-merge deploy workflow

Once the upgrade PR has been reviewed and merged, the `eks-deploy.yml` workflow runs `cdk deploy` against the real cluster and tags the CloudFormation stack with the originating investigation's `task_id`.

This step is a manual trigger on purpose: auto-deploying after merge is aggressive for a sample repo, and the human review on the PR is already the gate.

**One-time setup: AWS OIDC deploy role**

The deploy workflow uses GitHub Actions OIDC to assume an AWS role — no long-lived keys in GitHub.

1. In IAM, create a role with a trust policy that allows GitHub Actions from your repo to assume it:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:<owner>/<repo>:ref:refs/heads/main" }
    }
  }]
}
```

2. Attach permissions sufficient for `cdk deploy` against the EKS stack (the CDK bootstrap role is usually enough for sample deployments — scope tighter for production).

3. If you don't already have the `token.actions.githubusercontent.com` OIDC provider in IAM, add it — see [GitHub's OIDC guide](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services) for the one-time global setup.

4. Add the role ARN to GitHub: **Settings → Secrets and variables → Actions → New repository secret**
   - Name: `AWS_DEPLOY_ROLE_ARN`
   - Value: the role ARN from step 1 (e.g. `arn:aws:iam::123456789012:role/GitHubActionsDeployRole`)

5. (Optional) Set a repository variable `AWS_REGION` if your cluster isn't in `us-east-1`.

**Run the deploy workflow**

After merging an upgrade PR:

```bash
# Find the merged PR number
gh pr list --state merged --label eks-upgrade --limit 1

# Trigger the deploy (replace 42 with your PR number)
gh workflow run eks-deploy.yml -f pr_number=42

# Watch it
gh run watch
```

The workflow parses the `<!-- investigation-context-start -->` block from the PR body, extracts the `task_id`, passes it to CDK as context, and CDK applies it as an `InvestigationTaskId` stack tag.

### Step 8b: Test the failure → mitigation path (optional)

This tests the closed-loop failure path: Failure Lambda → root-cause investigation → programmatic `UpdateBacklogTask(PENDING_START)` → Trigger Lambda polls via EventBridge Scheduler → dispatches `next-steps.yml` + SNS.

**Option A: Trigger a real CDN rollback**

Deploy a CDK change that will fail (e.g., an invalid addon version or a version downgrade). The `eks-cfn-stack-failure` EventBridge rule catches the terminal rollback and invokes the Failure Lambda automatically:

```bash
# From a branch with an intentionally bad CDK change (e.g., downgrade from 1.31 to 1.30):
npm install
npx cdk deploy -c nameSuffix=<suffix> --require-approval never
```

The deploy will fail and CFN will emit `UPDATE_ROLLBACK_COMPLETE` (or `UPDATE_ROLLBACK_FAILED`), triggering the Failure Lambda via EventBridge.

**Option B: Invoke the Failure Lambda directly with a synthetic event**

```bash
aws lambda invoke \
  --function-name devops-agent-upgrade-failure-event-<suffix> \
  --payload "$(echo '{
  "source": "aws.cloudformation",
  "detail-type": "CloudFormation Stack Status Change",
  "detail": {
    "stack-id": "arn:aws:cloudformation:us-east-1:ACCOUNT_ID:stack/EksUpgradePocStack-<suffix>/STACK_UUID",
    "logical-resource-id": "EksUpgradePocStack-<suffix>",
    "resource-type": "AWS::CloudFormation::Stack",
    "status-details": {
      "status": "UPDATE_ROLLBACK_COMPLETE",
      "status-reason": "The following resource(s) failed to update: [CoreDns, KubeProxy, Cluster9EE0221C, VpcCni]."
    }
  }
}' | base64)" \
  --cli-binary-format base64 \
  --region us-east-1 \
  /tmp/failure-test.json && cat /tmp/failure-test.json
```

Replace `ACCOUNT_ID` and `STACK_UUID` with your values. If you deployed with `NAME_SUFFIX=<suffix>`, change `--function-name` accordingly.

**What to expect (do NOT click "Generate Mitigation" in the console)**

1. Failure Lambda opens a new investigation on the agent space asking for root cause only (the `eks-failure-root-cause` skill activates; the `eks-investigation-triage-rules` skill ensures no linking to upgrade investigations)
2. Agent produces `### Root Cause:` → `Investigation Completed` event fires
3. Trigger Lambda fetches journal records, sees Root Cause but no Mitigation Plan → calls `aidevops:UpdateBacklogTask(taskStatus='PENDING_START')` programmatically and schedules a 3-minute EventBridge Scheduler check
4. Mitigation Agent runs (~2 min) → produces execution plan + agent-ready spec
5. Scheduled check fires → Trigger Lambda sees Mitigation Plan marker → dispatches `next-steps.yml` + publishes to SNS

If you have more than one deployment in the account, expect **exactly one** investigation and one `next-steps.yml` run. Only the deployment whose `ROOT_STACK_PREFIX` matches the rolled-back stack reacts; the others log `Ignoring rollback for stack …` and return.

Total runtime is ~10-20 min. **Important:** do not manually click "Generate Mitigation" in the console — let the Trigger Lambda handle it automatically. Clicking manually creates a race condition where the Trigger Lambda may see the mitigation content before it processes the root-cause-only event.

**Verify in CloudWatch Logs:**

```bash
# Check Trigger Lambda saw 'incomplete' and called UpdateBacklogTask:
aws logs filter-log-events \
  --log-group-name /aws/lambda/devops-agent-trigger-upgrade-<suffix> \
  --start-time $(date -u -d '30 minutes ago' +%s000) \
  --region us-east-1 \
  --query 'events[].message' --output text | grep -E "UpdateBacklogTask|PENDING_START|incomplete|Routing|schedule"

# Confirm the ownership guard let this deployment through (and check the
# other deployments' log groups to confirm they dropped the same event):
aws logs filter-log-events \
  --log-group-name /aws/lambda/devops-agent-upgrade-failure-event-<suffix> \
  --start-time $(date -u -d '30 minutes ago' +%s000) \
  --region us-east-1 \
  --query 'events[].message' --output text | grep -E "Ignoring rollback|Opening failure-analysis|Webhook OK"

# Confirm the mitigation payload was the structured spec, not a truncated
# transcript. Prefer 'source=agent-ready spec (write_mitigation_code_spec)';
# any 'truncation dropped the only copy' warning explains a later
# "no actionable mitigation spec found" failure in next-steps.yml.
aws logs filter-log-events \
  --log-group-name /aws/lambda/devops-agent-trigger-upgrade-<suffix> \
  --start-time $(date -u -d '30 minutes ago' +%s000) \
  --region us-east-1 \
  --query 'events[].message' --output text | grep -E "source=|truncat"
```

### Step 9: Tear down the environment (optional)

When you're done with the sample, `cleanup.sh` deletes everything `bootstrap.sh` created in reverse order.

**Before you run cleanup**

A handful of items won't block the script but will either stick around costing money or leave orphaned resources if you skip them. Work through these first:

1. **Delete any Kubernetes LoadBalancer/Ingress resources in the cluster.** The AWS Load Balancer Controller provisions ALBs/NLBs outside the CDK stack, so `cdk destroy` leaves them behind as orphaned resources that keep billing. Drop any `Service` of type `LoadBalancer` and any `Ingress` before tearing down:

   ```bash
   kubectl get svc -A --field-selector spec.type=LoadBalancer
   kubectl get ingress -A
   # delete each one before continuing
   ```

   If the cluster is empty (no workloads deployed), skip this step.

2. **Delete any PersistentVolumeClaims backed by EBS with Retain policy.** Same reason — orphaned EBS volumes survive cluster deletion:

   ```bash
   kubectl get pv --output=jsonpath='{range .items[?(@.spec.persistentVolumeReclaimPolicy=="Retain")]}{.metadata.name}{"\n"}{end}'
   # either delete the PVs, or accept the EBS charges and clean them up later
   ```

3. **Wait for any running DevOps Agent investigations to complete.** Deleting the agent space mid-investigation drops the task; the webhook and EventBridge rules go with it. Check the Backlog tab in the DevOps Agent console.

4. **Delete Lambda log groups (optional, to stop CloudWatch charges).** CFN deletes the Lambdas but not their log groups — AWS retains them forever by default:

   ```bash
   for name in devops-agent-health-event devops-agent-trigger-upgrade devops-agent-upgrade-failure-event; do
     aws logs delete-log-group --log-group-name "/aws/lambda/$name" 2>/dev/null || true
   done
   ```

   (Add the `NAME_SUFFIX` to each name if you used one during bootstrap.)

5. **Drain workloads from node groups if you added any.** The sample doesn't deploy workloads, but if you used the cluster for anything real, PodDisruptionBudgets can block node group teardown and stall CDK destroy indefinitely. A quick `kubectl delete deploy --all -A` on any non-system namespace avoids that.

**Run the cleanup**

```bash
./cleanup.sh
```

The script prints what it's about to delete and waits for you to type `yes` before doing anything. On confirmation it:

1. Deletes the CloudFormation stack (`DevOpsAgentStack`) — removes the agent space, IAM roles, EventBridge rules, all three Lambdas, and Secrets Manager secrets
2. Force-deletes the Secrets Manager secrets immediately so the names are reusable right away (otherwise they sit in a 30-day recovery window)
3. Deletes the CDK stack (`EksUpgradePocStack`) — removes the EKS cluster, addons, node group, VPC, and ALB controller. This is the slow step (~10-15 min for EKS control plane teardown)

**Respects `NAME_SUFFIX` and `AWS_PROFILE`**, same as `bootstrap.sh`:

```bash
NAME_SUFFIX=alice ./cleanup.sh
AWS_PROFILE=sandbox ./cleanup.sh
```

**What cleanup does NOT touch** (you decide):

- The CDK bootstrap stack (`CDKToolkit`) — account-wide, likely shared with other projects. Delete manually via CloudFormation only if you're sure nothing else uses it
- GitHub repo secrets (`KIRO_API_KEY`, `AWS_DEPLOY_ROLE_ARN`) — manage via GitHub UI or `gh secret delete <name>`
- The AWS OIDC IAM role you created for `eks-deploy.yml` (Step 8) — reusable across projects, delete from IAM if this was its only consumer
- Your Kiro API key on [app.kiro.dev](https://app.kiro.dev/) — revoke there if this sample was the only consumer
- Your GitHub PAT — revoke on GitHub if the PAT was created specifically for this sample
- CloudWatch log groups for the three Lambdas — see prerequisite 4 above if you want these gone
- Merged upgrade PRs on your fork — standard git cleanup applies

**Skip flags** for partial teardowns:

```bash
SKIP_CFN=1 ./cleanup.sh   # CFN stack already gone, just clean up secrets + CDK
SKIP_CDK=1 ./cleanup.sh   # Leave EKS cluster running, only remove agent plumbing
```

After cleanup completes, you can re-run `./bootstrap.sh` from scratch — secrets and stack names are immediately reusable.

## Daily skill review

An EventBridge Rule (cron schedule) triggers the Skill Review Lambda daily at 08:00 UTC. This automated workflow keeps the pipeline's skills current with AWS changes.

### How it works

```
EventBridge Rule (daily 08:00 UTC cron)
  → Skill Review Lambda
      1. Fetches all four SKILL.md files from GitHub (Contents API)
      2. Posts webhook to agent space with skill content embedded
  → DevOps Agent runs eks-skill-review skill (Incident RCA)
      - Verifies claims against live AWS APIs, docs, and release notes
        (the skill states the goal; the agent chooses the tools)
      - Compares against embedded skill content
      - Produces Skill Update Spec
  → Investigation Completed event
      → Trigger Lambda reads journal records, extracts the agent's real spec
          IF CHANGES_FOUND: YES → dispatches skill-update.yml + publishes SNS
          IF CHANGES_FOUND: NO → logs and exits (no PR, no notification)
          IF no spec could be isolated → dispatches so the workflow fails loudly
```

The `CHANGES_FOUND` test runs against the **extracted** spec, never the raw
findings. The `eks-skill-review` SKILL.md is echoed into the findings and its
output contract shows both a `YES` and a `NO` example, so a raw-findings match
made every no-change review look like a change and emailed "changes detected."

Detecting that echo needs more than a "contains both YES and NO" test. The two
template examples are *separate* fenced blocks, each under its own
`### Skill Update Spec` heading, so the section strategy matches the `NO` example
alone — one block, no `YES`, no `SKILL:` line, indistinguishable from a genuine
no-change answer by shape. `_is_skill_template_echo` therefore also rejects blocks
whose recognized field values (`SKILL`, `SECTION`, `CHANGE_TYPE`, `DESCRIPTION`,
`REVIEW_SUMMARY`) still contain `<lowercase-placeholders>`. `SUGGESTED_EDIT` bodies
are exempt, because real edits legitimately carry angle brackets — the rollback
command contains `<previous-version>`. Keep this in sync with `is_template_echo` in
`skill-update.yml`.

For the same reason, spec extraction must **not** fall back to scanning unfiltered
candidates for a `NO` block. That returned the template's own `NO` example and
laundered "the agent never answered" into "all skills current" — the more dangerous
of the two failure directions, which is why an un-isolatable spec dispatches and
fails loudly instead.

The review also **reviews itself**: `SKILL_PATHS` in the Skill Review Lambda lists
`eks-skill-review/SKILL.md` alongside the three operational skills, because its own
verification guidance and output contract go stale the same way and nothing else
audits it. `SKILL_PATHS` and the skill's own "Goal" list of reviewed files must be
updated together. If a GitHub fetch fails, that skill is replaced with a
`(FETCH FAILED — skip this skill)` marker and the review proceeds on the rest
rather than aborting.

### Subscribe to skill update notifications

After deploying the stack, subscribe to the `eks-skill-update-notifications` topic:

```bash
aws sns subscribe \
  --topic-arn $(aws cloudformation describe-stacks \
    --stack-name DevOpsAgentStack \
    --query 'Stacks[0].Outputs[?OutputKey==`SkillUpdateNotificationTopicArn`].OutputValue' \
    --output text) \
  --protocol email \
  --notification-endpoint your-email@example.com
```

### What to do when a skill update PR is opened

1. Review the PR — the body contains the agent's reasoning for each change
2. Approve and merge
3. Rebuild the affected skill zips. **Delete each zip first** — `zip -r` *adds to*
   an existing archive instead of replacing it, so re-running it over a zip that
   already exists leaves the stale `SKILL.md` inside alongside the new one:
   ```bash
   cd skills
   for dir in */; do rm -f "${dir%/}.zip" && zip -qr "${dir%/}.zip" "$dir"; done
   ```
   Note `eks-upgrade-planning.zip` stores `SKILL.md` at the **archive root**,
   while the other three nest it under `<skill-name>/`. Both layouts work, but the
   loop above rewrites the upgrade-planning zip into the nested layout. To preserve
   the root-level layout, rebuild that one from inside its directory:
   ```bash
   rm -f eks-upgrade-planning.zip
   cd eks-upgrade-planning && zip -q ../eks-upgrade-planning.zip SKILL.md && cd ..
   ```
   Verify the result before uploading — `unzip -l <zip>` should list exactly one
   `SKILL.md`, and `unzip -p <zip> <path>/SKILL.md | diff - <path>/SKILL.md`
   should be empty.
4. Re-upload the updated zips to the DevOps Agent space (Console → Settings → Skills → replace existing).
   **This step is what changes agent behaviour** — merging the PR updates the repo
   only. Until the upload happens, investigations keep running the previous skill.

### Disable or adjust schedule

To change the schedule, update the `SkillReviewScheduleRule` cron expression in `devops-agent-space.yaml` and redeploy. To disable, set `State: DISABLED` on the rule.

## What happens next

### Forward path (upgrade planning → CDK PR)

1. Health Lambda sends a signed webhook to the DevOps Agent → upgrade-planning investigation starts (brand new, no parent linking)
2. DevOps Agent follows the `eks-upgrade-planning` skill (Steps 1-9) → produces a `CDK Change Spec` recorded in journal records
3. Investigation completes → EventBridge → Trigger Lambda calls `aidevops:ListJournalRecords`, stitches findings, and dispatches `eks-upgrade.yml` only when the findings contain a `CDK Change Spec` block
4. `eks-upgrade.yml` validates the spec, then runs Kiro CLI to apply it to `lib/iteration3-stack.ts` **only**. A separate workflow step swaps the kubectl layer dependency in `package.json` using `npm` → PR created for human review

The spec must carry `FEASIBILITY: READY` or the workflow stops at the validation
step, before Kiro runs — see [Why the spec is validated before Kiro runs](#why-the-spec-is-validated-before-kiro-runs).

The forward path takes ~15-30 min depending on investigation depth.

### Closed loop (real-cluster failure → root cause → programmatic mitigation → spec PR + SNS)

1. Post-merge `eks-deploy.yml` runs `cdk deploy` and tags the CFN stack with the originating `InvestigationTaskId`
2. CFN emits a terminal rollback → Failure Lambda picks it up. CloudFormation status events are account-wide, so if you run several deployments, every one of their Failure Lambdas is invoked; each drops the event unless the stack name matches its own `ROOT_STACK_PREFIX`, so exactly one investigation opens ([details](#deploying-multiple-copies-in-the-same-accountregion)).
3. Failure Lambda **opens a brand new failure investigation** on the **same agent space** via the shared generic webhook. The `eks-investigation-triage-rules` skill (scoped to Incident Triage) ensures the agent never links failure investigations to upgrade-planning investigations. The `eks-failure-root-cause` skill (scoped to Incident RCA) activates because the incident description mentions CloudFormation rollback. The Failure Lambda does NOT dispatch any GitHub workflow.
4. Agent runs the root-cause investigation → `Investigation Completed` event
5. Trigger Lambda fetches journal records via `ListJournalRecords`, sees `### Root Cause:` but no `## Mitigation Plan` or `# Mitigation Summary`, and **calls `aidevops:UpdateBacklogTask(taskStatus='PENDING_START')`** to activate the Mitigation Agent (equivalent to clicking "Generate Mitigation" in the console). Then schedules a one-time EventBridge Scheduler check after 3 minutes to poll for completion.
6. Mitigation Agent runs (~2 min) and produces the execution plan + agent-ready spec (including `# Mitigation Summary` or `## Mitigation Plan` sections). The Mitigation Agent does NOT emit an `Investigation Completed` event when done.
7. Scheduled check fires → Trigger Lambda fetches journal records again. If the mitigation execution ended with a terminal failure (`FAILED`, `CANCELED`, `TIMED_OUT`), it publishes an SNS alert and stops polling. If mitigation is still running (no mitigation marker found), it reschedules for 1 more minute. Once successfully complete (`STOPPED`), it:
   - **Dispatches `next-steps.yml`** with the agent-ready spec (change requirements + acceptance criteria), taken from the Mitigation Agent's `write_mitigation_code_spec` tool call — roughly 1 KB of structured requirements rather than a slice of the raw transcript, which keeps it well inside the 45,000-char payload cap. If the tool call is absent, the Lambda falls back to slicing the transcript and logs `source=sliced findings (no tool call found)`. Kiro CLI implements the spec in CDK code, opening a code fix PR.
   - **Publishes to SNS** — extracts the execution plan (immediate CLI steps to recover the cluster, excluding the Code Change Specification) and sends it to the `eks-upgrade-failure-mitigation` topic so on-call sees the urgent actions in their inbox. The message instructs the responder to take the immediate steps first, then review and merge the code fix PR opening on the repo.
8. `next-steps.yml` runs Kiro CLI to implement the agent-ready spec in CDK code → PR labeled `EKS Upgrade Failure Mitigation - Agent Spec PR`.
9. After merging, the code fix is deployed via `eks-deploy.yml`.

The Trigger Lambda's content classifier checks markers in priority order — `### Skill Update Spec` first (since skill reviews often quote `## Mitigation Plan` when documenting the mitigation contract), then `## Mitigation Plan` / `# Mitigation Summary`, then `### CDK Change Spec` / `CLUSTER_VERSION: X.Y` — so a skill review never triggers a spurious mitigation dispatch, a failure investigation can never auto-trigger another upgrade, and a skill review that quotes CDK spec examples can never trigger an upgrade workflow. A dispatch-lock mechanism (using deterministic EventBridge Scheduler schedule names) prevents duplicate dispatches when both a native `Investigation Completed` event and a scheduled poll hit the same task.

Note the two layers of dedup, which cover different problems. The dispatch lock is keyed on `task_id` and stops the *same* task being dispatched twice by an event and a poll. It cannot stop *different* agent spaces each opening their own investigation for one rollback, because each space mints a different `task_id` — that's what the Failure Lambda's ownership guard is for.

Why a webhook (and not the boto3 SDK) for opening the initial failure investigation? The DevOps Agent's `aidevops` API surface doesn't expose an action to push a new task into the backlog. The generic webhook with HMAC is the supported entry point. However, once a task exists, `UpdateBacklogTask` can advance it programmatically.

## Safety constraints

- Control plane upgrades are **reversible for 7 days** via EKS version rollback — after the window closes, the upgrade is permanent
- Rollback is NOT viable when: deprecated APIs were removed, addon updates are forward-only, or nodes have version skew
- `vpc-cni` **MUST** be updated before node groups (new AMIs expect the updated CNI)
- Only **one minor version** at a time (1.30 → 1.31, never 1.30 → 1.32)
- `cdk diff` must show **Modify**, never **Replace** (Replace = cluster destruction)

## Useful CDK commands

- `npm run build` — compile TypeScript to JS
- `npm run watch` — watch for changes and compile
- `npx cdk deploy` — deploy this stack to your default AWS account/region
- `npx cdk diff` — compare deployed stack with current state
- `npx cdk synth` — emit the synthesized CloudFormation template

## Responsible AI

This pipeline uses AI to *propose* changes, never to apply them unsupervised. The controls below are built into the design:

- **Human review gate.** Every AI-generated change — CDK upgrades, failure-mitigation code fixes, and skill updates — lands as a pull request that a human must review and merge. No AI output reaches a deployed environment without human approval. Post-merge deploy is a separate manual trigger (see `eks-deploy.yml`), not automatic.
- **Output validation.** Before a PR is opened, the workflows validate AI-generated CDK code (`npm run build`, `cdk synth`) and enforce a file-change allowlist, so malformed or out-of-scope edits fail the run rather than reaching a reviewer.
- **Scope of AI decision-making.** The AWS DevOps Agent plans upgrades and analyzes failures; Kiro CLI translates those plans into code. Humans decide what merges and what deploys. The AI does not manage credentials, alter IAM, or act on production infrastructure directly.
- **Transparency.** Each PR carries the investigation context that produced it (findings, change spec, acceptance criteria), so a reviewer can trace *why* a change was proposed.
- **AI model access.** Kiro CLI runs the code-generation steps using its own managed model service. Review the [Kiro](https://kiro.dev/docs/) and [Amazon Q Developer](https://docs.aws.amazon.com/amazonq/) documentation for the current data-handling and model details.

This is sample/POC code. Teams adopting it for production should confirm these controls meet their own Responsible AI and compliance requirements.

## Conclusion

This pipeline automates Amazon EKS upgrade planning with human review gates — AWS Health triggers the investigation, the AWS DevOps Agent plans the upgrade, and Kiro CLI opens a pull request. The closed-loop failure path ensures that real deployment failures also get automated root-cause analysis and code fix PRs. A daily skill review keeps the pipeline's agent skills current with AWS EKS changes, opening PRs and notifying via SNS when updates are needed. Customize the skills in `skills/` and extend the EventBridge rules to cover additional cluster operations as needed.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.