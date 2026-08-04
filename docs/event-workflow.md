# Amazon EKS Automated Upgrade Pipeline — Event Workflow

End-to-end documentation of the automated EKS upgrade pipeline.

## Pipeline overview

All three paths funnel through the same EventBridge rule (`devops-agent-investigation-events`) and the same Lambda (`devops-agent-trigger-upgrade`). All three use a **single agent space** — investigation isolation is enforced by the `eks-investigation-triage-rules` skill (scoped to Incident Triage) which prevents the agent from linking upgrade, failure, and skill-review investigations. The Trigger Lambda routes by inspecting the journal records — Skill Update Spec → skill-update.yml + SNS, Mitigation Plan/Summary marker → next-steps.yml + SNS, CDK Change Spec → eks-upgrade.yml, Root Cause only → UpdateBacklogTask + schedule poll.

```
                      ┌─────────────────── Upgrade path ───────────────────┐
[1] AWS Health  ─→ EventBridge ─→ Health Lambda ─→ DevOps Agent (webhook, new investigation)
                                                          │
                                                          ▼ runs eks-upgrade-planning skill
                                                  Investigation Completed
                                                          │
                                                          ▼ EventBridge
                                                  Trigger Lambda
                                                          │ ListExecutions + ListJournalRecords
                                                          │ (CDK Change Spec found → upgrade)
                                                          ▼
                                              GitHub Actions (eks-upgrade.yml)
                                                          │
                                                          ▼ Kiro CLI applies CDK Change Spec
                                                       PR (CDK)
                                                          │
                                                          ▼ human review + merge
                                                   eks-deploy.yml ─→ cdk deploy

                      ┌──────── Failure path (closed loop, single space with skill isolation) ────────┐
[F] CFN rollback  (account-wide event — every deployment's rule sees it)
        │
        ▼ EventBridge
   Failure Lambda ─→ ownership guard: stack name == ROOT_STACK_PREFIX ? proceed : drop
        │
        └────────────→ DevOps Agent SAME space (webhook, brand new UNLINKED investigation,
                                   triage skill prevents linking, RCA skill activates,
                                   asks for "### Root Cause:" only)
                                                          │
                                                          ▼ produces Root Cause
                                                  Investigation Completed
                                                          │
                                                          ▼ EventBridge
                                                  Trigger Lambda
                                                          │ ListJournalRecords
                                                          │ (Root Cause found, no Mitigation Plan)
                                                          │ → calls aidevops:UpdateBacklogTask(PENDING_START)
                                                          │ → schedules 5-min EventBridge Scheduler check
                                                          ▼
                                                  Mitigation Agent runs (~2 min)
                                                  (follows Incident Mitigation instructions)
                                                  (does NOT emit Investigation Completed)
                                                          │
                                                          ▼ Scheduled check fires
                                                  Trigger Lambda (polls via ListJournalRecords)
                                                          │ (Mitigation Plan / Mitigation Summary found)
                                                          ▼
                                              GitHub Actions (next-steps.yml)        SNS topic
                                                          │                            │
                                                          ▼ Kiro CLI implements        ▼ execution plan
                                                          agent-ready spec in CDK      (immediate CLI steps)
                                                       PR (code fix)

                      ┌──── Skill review path (daily maintenance, same space) ────┐
[S] EventBridge rule eks-skill-review-daily (cron 08:00 UTC)
        │
        ▼
   Skill Review Lambda ─→ reads all four skills/*/SKILL.md via GitHub Contents API
        │
        └────────────→ DevOps Agent SAME space (webhook, brand new investigation,
                                   eks-skill-review skill activates)
                                                          │
                                                          ▼ produces Skill Update Spec
                                                  Investigation Completed
                                                          │
                                                          ▼ EventBridge
                                                  Trigger Lambda
                                                          │ ListJournalRecords
                                                          │ (Skill Update Spec found — checked FIRST)
                                                          │
                                    CHANGES_FOUND: NO ────┴──── CHANGES_FOUND: YES
                                          │                            │
                                          ▼                            ▼
                                    log and exit          GitHub Actions        SNS topic
                                    (no PR, no SNS)       (skill-update.yml)   (eks-skill-update-
                                                                │              notifications)
                                                                ▼ Kiro CLI edits SKILL.md
                                                                  + rebuilds skill zips
                                                             PR (skills)
```

## Step 1 — AWS Health planned-lifecycle event

**Source:** AWS Health detects an Amazon EKS cluster approaching end-of-support.

**Event:** `AWS_EKS_PLANNED_LIFECYCLE_EVENT` published to EventBridge with `service: EKS`, `eventTypeCategory: scheduledChange`.

**Next:** `eks-health-planned-lifecycle` rule matches and invokes the Health Lambda.

## Step 2 — EventBridge rule (planned-lifecycle)

**Rule:** `eks-health-planned-lifecycle`

**Pattern:** `source: aws.health`, `detail-type: AWS Health Event`, `detail.service: EKS`, `detail.eventTypeCode: AWS_EKS_PLANNED_LIFECYCLE_EVENT`

**Targets:** Health Lambda function + the shared Amazon EventBridge log group (for diagnostic visibility).

## Step 3 — Health Lambda → webhook to DevOps Agent

**Function:** `devops-agent-health-event`

1. Reads webhook URL + HMAC secret from `devops-agent/webhook-credentials`. Fails fast with a clear error if either is `PLACEHOLDER`.
2. Extracts the cluster name from the affected entity ARN.
3. Builds an incident payload (`title`, `description` instructing the agent to follow `eks-upgrade-planning`).
4. Signs the payload with HMAC-SHA256 using `<timestamp>:<payload>`.
5. POSTs to the agent's generic webhook. **No parent linking** — every upgrade-planning investigation is brand new.

**Output:** A new task in the agent's backlog. The agent runs the `eks-upgrade-planning` skill (Steps 1-9) and produces a summary including the `CDK Change Spec` block.

## Step 4 — DevOps Agent investigation

The agent runs the 9-step skill against the cluster. Findings are recorded in journal records — read later by the Trigger Lambda via `ListJournalRecords`.

When the agent finishes, it emits an `Investigation Completed` event:

```json
{
  "source": "aws.aidevops",
  "detail-type": "Investigation Completed",
  "detail": {
    "metadata": {
      "agent_space_id": "...",
      "task_id": "...",
      "execution_id": "..."
    },
    "data": { "status": "COMPLETED", "summary_record_id": "..." }
  }
}
```

## Step 5 — EventBridge rule (investigation events)

**Rule:** `devops-agent-investigation-events`

**Pattern:** `source: aws.aidevops`, filtered by this stack's single `agent_space_id`. No `detail-type` filter — the Lambda inspects `detail.data.status` to route events, so any event the service emits for this space is received.

**Target:** Trigger Lambda + shared EventBridge log group.

This rule fires for completions, timeouts, and any future event types. `TIMED_OUT` is classified by task type and routed to the matching SNS topic as an alert; `COMPLETED` proceeds to routing. All other statuses are ignored with a 204 early-return.

## Step 6 — Trigger Lambda

**Function:** `devops-agent-trigger-upgrade`

1. **Fetches journal records** via `aidevops:ListJournalRecords(agentSpaceId, executionId)` using `boto3.client('devops-agent').list_journal_records(...)`. It first calls `ListExecutions(agentSpaceId, taskId)` and reads records from *every* execution on the task, not just the one in the event — the Mitigation Agent runs under its own execution ID, but the `Investigation Completed` event only carries the RCA execution's. Where the Lambda runtime's bundled boto3 lacks the `devops-agent` client, the Lambda depends on a `devops-agent-sdk` Lambda layer that ships the botocore service model JSON (~26 KB); once the runtime bundles that model, the layer can be removed. The `AWS_DATA_PATH=/opt/botocore-models` env var tells botocore where to find it. Built from `lambda-layers/devops-agent-sdk/service-model/` and uploaded by `bootstrap.sh`. Pagination handled in the Lambda — the API returns at most 100 records per page.
2. **Stitches the records' `content` fields** into a single string (the full investigation output, walking nested `text`/`message`/`content` keys to preserve real newlines).
3. **Routes by content marker, in priority order:**
   - `### Skill Update Spec` present → dispatch `skill-update.yml` + publish to the `eks-skill-update-notifications` topic (if the *extracted* spec says `CHANGES_FOUND: YES`), or exit silently (if it says `NO`). If no spec can be isolated at all, the Lambda stays on this path and dispatches the full findings so the workflow fails loudly rather than reporting a false no-op. Checked first because skill reviews often quote `## Mitigation Plan` when documenting the mitigation contract, which would otherwise false-match the mitigation path.
   - `## Mitigation Plan` or `# Mitigation Summary` heading present → dispatch `next-steps.yml` (mitigation phase completed; produces a code fix PR) AND publish the execution plan (immediate CLI steps, excluding Code Change Specification) to the SNS topic. The dispatched payload is the structured agent-ready spec when available — see [How the mitigation spec is selected](#how-the-mitigation-spec-is-selected).
   - Filled-in CDK Change Spec (`### CDK Change Spec` heading or `CLUSTER_VERSION: <minor>` line) → dispatch `eks-upgrade.yml` (upgrade path).
   - `### Root Cause:` without a Mitigation Plan → root-cause investigation completed. **Calls `aidevops:UpdateBacklogTask(taskStatus='PENDING_START')`** to programmatically activate the Mitigation Agent (equivalent to clicking "Generate Mitigation" in the console). Then schedules a one-time EventBridge Scheduler check after 5 minutes to poll for mitigation completion. The Mitigation Agent does NOT emit an `Investigation Completed` event when done, so polling is required. Terminal failure statuses (`FAILED`, `CANCELED`, `TIMED_OUT`) trigger an SNS alert and stop polling.
   - None of the above → log a diagnostic dump and exit.
   
   A dispatch-lock mechanism prevents duplicate dispatches when both a native event and a scheduled poll process the same task (uses deterministic EventBridge Scheduler schedule names as an atomic compare-and-swap).
4. **For workflow dispatches**, builds `INVESTIGATION_SUMMARY` (JSON metadata, with `investigation_type` set to `'upgrade'`, `'mitigation'`, or `'skill_update'`) and `INVESTIGATION_FINDINGS` (the payload selected for that path). Prints both to CloudWatch so they're auditable.
5. **`workflow_dispatch`** the chosen workflow with both inputs.

### Where INVESTIGATION_SUMMARY and INVESTIGATION_FINDINGS come from

| Variable | Source | Built by |
|---|---|---|
| `INVESTIGATION_SUMMARY` | `Investigation Completed` event metadata (`agent_space_id`, `task_id`, `execution_id`, `summary_record_id`, `status`) plus the routing decision (`investigation_type: 'upgrade'`, `'mitigation'`, or `'skill_update'`); the upgrade and mitigation paths also add `cluster_name` | Trigger Lambda |
| `INVESTIGATION_FINDINGS` | Path-dependent. **Upgrade:** the `investigation_result` journal record (the agent's authoritative deliverable, ~3.8 KB), falling back to the actionable slice of the stitched transcript. **Mitigation:** the structured agent-ready spec from the `write_mitigation_code_spec` tool call, falling back to the slice. **Skill update:** the isolated Skill Update Spec, falling back to the full findings. All journal-record content comes from `aidevops:ListJournalRecords(agentSpaceId, executionId).records[*].content`, joined with `\n\n---\n\n`, and every payload is capped at 45,000 chars. | Trigger Lambda |

Both are visible in CloudWatch Logs of `devops-agent-trigger-upgrade`, which logs the payload source and size for each path (`Upgrade payload source=… bytes=…`, `Dispatched next-steps.yml (code spec found) source=… bytes=…`). `next-steps.yml` and `skill-update.yml` also write the findings to a file and report the byte count in their job logs.

Why the upgrade path prefers the `investigation_result` record: DevOps Agent re-styles that record into Slack mrkdwn, rewriting ATX headings to bold and pipe tables to space-separated columns — so no markdown-heading regex can match it, by design of the platform rather than agent drift. Fenced code blocks are left byte-identical, and `eks-upgrade.yml` already anchors on a fence containing `CLUSTER_VERSION` rather than on a heading, so the record satisfies its contract. It also fits the size cap with room to spare, whereas the full stitched transcript runs ~185 KB and sorts the result record **last** (`order='ASC'`) — truncation would decapitate exactly the part the workflow needs.

## Step 7 — GitHub Actions: eks-upgrade.yml

**Workflow:** `.github/workflows/eks-upgrade.yml`

1. **Validate step** parses the summary JSON and confirms `agent_space_id`, `task_id`, `status` are present.
2. **Write step** writes `INVESTIGATION_FINDINGS` to `/tmp/investigation-findings.md` and reports the byte count in the run log.
3. **Extract and validate CDK Change Spec** pulls every fenced block containing `CLUSTER_VERSION` out of the findings and validates each against a strict contract — no `<placeholders>` or `e.g.`, `CLUSTER_VERSION` matching `\d+\.\d+`, `KUBECTL_LAYER_PACKAGE` matching `@aws-cdk/lambda-layer-kubectl-v\d+`, every `ADDON` a full `vX.Y.Z-eksbuild.N` string (or `NOT_INSTALLED`), and **`FEASIBILITY` exactly `READY`**. Exactly one block must survive: zero fails the run, and so does more than one (the pipeline won't choose between conflicting specs). The winner is written to `/tmp/cdk-change-spec.txt` — a clean file, so Kiro never parses the raw findings.
4. **Install Kiro CLI** and check the installed version against `KIRO_MIN_VERSION` (`1.0.3`) — older fails the run, newer emits a warning so the pin gets revisited.
5. **Kiro CLI** runs with `--no-interactive --trust-tools=read,write,glob,grep` (no shell, no network). Prompt: read `kiro-cdk-instructions.md` for CDK patterns, then apply `/tmp/cdk-change-spec.txt` to **`lib/iteration3-stack.ts` only** — explicitly *not* `package.json` or `package-lock.json` — deriving no version numbers of its own, and running no build or shell commands.
6. **Enforce file-change allowlist** fails the run if anything outside `^lib/iteration3-stack\.ts$` was touched.
7. **Swap kubectl layer dependency** reads `KUBECTL_LAYER_PACKAGE` from the spec, reads the outgoing package from `package.json`, and runs `npm pkg delete` + `npm install --save-exact` so **npm** resolves the published version. This runs *after* the allowlist audit, so its `package.json` edit is never laundered through it. See [Why the kubectl layer version is resolved here](#why-the-kubectl-layer-version-is-resolved-here).
8. **Validate CDK changes** runs `npm install`, `npm run build`, `npx cdk synth --quiet`.
9. **`peter-evans/create-pull-request`** opens a PR labeled `eks-upgrade,automated` with the investigation summary embedded in the body between `<!-- investigation-context-start -->` / `<!-- investigation-context-end -->` markers, which the post-merge deploy workflow parses.

### Why the kubectl layer version is resolved here

The kubectl layer packages are independently versioned siblings:
`@aws-cdk/lambda-layer-kubectl-v30` tops out at `2.0.4` while `-v31` jumps from
`2.0.3` to `2.1.0`. A version number never transfers between them, so copying the
outgoing pin onto the incoming package yields a version that does not exist and
fails `npm install` with `ETARGET`.

The spec therefore carries only the package **name**. Neither component upstream of
this step can resolve a version — the DevOps Agent has no network-capable tool (AWS
APIs and file reads only), and Kiro runs sandboxed without shell or network. Rather
than grant either one network access — Kiro's sandbox is what makes the allowlist
audit meaningful — resolution happens in the workflow, where npm is already
available.

Ordering matters: the swap must come **after** the allowlist audit. Putting it
before would require adding `package.json` to the allowlist, which would also
silently permit Kiro to edit it.

The step guards its command substitutions explicitly rather than relying on
`set -e`, which does **not** abort on a failed substitution inside an assignment. An
unguarded empty result would turn `npm pkg delete dependencies.$OLD` into
`npm pkg delete dependencies.`, wiping every dependency and exiting 0.

### FEASIBILITY is a hard gate

Step 3 rejects any spec whose `FEASIBILITY` is not `READY`, before Kiro runs and
before any PR exists. The realistic failure is not a malformed spec but a
well-formed one where the agent resolved every version and then blocked itself on a
real-but-non-blocking observation — most often the node group's AMI type, because
the `Amazon Linux 2 compatibility` insight reports `ERROR` on any AL2 node group
regardless of whether a target AMI exists. That makes the verdict nondeterministic
on such a cluster: identical inputs, opposite answers.

`skills/eks-upgrade-planning/SKILL.md` Step 8 enumerates what must never block and
routes everything else to `RISK:` plus the risks section, on the reasoning that a
human reviews every generated PR whereas a `NEEDS_REMEDIATION` halts the pipeline
before there is anything to review. Being prompt-level, that fix is probabilistic;
this gate is the deterministic backstop.

## Step 8 — Human review and merge

Reviewer checks version numbers, confirms `cdk diff` shows only `Modify` operations (never `Replace`), and merges.

## Step 9 — eks-deploy.yml (post-merge)

**Workflow:** `.github/workflows/eks-deploy.yml`

Manual trigger (`gh workflow run eks-deploy.yml -f pr_number=<N>`). Parses the `<!-- investigation-context-start -->` block from the merged PR body to extract `task_id`, passes it to `cdk deploy` as context, and CDK applies it as an `InvestigationTaskId` stack tag.

The tag is informational metadata read by the Failure Lambda if the deploy fails — it tells the human reviewer which agent investigation produced the (now-failed) plan.

## Failure path (closed loop, single agent space with skill-based isolation + polling)

When the deployed upgrade fails on the cluster, the failure path runs in two phases: (1) root-cause investigation on the same agent space (isolated by the triage skill), then (2) programmatic mitigation activation via `aidevops:UpdateBacklogTask(PENDING_START)` with EventBridge Scheduler polling for completion (bounded at `MAX_POLLING_ATTEMPTS = 30`). The Trigger Lambda is the only orchestrator — there's no Step Functions or queue.

### Step F1 — CFN rollback

**Rule:** `eks-cfn-stack-failure` matches `aws.cloudformation` events with terminal rollback statuses (`ROLLBACK_FAILED`, `ROLLBACK_COMPLETE`, `UPDATE_ROLLBACK_FAILED`, `UPDATE_ROLLBACK_COMPLETE`). Auto-rollback (the `cdk deploy` default) emits exactly one event per failed deploy.

The event pattern carries **no `stack-id` filter** — CloudFormation Stack Status Change events are account-wide, so this rule sees every rollback in the account, not just this deployment's. That is deliberate (see [Ownership guard](#ownership-guard-multiple-deployments-in-one-account)); the filtering happens in the Lambda.

It invokes `devops-agent-upgrade-failure-event`.

### Step F2 — Failure Lambda

1. Normalizes the CFN event into a uniform failure detail.
2. **Ownership guard** — drops the event unless the rolled-back stack name matches this deployment's `ROOT_STACK_PREFIX` exactly. See below.
3. Reads the stack's `InvestigationTaskId` tag (informational only; does NOT link the new investigation).
4. **Opens a brand new failure investigation** on the **same agent space** via the shared generic webhook. `action: created`, no `parentInvestigationId`. The `eks-investigation-triage-rules` skill (scoped to Incident Triage) ensures the agent never links this to an active upgrade investigation. The `eks-failure-root-cause` skill (scoped to Incident RCA) activates because the description mentions CloudFormation rollback. The description tells the agent to produce:
   - `### Root Cause:` — concise root-cause statement plus supporting evidence.

That's all the Failure Lambda does. It does not dispatch any GitHub workflow or request mitigation — that's handled programmatically by the Trigger Lambda after root cause completes.

#### Ownership guard (multiple deployments in one account)

`eks-cfn-stack-failure` subscribes to CloudFormation Stack Status Change events, which are **account-wide** — the event pattern has no `stack-id` filter. Every deployed copy of this template creates its own copy of the rule, so a single rollback fans out to *every* deployment's Failure Lambda. Without a guard, each one opens its own investigation in its own agent space, and a single failed deploy produces N duplicate `next-steps.yml` runs and N mitigation PRs. The dispatch lock can't dedupe them — it's keyed on `task_id`, and each agent space mints a different one.

The Failure Lambda therefore drops any rollback whose stack name doesn't match `ROOT_STACK_PREFIX`, the env var that already declares which stack the deployment owns:

| `ROOT_STACK_PREFIX` | Rolled-back stack | Result |
|---|---|---|
| `EksUpgradePocStack-alice` | `EksUpgradePocStack-alice` | Investigation opened |
| `EksUpgradePocStack-bob` | `EksUpgradePocStack-alice` | Ignored — not this deployment's stack |
| `EksUpgradePocStack` | `EksUpgradePocStack-alice` | Ignored — exact match, not prefix match |
| `EksUpgradePocStack-alice` | `SomeCustomerAppStack` | Ignored |
| `EksUpgradePocStack-alice` | `EksUpgradePocStack-alice-NestedStack-…` | Ignored by the earlier nested-stack check |

The comparison is **exact**, not a prefix test: an unsuffixed `EksUpgradePocStack` is a string prefix of every suffixed name, so a prefix match would let the default deployment claim every suffixed deployment's failures. The nested-stack heuristic that runs just before this already excludes a stack's own children.

`ROOT_STACK_PREFIX` is set by CFN from the `NameSuffix` parameter (`EksUpgradePocStack-<suffix>`, or `EksUpgradePocStack` when unsuffixed), so no extra configuration is needed. If you rename the CDK stack, update `NameSuffix`/`ROOT_STACK_PREFIX` to match or the guard will silently drop every failure event. Ignored events log a line naming both stacks:

```
Ignoring rollback for stack EksUpgradePocStack-alice: this deployment owns
EksUpgradePocStack-bob. Another deployment's failure detector handles it.
```

The health-event path (`eks-health-planned-lifecycle`) is intentionally **not** scoped this way — planned lifecycle events should reach the agent for any cluster in the account, which is what makes the pipeline generic across clusters.

### Step F3 — Root-cause investigation completes

The agent works through the prompt, records the root cause in journal records, and emits `Investigation Completed`. The Trigger Lambda picks it up via the same `Investigation Completed` rule used for upgrade-planning completions.

### Step F4 — Trigger Lambda calls UpdateBacklogTask and schedules polling

The Trigger Lambda fetches the journal records, finds `### Root Cause:` but no `## Mitigation Plan` or `# Mitigation Summary`, and calls `aidevops:UpdateBacklogTask(agentSpaceId, taskId, taskStatus='PENDING_START')` to programmatically activate the Mitigation Agent — equivalent to clicking "Generate Mitigation" in the DevOps Agent console. The Mitigation Agent follows the Incident Mitigation instructions configured in the agent space.

Before doing so it calls `ListExecutions` to check whether a `mitigation` execution already exists on the task — the `Investigation Completed` event can arrive before every journal record is written, and re-activating a task that is already mitigating would loop. If one exists, the Lambda inspects its status instead of calling `UpdateBacklogTask` again.

Since the Mitigation Agent does NOT emit an `Investigation Completed` event when done, the Trigger Lambda schedules a one-time EventBridge Scheduler check after 5 minutes to poll for completion.

### Step F5 — Mitigation Agent runs and Trigger Lambda polls

The Mitigation Agent runs (~2 min) and produces the execution plan + agent-ready spec (including `# Mitigation Summary` or `## Mitigation Plan` sections).

When the scheduled check fires, the Trigger Lambda fetches journal records again via `ListJournalRecords`. The reschedule interval depends on what it finds:

| Mitigation execution state | Next action |
|---|---|
| Still running (non-terminal status) | Reschedule in 3 minutes |
| `STOPPED` — finished, but records not yet all visible | Reschedule in 1 minute |
| `FAILED` / `CANCELED` / `TIMED_OUT` | Publish an SNS alert to `eks-upgrade-failure-mitigation` and stop polling |
| Mitigation marker found in the records | Proceed to dispatch (Step F6) |

Polling is capped at `MAX_POLLING_ATTEMPTS = 30`; exceeding it stops the chain rather than scheduling indefinitely.

### Step F6 — Trigger Lambda dispatches next-steps.yml + SNS publish

Once the Trigger Lambda detects the mitigation marker (`## Mitigation Plan` or `# Mitigation Summary`), it:

1. **Dispatches `next-steps.yml`** with `INVESTIGATION_SUMMARY` (`investigation_type='mitigation'`) and `INVESTIGATION_FINDINGS` (the agent-ready spec — see [How the mitigation spec is selected](#how-the-mitigation-spec-is-selected)). Skipped when the mitigation output carries no code spec at all — there would be nothing for Kiro to implement.
2. **Publishes to SNS** — extracts the execution plan (immediate CLI steps to recover the cluster, excluding the Code Change Specification) and publishes it to the `eks-upgrade-failure-mitigation` topic so on-call sees the urgent actions in their inbox/Slack ahead of reading the full code fix PR. The message instructs the responder to take the immediate steps first, then review and merge the code fix PR opening on the repo. Skipped when the output contains no immediate steps. Best-effort — if SNS is unavailable, the Lambda logs and continues; the PR is still created.

The two are independent: a mitigation that produces only immediate steps notifies without a PR, and one that produces only a code spec opens a PR without a notification.

### Step F7 — GitHub Actions: next-steps.yml

**Workflow:** `.github/workflows/next-steps.yml`

1. Validates the summary JSON and confirms `investigation_type='mitigation'` (rejects accidental dispatches).
2. Writes `INVESTIGATION_FINDINGS` to `/tmp/investigation-findings.md`, reporting the byte count.
3. **Extracts and validates the spec.** Priority 1 is the structured `# Agent-ready spec` block (requires `## Change requirements` or acceptance criteria); Priority 2 falls back to a `## Mitigation Plan` / `# Mitigation Summary` section that contains actionable keywords. Both are matched at **start of line** — see the anchoring note below. If neither is found the workflow stops with `Mitigation pipeline STOPPED — no actionable mitigation spec found in findings` rather than handing Kiro CLI a partial spec.
4. Kiro CLI reads `/tmp/mitigation-spec.md` (the validated spec with change requirements + acceptance criteria) and implements it in CDK code, modifying `lib/iteration3-stack.ts` and/or `package.json` as needed. It is told explicitly not to touch `devops-agent-space.yaml`, `.github/workflows/`, `skills/`, or `kiro-cdk-instructions.md`.
5. **Enforce file-change allowlist** fails the run if anything outside `^(lib/iteration3-stack\.ts|package\.json|package-lock\.json)$` was touched. Wider than the upgrade path's allowlist because a mitigation may legitimately need a dependency change, and unlike the upgrade path there is no later npm step to make that edit outside the audit.
6. **Validate CDK changes** runs `npm install`, `npm run build`, `npx cdk synth --quiet`.
7. PR labeled `eks-mitigation,automated`, titled `fix(eks): Failure mitigation for <cluster>`. After merge, the code fix is deployed via `eks-deploy.yml`.

### How the mitigation spec is selected

The Trigger Lambda has two ways to produce the payload and prefers the smaller, structured one:

| Priority | Source | Typical size | Notes |
|---|---|---|---|
| 1 | `_extract_mitigation_spec` — built from the agent's `write_mitigation_code_spec` tool call | ~1 KB | Pure requirements + acceptance criteria. Emits `# Agent-ready spec` / `## Change requirements`, matching the workflow's Priority 1 extractor. Fits well inside the size cap. |
| 2 | `_extract_actionable_content(findings, 'mitigation')` — slices the raw transcript from the last mitigation heading | tens of KB | Fallback only, used when the agent didn't make the tool call. |

The Lambda logs which one it used: `Dispatched next-steps.yml (code spec found) source=… bytes=…`. Prefer to see `source=agent-ready spec (write_mitigation_code_spec)`; a run reporting `source=sliced findings (no tool call found)` means the Mitigation Agent didn't emit a structured spec and the payload is far more likely to hit the truncation cap.

### Heading anchoring: why markers must be at start of line

Agents routinely echo `SKILL.md` and other instruction-file content that *describes* this contract in prose — "emit a `` `## Mitigation Plan` ``, a `` `## Immediate Steps` `` block…". An unanchored regex latches onto that backtick-quoted reference. Because findings interleave instructions, tool calls, and the agent's own output, the prose reference frequently appears *later* in the transcript than the genuine heading; the slice then begins mid-sentence and discards the real section entirely, and the 45 KB cap removes every remaining heading, so the workflow receives a payload with nothing parseable in it.

Two rules prevent that, and both sides of the contract must keep them in lockstep — `_extract_actionable_content` in `devops-agent-space.yaml` and the extract step in `next-steps.yml`. (`eks-upgrade.yml` extracts fenced code blocks containing `CLUSTER_VERSION` rather than headings, so only the Lambda side of the upgrade path uses this anchoring. The skill-update path anchors on headings on both sides too, and carries the additional template-echo rejection described in [Step S4](#step-s4-trigger-lambda-routes-the-skill-update).)

- **Anchor at start of line** and require a newline after the heading text, so an inline backtick reference can't match.
- **Keep the LAST match**, not the first — the agent's final answer, mirroring `_extract_skill_update_spec`.

One implementation trap worth calling out: match heading *positions* under `re.MULTILINE` and slice from the last one. Do **not** use `re.DOTALL` with a greedy `.*` — that collapses `finditer` to a single match running to end-of-string, so `matches[-1]` silently becomes the *first* heading, the opposite of the intent.

### Truncation is logged by name

`_dispatch_workflow` caps `INVESTIGATION_FINDINGS` at 45,000 characters. When a cut removes the only copy of a parseable marker (`# Agent-ready spec`, `## Change requirements`, `# Mitigation Summary`, `## Mitigation Plan`, `### CDK Change Spec`, `### Skill Update Spec`), the Lambda names it:

```
WARNING: findings length 210111 > 45000; truncating
WARNING: truncation dropped the only copy of these markers:
['# Mitigation Summary', '## Mitigation Plan'] — the workflow will likely fail to extract a spec.
```

Silent truncation is how a payload reaches GitHub looking complete while the section the workflow needs has been sliced off. If you see this warning alongside a "no actionable spec found" failure, the cause is the cap, not the agent.

## Skill review path (daily maintenance)

A third path runs on a schedule rather than in response to a cluster event. It keeps the pipeline's own skills current with AWS changes, and reuses the same webhook, agent space, investigation-events rule, and Trigger Lambda as the other two.

### Step S1 — Daily schedule

**Rule:** `eks-skill-review-daily` — an EventBridge rule with `ScheduleExpression: cron(0 8 * * ? *)`, enabled at deploy time. It invokes `devops-agent-skill-review-trigger` once a day at 08:00 UTC.

### Step S2 — Skill Review Lambda

**Function:** `devops-agent-skill-review-trigger`

1. Reads the GitHub PAT from `devops-agent/github-pat` and the webhook URL + HMAC secret from `devops-agent/webhook-credentials`, failing fast on `PLACEHOLDER` in either.
2. Fetches the current text of every file in `SKILL_PATHS` through the GitHub Contents API (`Accept: application/vnd.github.v3.raw`, `ref=main`):
   - `skills/eks-upgrade-planning/SKILL.md`
   - `skills/eks-failure-root-cause/SKILL.md`
   - `skills/eks-investigation-triage-rules/SKILL.md`
   - `skills/eks-skill-review/SKILL.md`
   A fetch that fails is replaced with a `(FETCH FAILED — skip this skill)` marker and the review proceeds on the rest rather than aborting the whole run.
3. Builds a `LOW` priority incident payload whose description embeds all four skill bodies under `## Current Skill Content` and instructs the agent to follow `eks-skill-review`.
4. Signs it with HMAC-SHA256 over `<timestamp>:<payload>` and POSTs to the same generic webhook the Health and Failure Lambdas use. `incidentId` is `skill-review-<YYYYMMDDHHMMSS>`.

The review **reviews itself**: `eks-skill-review/SKILL.md` is in `SKILL_PATHS` alongside the three operational skills, because its verification guidance and output contract go stale the same way and nothing else audits it. `SKILL_PATHS` and the skill's own "Goal" list of reviewed files must be updated together.

### Step S3 — Agent produces a Skill Update Spec

The `eks-skill-review` skill (Incident RCA) verifies the embedded skill content against live AWS APIs, documentation, and release notes, then emits a `### Skill Update Spec` block carrying `CHANGES_FOUND: YES|NO` plus `SKILL:` / `SECTION:` / `CHANGE_TYPE:` / `DESCRIPTION:` / `SUGGESTED_EDIT:` groups. The investigation then emits `Investigation Completed` like any other, and the same `devops-agent-investigation-events` rule delivers it to the Trigger Lambda.

### Step S4 — Trigger Lambda routes the skill update

`### Skill Update Spec` is the **first** marker the classifier checks, because a skill review that documents the mitigation contract quotes `## Mitigation Plan` in prose and would otherwise false-match the mitigation path.

The `CHANGES_FOUND` test then runs against the **extracted** spec, never the raw findings:

| Extracted spec | Classification | Action |
|---|---|---|
| Contains `CHANGES_FOUND: YES` | `skill_update` | Dispatch `skill-update.yml` + publish to `eks-skill-update-notifications` |
| Contains `CHANGES_FOUND: NO` | `skill_update_noop` | Log and exit — no PR, no notification |
| Could not be isolated at all | `skill_update` | Dispatch the full findings so the workflow fails loudly |

That last row is deliberate. `eks-skill-review/SKILL.md` shows both a `YES` and a `NO` example in its output contract, and the whole file is echoed into the findings — so a raw-findings match found the template's `YES` on every run, classified genuine no-change reviews as `skill_update`, and emailed "changes detected" while `skill_update_noop` stayed unreachable. Extraction alone isn't enough either: the two template examples are *separate* fenced blocks under their own `### Skill Update Spec` headings, so the `NO` example is indistinguishable from a real no-change answer by shape. `_is_skill_template_echo` therefore also rejects blocks whose recognized field values still contain `<lowercase-placeholders>` — with `SUGGESTED_EDIT` bodies exempt, since real edits legitimately carry angle brackets (the rollback command contains `<previous-version>`). Keep this in sync with `is_template_echo` in `skill-update.yml`.

For the same reason, extraction must **not** fall back to scanning unfiltered candidates for a `NO` block: that returns the template's own `NO` example and launders "the agent never answered" into "all skills current" — the more dangerous of the two failure directions, which is why an un-isolatable spec dispatches and fails loudly instead.

### Step S5 — GitHub Actions: skill-update.yml

**Workflow:** `.github/workflows/skill-update.yml`

1. Validates the summary JSON, then writes the findings to `/tmp/investigation-findings.md`.
2. **Extracts and validates the Skill Update Spec**, applying its own echo rejection, and writes the clean spec to `/tmp/skill-update-spec.txt`. A `CHANGES_FOUND: NO` spec short-circuits the run; `CHANGES_FOUND: YES` with no `SKILL`/`SUGGESTED_EDIT` pairs fails it.
3. Installs Kiro CLI and enforces `KIRO_MIN_VERSION` (`1.0.3`).
4. Kiro CLI runs sandboxed (`--no-interactive --trust-tools=read,write,glob,grep`) and applies only the called-out edits to the `SKILL.md` files under `skills/`.
5. **Rebuilds the skill zips** — `cd skills && for dir in */; do zip -r "${dir%/}.zip" "$dir"; done` — so the artifacts the DevOps Agent console consumes land in the same diff.
6. PR labeled `skill-update,automated`. After merge, the changed zips still need to be re-uploaded to the agent space by hand (Console → Settings → Skills → replace existing); that upload is the one manual step in this path.

## Why a single agent space (with skill-based isolation)

Upgrade-planning, failure, and skill-review investigations all run on the same agent space. Investigation isolation is enforced by:

- **Triage skill** (`eks-investigation-triage-rules`, scoped to Incident Triage) — explicit "never link" rules prevent the agent from correlating failure investigations with upgrade-planning investigations, even for the same cluster.
- **Skill scoping** — `eks-upgrade-planning` (Incident RCA) activates for planned lifecycle event investigations; `eks-failure-root-cause` (Incident RCA) activates for CloudFormation rollback investigations; `eks-skill-review` (Incident RCA) activates for the daily review. The agent selects the correct skill based on the incident description. No skill interference.
- **Global Instructions** — always-on rules reinforce isolation ("never reference findings from an upgrade-planning investigation when performing failure root-cause analysis" and vice versa).

Trade-offs vs the previous two-space design:

- **Pro:** Simpler infrastructure — one webhook, one space, one IAM role, fewer secrets.
- **Pro:** The monitor's memory store builds root-cause history across both investigation types, improving future triage.
- **Con:** Relies on the triage AI to correctly not-link investigations (vs hard isolation via separate spaces). The triage skill mitigates this, and bad decisions can be corrected in the UI.

## Why UpdateBacklogTask + polling (not a second Investigation Completed event)

The Mitigation Agent (activated via `UpdateBacklogTask(PENDING_START)`) does NOT emit an `Investigation Completed` event when it finishes. This is an agent service behavior — only the initial investigation phase emits that event. The Trigger Lambda works around this by scheduling a one-time EventBridge Scheduler check after 5 minutes, then rescheduling on the intervals in [Step F5](#step-f5-mitigation-agent-runs-and-trigger-lambda-polls) until the mitigation marker appears. This polling approach:

- **Avoids tight coupling** to internal agent event semantics that may change.
- **Is self-healing** — if the first poll misses, the next one catches it.
- **Has bounded cost** — `MAX_POLLING_ATTEMPTS = 30` caps the chain, and terminal failure statuses (`FAILED`, `CANCELED`, `TIMED_OUT`) halt polling immediately and publish an SNS alert.
- **Is idempotent** — a dispatch-lock mechanism (deterministic Scheduler schedule name per task+kind) prevents duplicate dispatches when both a native event and a scheduled poll hit the same task.

Loop-safety is unchanged. The classifier checks markers in priority order (`### Skill Update Spec` > `## Mitigation Plan` / `# Mitigation Summary` > `### CDK Change Spec` / `CLUSTER_VERSION` > stalled-with-Root-Cause-only), so a skill review that quotes mitigation headers never triggers a spurious mitigation dispatch, and a failure investigation that quotes upstream upgrade context still routes to next-steps, never to eks-upgrade.

## Why webhook (not SDK) for opening investigations

The DevOps Agent's `aidevops` API surface that we expose to Lambdas via the `devops-agent-sdk` layer is read-oriented (`ListJournalRecords`, `ListExecutions`) plus task-management (`UpdateBacklogTask`). There is no public SDK action for an external system to inject a new task into the agent's backlog. The supported way is the generic webhook with HMAC, which is what the Health, Failure, and Skill Review Lambdas all use. All three share a single webhook secret on the same agent space — one trust path, one signing scheme, one auth model. The Trigger Lambda opens no agent investigations — it only reads journal records, calls `UpdateBacklogTask` to activate mitigation, schedules polling, dispatches GitHub workflows, and publishes to SNS — so the webhook is purely the entry-point primitive for the three inbound Lambdas.

## Components

All resource names below are the unsuffixed defaults. Deploying with `NAME_SUFFIX=<s>` appends `-<s>` to every one of them (and to the agent space name), so several copies can coexist in one account.

| Component | Resource | Deployed by |
|---|---|---|
| Agent Space | `eks-upgrade-poc` (or suffixed) | CFN |
| Global Instructions | Safety constraints + isolation rules (All agents) | Manual (console) |
| Mitigation Instructions | Output format rules (Incident Mitigation) | Manual (console) |
| Skill: eks-upgrade-planning | 9-step upgrade investigation (Incident RCA) | Manual (console upload) |
| Skill: eks-investigation-triage-rules | Never-link rules (Incident Triage) | Manual (console upload) |
| Skill: eks-failure-root-cause | Failure RCA procedure (Incident RCA) | Manual (console upload) |
| Skill: eks-skill-review | Daily skill freshness review (Incident RCA) | Manual (console upload) |
| Health Lambda | `devops-agent-health-event` | CFN (inline) |
| Trigger Lambda | `devops-agent-trigger-upgrade` | CFN (inline; calls boto3 ListJournalRecords + ListExecutions + UpdateBacklogTask via `devops-agent-sdk` Lambda layer; routes the upgrade, next-steps, and skill-update workflows; publishes execution plans and skill-update summaries to SNS; schedules polling via EventBridge Scheduler) |
| Lambda Layer | `devops-agent-sdk` | CFN (artifact built from `lambda-layers/devops-agent-sdk/`, uploaded to S3 by `bootstrap.sh`) |
| Failure Lambda | `devops-agent-upgrade-failure-event` | CFN (inline; webhook to same space — no workflow dispatch; ownership guard drops rollbacks for stacks other than `ROOT_STACK_PREFIX`) |
| Skill Review Lambda | `devops-agent-skill-review-trigger` | CFN (inline; reads the four `SKILL.md` files via the GitHub Contents API, then webhooks the same space) |
| EventBridge rules | `eks-health-planned-lifecycle`, `devops-agent-investigation-events`, `eks-cfn-stack-failure`, `eks-skill-review-daily` (cron 08:00 UTC) | CFN |
| EventBridge Scheduler | One-time schedules for mitigation polling and dispatch locks | Created dynamically by Trigger Lambda (via `scheduler:CreateSchedule`) |
| Scheduler Role | IAM role assumed by EventBridge Scheduler to invoke Trigger Lambda | CFN |
| KMS Key | `alias/devops-agent-secrets` — customer-managed, rotation enabled; encrypts both secrets and the DLQ | CFN |
| Dead-letter queue | `devops-agent-lambda-dlq` — shared by all four Lambdas, 14-day retention | CFN |
| EventBridge log group | `/aws/events/eks-upgrade-pipeline` — 14-day retention; a target on the rules for diagnostic visibility | CFN |
| Webhook Secret | `devops-agent/webhook-credentials` | Secrets Manager (read by the Health, Failure, and Skill Review Lambdas) |
| GitHub PAT Secret | `devops-agent/github-pat` | Secrets Manager (read by the Trigger Lambda for `workflow_dispatch` and the Skill Review Lambda for the Contents API) |
| SNS Topic | `eks-upgrade-failure-mitigation` | CFN (operator notification on mitigation completion and on mitigation/investigation failure; subscribers added with `aws sns subscribe`) |
| SNS Topic | `eks-skill-update-notifications` | CFN (operator notification when the daily review finds skill changes; subscribers added with `aws sns subscribe`) |
| EKS Cluster | `eks-upgrade-poc` | CDK |
| Upgrade workflow | `.github/workflows/eks-upgrade.yml` | repo |
| Next-steps workflow | `.github/workflows/next-steps.yml` | repo |
| Skill update workflow | `.github/workflows/skill-update.yml` | repo |
| Post-merge deploy workflow | `.github/workflows/eks-deploy.yml` | repo |

## Safety constraints

- Control plane upgrades are **reversible for 7 days** via EKS version rollback — after the window closes, the upgrade is permanent
- `vpc-cni` MUST be updated before node groups (new AMIs expect updated CNI)
- One minor version at a time (1.30 → 1.31, never 1.30 → 1.32)
- `cdk diff` must show **Modify**, never **Replace** (Replace = cluster destruction)
- A failed upgrade does NOT auto-trigger another upgrade — the failure investigation produces a code fix PR (`next-steps.yml`), not a CDK upgrade PR. The only way to dispatch `eks-upgrade.yml` is for the agent to emit a `CDK Change Spec` block, which only happens when the upgrade-planning skill runs (Health-driven path). A skill review that quotes CDK spec examples can't reach it either — `### Skill Update Spec` is classified first.
- One rollback produces **one** investigation, even with several deployments in the same account — the Failure Lambda's [ownership guard](#ownership-guard-multiple-deployments-in-one-account) drops rollbacks for stacks the deployment doesn't own. Without it, N deployments produce N investigations and N mitigation PRs for a single failed deploy.
- A workflow never receives a partially-extracted spec. Both the Lambda and `next-steps.yml` require start-of-line headings and stop with an explicit error rather than passing an unparseable payload to Kiro CLI.
- Every Kiro CLI run is sandboxed to `read,write,glob,grep` — no shell, no network. Kiro cannot run a build, reach the internet, or resolve a version number of its own. The two CDK-editing paths additionally audit the resulting diff against an explicit allowlist (`eks-upgrade.yml`: `lib/iteration3-stack.ts` only; `next-steps.yml`: plus `package.json` / `package-lock.json`). `skill-update.yml` has no such audit — it edits documentation under `skills/`, which never reaches the cluster, and every change lands in a reviewed PR.
- No path deploys on its own. `eks-deploy.yml` is a manual `workflow_dispatch`, so a human merge and a human trigger both stand between an agent's output and the cluster.
