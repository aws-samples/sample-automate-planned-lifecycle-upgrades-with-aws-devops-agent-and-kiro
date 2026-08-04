# EKS Automated Upgrade Pipeline — Architecture

Detailed walkthrough in [`event-workflow.md`](./event-workflow.md).

Three event paths share one agent space, one `Investigation Completed` EventBridge
rule (`devops-agent-investigation-events`), and one Trigger Lambda that routes by
content marker. All resource names below are the un-suffixed form; deploying with
`NAME_SUFFIX` set appends `-<suffix>` to every name so several stacks can coexist
in one account.

## Sequence — upgrade path

```mermaid
sequenceDiagram
    participant Health as AWS Health
    participant EB as EventBridge
    participant HL as Health Lambda
    participant SM as AWS Secrets Manager
    participant DA as AWS DevOps Agent
    participant TL as Trigger Lambda
    participant GHA as GitHub Actions
    participant Kiro as Kiro CLI
    participant PR as GitHub PR

    Note over Health: EKS cluster approaching<br/>end-of-support

    Health->>EB: [1] AWS_EKS_PLANNED_LIFECYCLE_EVENT
    Note over EB: [2] eks-health-planned-lifecycle rule
    EB->>HL: [3] invoke

    HL->>SM: GetSecretValue(devops-agent/webhook-credentials)
    SM-->>HL: {url, secret}

    Note over HL: HMAC-SHA256 sign "timestamp:payload"<br/>(no parent linking — new investigation)
    HL->>DA: POST signed webhook

    Note over DA: [4] Runs eks-upgrade-planning skill<br/>(Steps 1-9) → CDK Change Spec<br/>recorded in journal records

    DA->>EB: [5] Investigation Completed<br/>{agent_space_id, task_id, execution_id, status}
    Note over EB: [6] devops-agent-investigation-events rule<br/>filtered by agent_space_id
    EB->>TL: invoke

    Note over TL: boto3.client('devops-agent')<br/>(via devops-agent-sdk Lambda layer —<br/>runtime boto3 doesn't ship the service)
    TL->>DA: aidevops:ListExecutions(agentSpaceId, taskId)
    DA-->>TL: executions[*].executionId
    TL->>DA: aidevops:ListJournalRecords<br/>(per execution)
    DA-->>TL: records[*].content

    Note over TL: Stitch findings, then classify in order:<br/>Skill Update Spec? NO<br/>H2 Mitigation Plan heading? NO<br/>CDK Change Spec? YES → upgrade.<br/>Take the dispatch lock, then dispatch.
    Note over TL: Payload = the investigation_result record<br/>(~3.8 KB, spec fence byte-identical).<br/>Falls back to slicing the transcript.<br/>Logs "Upgrade payload source=… bytes=…"

    TL->>SM: GetSecretValue(devops-agent/github-pat)
    SM-->>TL: PAT

    TL->>GHA: [7] workflow_dispatch eks-upgrade.yml<br/>{investigation_summary, investigation_findings}

    Note over GHA: Validate summary JSON<br/>(rejects unless investigation_type=upgrade)<br/>Write findings to /tmp/investigation-findings.md

    Note over GHA: Extract + validate CDK Change Spec.<br/>FEASIBILITY must be READY, else STOP.<br/>Exactly 1 valid block → /tmp/cdk-change-spec.txt

    Note over GHA: Install Kiro CLI + enforce KIRO_MIN_VERSION 1.0.3<br/>(older = hard fail, newer = warning)

    GHA->>Kiro: kiro-cli chat with spec file
    Note over Kiro: Read /tmp/cdk-change-spec.txt.<br/>Apply to lib/iteration3-stack.ts ONLY.<br/>No package.json / package-lock.json,<br/>no shell, no network.

    Kiro-->>GHA: Modified TypeScript

    Note over GHA: Enforce allowlist (lib/iteration3-stack.ts only)<br/>THEN swap kubectl layer via npm<br/>(npm resolves the published version)<br/>Validate: npm install + build + cdk synth

    GHA->>PR: peter-evans/create-pull-request@v7
    Note over PR: branch upgrade/eks-automated-{run_id}<br/>label eks-upgrade,automated<br/>investigation-context block embedded<br/>for eks-deploy.yml to read back
```

## Sequence — failure path (closed loop, single agent space with skill-based isolation + polling)

```mermaid
sequenceDiagram
    participant CFN as CloudFormation
    participant EB as EventBridge
    participant FL as Failure Lambda
    participant SM as AWS Secrets Manager
    participant DA as AWS DevOps Agent<br/>(same space)
    participant TL as Trigger Lambda
    participant Sched as EventBridge Scheduler
    participant GHA as GitHub Actions (next-steps.yml)
    participant SNS as SNS topic
    participant Kiro as Kiro CLI
    participant PR as GitHub PR

    CFN->>EB: [F1] Stack Status Change<br/>(ROLLBACK_COMPLETE / UPDATE_ROLLBACK_COMPLETE / *_FAILED)
    Note over EB: eks-cfn-stack-failure rule<br/>(terminal rollback statuses only —<br/>one event per failed deploy).<br/>NO stack-id filter — account-wide,<br/>so every deployment's rule sees it.

    EB->>FL: [F2] invoke
    Note over FL: Ownership guard: skip nested stacks, then<br/>require stack name == ROOT_STACK_PREFIX (exact).<br/>Rollbacks owned by another deployment are dropped,<br/>so one failure → one investigation.
    FL->>SM: GetSecretValue(webhook-credentials)
    SM-->>FL: {url, secret}

    Note over FL: Open BRAND NEW unlinked failure investigation<br/>on SAME agent space (shared webhook).<br/>Triage skill prevents linking to upgrade investigations.<br/>eks-failure-root-cause skill activates for RCA.
    FL->>DA: POST signed webhook

    Note over DA: [F3] eks-investigation-triage-rules ensures<br/>no linking to upgrade investigations.<br/>eks-failure-root-cause skill runs.<br/>Findings include an H3 Root Cause section.

    DA->>EB: Investigation Completed
    Note over EB: devops-agent-investigation-events rule<br/>filtered by agent_space_id
    EB->>TL: invoke

    TL->>DA: aidevops:ListExecutions + ListJournalRecords<br/>(all executions for the task)
    DA-->>TL: records[*].content

    Note over TL: [F4] Classified 'incomplete':<br/>H3 Root Cause found, no Skill Update Spec,<br/>no H2 Mitigation Plan / H1 Mitigation Summary.<br/>First re-check ListExecutions for an existing<br/>agentType == 'mitigation' execution — guards the<br/>loop when the event beats the journal writes.

    TL->>DA: aidevops:UpdateBacklogTask<br/>(taskStatus='PENDING_START')
    TL->>Sched: scheduler:CreateSchedule<br/>(5 min from now, invoke TL)

    Note over DA: Mitigation Agent runs under its OWN<br/>execution ID. Follows Incident Mitigation<br/>instructions. Produces execution plan +<br/>agent-ready spec. Does NOT emit<br/>Investigation Completed.

    Sched->>TL: [F5] scheduled invoke (5 min later)
    TL->>DA: aidevops:ListExecutions + ListJournalRecords
    DA-->>TL: records[*].content

    Note over TL: Start-of-line H2 Mitigation Plan or<br/>H1 Mitigation Summary? YES<br/>→ take dispatch lock, dispatch + publish.<br/>Otherwise re-check the mitigation execution:<br/>still running → 3-min recheck<br/>STOPPED → 1-min retry (records lagging)<br/>FAILED/CANCELED/TIMED_OUT → SNS alert, stop.<br/>Capped at MAX_POLLING_ATTEMPTS = 30.
    Note over TL: Payload = structured agent-ready spec from the<br/>write_mitigation_code_spec tool call (~1 KB) when present.<br/>Else the transcript slice (fallback, may hit the 45 KB cap).

    TL->>SM: GetSecretValue(github-pat)
    SM-->>TL: PAT

    par dispatch workflow (only if a code spec is present)
        TL->>GHA: [F6a] workflow_dispatch next-steps.yml<br/>{investigation_summary, investigation_findings}
    and operator notification (only if immediate steps are present)
        TL->>SNS: [F6b] sns:Publish<br/>execution plan (immediate CLI steps) +<br/>"review the code fix PR"
    end

    Note over GHA: [F7] Validate summary JSON<br/>(rejects unless investigation_type=mitigation)<br/>Extract spec: H1 Agent-ready spec first, else a<br/>start-of-line Mitigation section. No match → STOP.<br/>Install Kiro CLI + version gate

    GHA->>Kiro: kiro-cli chat with agent-ready spec
    Note over Kiro: Implement agent-ready spec in CDK code.<br/>Modify lib/iteration3-stack.ts +<br/>package.json as needed. File edits only —<br/>no build or shell commands.

    Kiro-->>GHA: Modified CDK files

    Note over GHA: Enforce allowlist (lib/iteration3-stack.ts,<br/>package.json, package-lock.json)<br/>then validate: npm install + build + cdk synth

    GHA->>PR: peter-evans/create-pull-request@v7
    Note over PR: branch fix/mitigation-{run_id}<br/>label eks-mitigation,automated
```

## Sequence — skill review path (daily maintenance)

```mermaid
sequenceDiagram
    participant EB as EventBridge
    participant SRL as Skill Review Lambda
    participant SM as AWS Secrets Manager
    participant GH as GitHub Contents API
    participant DA as AWS DevOps Agent<br/>(same space)
    participant TL as Trigger Lambda
    participant GHA as GitHub Actions (skill-update.yml)
    participant SNS as SNS topic
    participant Kiro as Kiro CLI
    participant PR as GitHub PR

    Note over EB: [S1] eks-skill-review-daily rule<br/>cron(0 8 * * ? *) — 08:00 UTC
    EB->>SRL: invoke

    SRL->>SM: GetSecretValue(github-pat)
    SM-->>SRL: PAT
    SRL->>GH: [S2] GET contents for 4 SKILL.md paths<br/>(upgrade-planning, failure-root-cause,<br/>investigation-triage-rules, skill-review)
    GH-->>SRL: raw markdown per skill
    Note over SRL: A failed fetch becomes<br/>"(FETCH FAILED — skip this skill)" —<br/>the review continues on the rest.<br/>eks-skill-review reviews ITSELF —<br/>nothing else does.
    SRL->>SM: GetSecretValue(webhook-credentials)
    SM-->>SRL: {url, secret}
    SRL->>DA: POST signed webhook<br/>(LOW-priority incident, current skills inline)

    Note over DA: [S3] Runs eks-skill-review skill.<br/>Compares skills against live AWS APIs + docs.<br/>Emits an H3 Skill Update Spec section with<br/>CHANGES_FOUND: YES or NO.

    DA->>EB: Investigation Completed
    Note over EB: devops-agent-investigation-events rule<br/>(same rule as the other two paths)
    EB->>TL: invoke

    TL->>DA: aidevops:ListExecutions + ListJournalRecords
    DA-->>TL: records[*].content

    Note over TL: [S4] Skill Update Spec is tested FIRST —<br/>skill content quotes the H2 Mitigation Plan<br/>marker when documenting the contract, which<br/>would otherwise false-match.<br/>Isolate the real spec (the SKILL.md template echo<br/>shows BOTH YES and NO examples, so the<br/>CHANGES_FOUND test runs on the EXTRACTED spec).

    alt Spec says CHANGES_FOUND YES
        TL->>GHA: workflow_dispatch skill-update.yml
        TL->>SNS: sns:Publish to eks-skill-update-notifications
    else Spec says CHANGES_FOUND NO
        Note over TL: skill_update_noop — no PR, no SNS
    else spec not isolatable
        TL->>GHA: dispatch full findings<br/>(workflow fails loudly rather than<br/>silently reporting no-op)
    end

    Note over GHA: [S5] Validate summary JSON<br/>Extract + validate Skill Update Spec<br/>(strip line-number gutters, reject template echo,<br/>keep the LAST real block)<br/>No changes → skip Kiro and PR steps

    GHA->>Kiro: kiro-cli chat with skill update spec
    Note over Kiro: Apply SUGGESTED_EDITs to skills/*/SKILL.md.<br/>Only the lines called out. No commit.

    Kiro-->>GHA: Modified SKILL.md files
    Note over GHA: Rebuild skills/*.zip so the PR carries<br/>uploadable artifacts

    GHA->>PR: peter-evans/create-pull-request@v7
    Note over PR: branch skill-update/automated-{run_id}<br/>label skill-update,automated
```

## Components

```mermaid
flowchart TB
    subgraph "Event Sources"
        Health["☁️ AWS Health<br/><i>Planned Lifecycle events</i>"]
        CFN["☁️ CloudFormation<br/><i>Stack Status Change</i>"]
        Cron["🕗 Daily schedule tick<br/><i>08:00 UTC</i>"]
        Agent["🤖 DevOps Agent<br/><i>single space, named after the cluster</i><br/><i>Skills: eks-upgrade-planning,<br/>eks-investigation-triage-rules,<br/>eks-failure-root-cause,<br/>eks-skill-review</i>"]
    end

    subgraph "Event Routing"
        EB["📡 EventBridge<br/><i>4 rules, each also logging to<br/>/aws/events/eks-upgrade-pipeline</i>"]
        Sched["⏰ EventBridge Scheduler<br/><i>one-time polling for mitigation completion<br/>+ deterministic dispatch locks</i>"]
    end

    subgraph "Lambdas"
        HL["⚡ devops-agent-health-event<br/><i>opens upgrade-planning investigation</i>"]
        FL["⚡ devops-agent-upgrade-failure-event<br/><i>opens unlinked failure investigation<br/>(same space; triage skill prevents linking)</i>"]
        SRL["⚡ devops-agent-skill-review-trigger<br/><i>fetches 4 SKILL.md from GitHub,<br/>opens skill-review investigation</i>"]
        TL["⚡ devops-agent-trigger-upgrade<br/><i>boto3 ListExecutions + ListJournalRecords +<br/>UpdateBacklogTask via devops-agent-sdk layer</i><br/><i>Routes by content marker, in order:<br/>Skill Update Spec → skill-update.yml + SNS (or no-op)<br/>Mitigation Plan/Summary → next-steps.yml + SNS<br/>CDK Change Spec → eks-upgrade.yml<br/>Root Cause only → UpdateBacklogTask + schedule poll<br/>none → logged no-op</i>"]
        DLQ["📮 devops-agent-lambda-dlq<br/><i>async failures, all 4 Lambdas</i>"]
    end

    subgraph "Secrets"
        SM1["🔐 devops-agent/webhook-credentials<br/><i>read by Health, Failure, Skill Review</i>"]
        SM2["🔐 devops-agent/github-pat<br/><i>read by Trigger, Skill Review</i>"]
        KMS["🔑 alias/devops-agent-secrets"]
    end

    subgraph "External"
        UpgradeGHA["🔄 eks-upgrade.yml"]
        NextStepsGHA["🔄 next-steps.yml"]
        SkillGHA["🔄 skill-update.yml"]
        DeployGHA["🔄 eks-deploy.yml<br/><i>manual, post-merge</i>"]
        Kiro["🤖 Kiro CLI<br/><i>--trust-tools=read,write,glob,grep</i>"]
        UpgradePR["📝 CDK PR"]
        NextStepsPR["📝 Code fix PR"]
        SkillPR["📝 Skill update PR"]
        SNS1["📣 eks-upgrade-failure-mitigation<br/><i>mitigation plan + failure/timeout alerts</i>"]
        SNS2["📣 eks-skill-update-notifications<br/><i>skill changes + review timeouts</i>"]
    end

    Health -->|"PLE event"| EB
    CFN -->|"rollback terminal"| EB
    Cron -->|"eks-skill-review-daily"| EB
    Agent -->|"Investigation Completed"| EB

    EB --> HL
    EB --> FL
    EB --> SRL
    EB --> TL
    Sched -->|"scheduled invoke"| TL

    HL -.-> DLQ
    FL -.-> DLQ
    SRL -.-> DLQ
    TL -.-> DLQ
    SM1 --- KMS
    SM2 --- KMS

    HL -->|"GetSecretValue"| SM1
    HL -->|"signed webhook"| Agent

    FL -->|"GetSecretValue"| SM1
    FL -->|"signed webhook"| Agent

    SRL -->|"GetSecretValue"| SM1
    SRL -->|"GetSecretValue"| SM2
    SRL -->|"signed webhook"| Agent

    TL -->|"GetSecretValue"| SM2
    TL -->|"ListExecutions + ListJournalRecords"| Agent
    TL -->|"UpdateBacklogTask"| Agent
    TL -->|"CreateSchedule (poll + lock)"| Sched
    TL -->|"workflow_dispatch<br/>(CDK Change Spec)"| UpgradeGHA
    TL -->|"workflow_dispatch<br/>(Mitigation Plan/Summary<br/>+ code spec)"| NextStepsGHA
    TL -->|"workflow_dispatch<br/>(CHANGES_FOUND: YES)"| SkillGHA
    TL -->|"sns:Publish<br/>(if immediate steps)"| SNS1
    TL -->|"sns:Publish"| SNS2

    UpgradeGHA --> Kiro
    NextStepsGHA --> Kiro
    SkillGHA --> Kiro
    UpgradeGHA --> UpgradePR
    NextStepsGHA --> NextStepsPR
    SkillGHA --> SkillPR
    UpgradePR -->|"merge, then manual run"| DeployGHA
```

## Deployment boundaries

| Boundary | Components | Managed via |
|---|---|---|
| CloudFormation stack (`devops-agent-space.yaml`) | Single Agent Space, IAM, 4 EventBridge rules, 4 Lambdas + `devops-agent-sdk` layer, Secrets Manager + KMS key, 2 SNS topics, DLQ, EventBridge log group, Scheduler Role | `aws cloudformation deploy` (run by `bootstrap.sh`) |
| CDK stack (`lib/iteration3-stack.ts`) | EKS cluster, addons, node group, Helm charts | `cdk deploy` (run by `bootstrap.sh` or `eks-deploy.yml`) |
| GitHub | `eks-upgrade.yml`, `next-steps.yml`, `skill-update.yml`, `eks-deploy.yml` | repo |
| DevOps Agent space | Global Instructions, agent-type instructions, 4 skills, generic webhook | manual config after `bootstrap.sh` |

Set `NAME_SUFFIX` to run more than one deployment in a single account — the CFN
stack suffixes every resource name and the CDK stack becomes
`EksUpgradePocStack-<suffix>`.

## Key data flows

| Step | From | To | Data | Protocol |
|---|---|---|---|---|
| [1] | AWS Health | EventBridge | PLE event | EventBridge native |
| [3] | EventBridge | Health Lambda | Health event JSON | Lambda invoke |
| [3] | Health Lambda | DevOps Agent | HMAC-signed webhook (new upgrade-planning investigation) | HTTPS POST |
| [5] | DevOps Agent | EventBridge | Investigation Completed metadata | EventBridge native |
| [6] | Trigger Lambda | DevOps Agent | `aidevops:ListExecutions`, then `aidevops:ListJournalRecords` per execution (via boto3 in the `devops-agent-sdk` Lambda layer) | HTTPS POST |
| [7] | Trigger Lambda | GitHub API | `workflow_dispatch` — `eks-upgrade.yml` (CDK Change Spec), `next-steps.yml` (Mitigation Plan), or `skill-update.yml` (Skill Update Spec) | HTTPS POST |
| [9] | Kiro CLI | repo files | Modified TypeScript (upgrade or code fix) or `skills/*/SKILL.md` | filesystem |
| [F2] | Failure Lambda | DevOps Agent (same space) | HMAC-signed webhook (unlinked failure investigation; triage skill prevents linking) | HTTPS POST |
| [F4] | Trigger Lambda | DevOps Agent | `aidevops:UpdateBacklogTask(PENDING_START)` | HTTPS POST |
| [F4] | Trigger Lambda | EventBridge Scheduler | `scheduler:CreateSchedule` (5-min one-time poll; 3-min or 1-min on recheck) | HTTPS POST |
| [F5] | EventBridge Scheduler | Trigger Lambda | Scheduled invoke (polling for mitigation completion, max 30 attempts) | Lambda invoke |
| [F6b] | Trigger Lambda | `eks-upgrade-failure-mitigation` | Execution plan (immediate CLI steps, excludes Code Change Spec) | sns:Publish |
| [S2] | Skill Review Lambda | GitHub API | `GET /repos/{repo}/contents/{path}` × 4 SKILL.md | HTTPS GET |
| [S2] | Skill Review Lambda | DevOps Agent | HMAC-signed webhook (skill-review investigation, skills inline) | HTTPS POST |
| [S4] | Trigger Lambda | `eks-skill-update-notifications` | Detected skill changes + pointer to the PR | sns:Publish |
| — | Trigger Lambda | SNS (routed by task type) | `TIMED_OUT` alert — skill reviews to `eks-skill-update-notifications`, everything else to `eks-upgrade-failure-mitigation` | sns:Publish |
