---
name: eks-upgrade-planning
description: >
  Plan and validate EKS cluster version upgrades. Use this skill when
  investigating Amazon EKS planned lifecycle events, end-of-support
  upgrades, addon compatibility, or cluster version planning. Produces a
  CDK Change Spec with target versions for all components. Covers control
  plane upgrades, addon version compatibility, node group rolling updates,
  deprecated API detection, and upgrade sequencing requirements.
scoped_to: Incident RCA
---

# EKS Upgrade Planning

Use this skill to investigate and plan EKS cluster upgrades from one Kubernetes minor version to the next.

## Step 1: Discover cluster topology

Query the EKS cluster to map its current state:

- Cluster version and status via `describe-cluster`
- Node groups, their versions, instance types, and scaling config via `list-nodegroups` and `describe-nodegroup`
- Installed addons and their versions via `list-addons` and `describe-addon`
- **Helm charts via CloudFormation**: Discover the cluster's managing stack by reading the `aws:cloudformation:stack-name` tag from the `describe-cluster` response. Use ONLY that stack for `cloudformation list-stack-resources` — never enumerate or inspect other stacks in the account. Look for `Custom::AWSCDK-EKS-HelmChart` resources in that stack. These represent Helm-deployed controllers (e.g., aws-load-balancer-controller) that do NOT appear in the EKS addons API. For each Helm chart resource found, use `cloudformation describe-stack-resource` to extract the chart name, version, and repository from its properties. If the cluster has no `aws:cloudformation:stack-name` tag, skip Helm chart discovery entirely rather than guessing which stack to inspect.

Record all current versions. This is the baseline.

## Step 2: Validate upgrade target

EKS only supports upgrading ONE minor version at a time (e.g., 1.30 → 1.31, never 1.30 → 1.32).

Confirm:
- Target version = current version + 1 minor
- Target version is supported by EKS in this region

If the target skips a version, STOP and report the error.

## Step 3: Check addon compatibility

For each installed addon, query compatible versions for the target Kubernetes version using `describe-addon-versions --kubernetes-version <target>`.

Pick the **default** compatible version for each addon (the version where `compatibilities[0].defaultVersion` is `true`). The default is the AWS-recommended version that balances stability and features. Only use a non-default version if there's a specific reason (e.g., a known bug fix in a newer build). Document:
- Current version → target version
- Whether the version actually changes (some addons are already compatible)

Critical addons to always check:
- **vpc-cni** (CRITICAL — pod networking)
- **kube-proxy** (service networking)
- **coredns** (DNS resolution)

Also check Helm-deployed controllers:
- **aws-load-balancer-controller** — determine the correct chart version upgrade path:
  1. Fetch the Helm repository index at `https://aws.github.io/eks-charts/index.yaml` to get available versions.
  2. Check the [LBC compatibility matrix](https://kubernetes-sigs.github.io/aws-load-balancer-controller) to determine which versions support the target Kubernetes version.
  3. Select the **lowest version that adds support for the target K8s version** while being higher than the currently installed version. Do NOT jump to the absolute latest — incremental upgrades reduce risk.
  4. If the current version already supports the target K8s version (e.g., chart 1.10.0 supports K8s 1.27-1.31), keep it unchanged unless there's a specific reason to upgrade.
  5. Never skip more than one minor version of the chart (e.g., 1.10 → 1.11 is fine, 1.10 → 1.14 is not — intermediate versions may have breaking changes).

## Step 4: Scan for deprecated APIs

Check for Kubernetes APIs deprecated or removed in the target version.

Key removals by version:
- **1.25**: PodSecurityPolicy (policy/v1beta1) — REMOVED
- **1.26**: HorizontalPodAutoscaler (autoscaling/v2beta2) — use autoscaling/v2
- **1.27**: CSI migration mandatory for EBS
- **1.29**: FlowSchema (flowcontrol.apiserver.k8s.io/v1beta2) — use v1beta3
- **1.32**: FlowSchema (flowcontrol.apiserver.k8s.io/v1beta3) — use v1

If deprecated APIs are in use, flag as a BLOCKER. The upgrade cannot proceed until they are remediated.

## Step 5: Determine upgrade sequence

The upgrade sequence is NON-NEGOTIABLE:

1. **Control plane** — `UpdateClusterVersion`. Takes ~20 min. Rollback is available for 7 days after upgrade via EKS version rollback; after that window the upgrade is permanent.
2. **vpc-cni addon** — MUST be updated BEFORE node groups. New node AMIs expect the updated vpc-cni. If skipped, pods lose networking.
3. **kube-proxy addon** — after control plane, before or after nodes
4. **coredns addon** — after control plane, before or after nodes
5. **Node groups** — rolling update, takes ~15 min. MUST be AFTER all addon updates.

Each step must complete (status = ACTIVE) before the next begins.

## Step 6: Assess rollback readiness

Before recommending an upgrade, verify that rollback will be available as a safety net:

1. Query cluster insights via `eks list-insights` and `eks describe-insight` — check for any conditions that would prevent rollback (node version skew, addon incompatibilities, deprecated API usage).
2. Determine if any planned addon changes are forward-only (not backward-compatible after upgrade).
3. Note whether the cluster uses EKS Auto Mode (which also rolls back worker nodes, respecting PodDisruptionBudgets).

Set `ROLLBACK_AVAILABLE: YES` in the CDK Change Spec if no blocking conditions are found. Set `ROLLBACK_AVAILABLE: NO` if deprecated APIs will be removed (rollback won't help) or other conditions prevent rollback.

**Risk adjustment with rollback:**
- Standard upgrade with rollback available: LOW risk (was MEDIUM)
- Upgrade with addon concerns + rollback available: MEDIUM risk (was HIGH)
- Upgrade past 7-day window (rollback expired): HIGH risk
- Upgrade with deprecated APIs in active use: HIGH risk (rollback won't fix API removal)

## Step 7: Assess other risks and blockers

Check for:
- PodDisruptionBudgets that could block node drains (minAvailable == currentHealthy means no eviction headroom)
- Custom or non-standard configurations (Fargate profiles, self-managed nodes, non-vpc-cni CNI plugins)
- Insufficient IP addresses in subnets for rolling node updates

## Step 8: Validate and resolve artifact availability

Before producing the final spec, confirm all recommended versions are real, available, and represent a safe incremental upgrade. Never recommend a version jump that skips intermediate releases with potential breaking changes.

**Version upgrade principles:**
- One K8s minor version at a time (already enforced in Step 2)
- EKS addon versions: use `describe-addon-versions` output — AWS provides these as compatible versions for the target K8s version
- Helm charts: no more than one minor version jump at a time (e.g., 1.10 → 1.11, not 1.10 → 1.14)
- kubectl layer: must exactly match the target K8s minor version

**Validation steps:**

- **EKS addons**: Already validated via `describe-addon-versions` — verified to exist and be compatible.

- **Helm charts (aws-load-balancer-controller)**:
  1. Fetch `https://aws.github.io/eks-charts/index.yaml` to get available chart versions.
  2. If the current installed version already supports the target K8s version, keep it unchanged (safest path).
  3. If an upgrade is needed, select the next minor version above the current that supports the target K8s version. Verify it exists in the index.
  4. If the index fetch fails, check whether the CDK stack uses an OCI registry (`oci://public.ecr.aws/eks`). If so, note that AWS has migrated to `https://aws.github.io/eks-charts` and recommend updating the `repository` field.
  5. If all fetch attempts fail and the current version is known to support the target K8s version, keep it unchanged.

- **kubectl layer**: The npm package `@aws-cdk/lambda-layer-kubectl-v<minor>` is published for every GA EKS version. Must match the target K8s minor version exactly.

**FEASIBILITY rules:**

`FEASIBILITY` gates the entire pipeline: anything other than `READY` stops the
upgrade before any code change is generated. Set it from the rules below, not
from an overall impression of risk. Advisories belong in the risks section and
in `RISK:` — not in `FEASIBILITY` or `BLOCKERS`.

- `READY` — every version required by the spec is resolved and compatible. This
  is the correct answer even when real, non-blocking concerns exist; record
  those as risks and raise `RISK:` instead.
- `NEEDS_REMEDIATION` — **only** if a critical component (control plane,
  vpc-cni) has no compatible version available for the target. Nothing else
  qualifies.
- `BLOCKED` — the upgrade is invalid or impossible: more than one minor version
  jump, or the cluster is not in `ACTIVE` status.

**Never block on any of the following.** Each is an advisory — report it under
risks, and continue with `READY`:

- **Node group AMI type**, including Amazon Linux 2 deprecation. AWS stopped
  publishing *new* AL2 AMIs on 2025-11-26, but AMIs published before that date
  remain available for existing K8s versions. Verify before deciding: query
  `/aws/service/eks/optimized-ami/<target>/amazon-linux-2/recommended/image_id`
  in SSM. If an AMI exists for the target version, the node group can upgrade
  and this is **not** a blocker — recommend migrating to
  `AL2023_x86_64_STANDARD` as a follow-up action instead. AMI type is also
  orthogonal to the K8s version: it can be changed before or after this
  upgrade, so it never has to gate it.
- **A cluster insight in `ERROR` or `UNKNOWN` status.** Insights are inputs to
  your judgement, not verdicts. The `Amazon Linux 2 compatibility` insight
  reports `ERROR` on any AL2 node group regardless of whether a target AMI
  exists, and `EKS add-on version compatibility` reports `UNKNOWN` whenever EKS
  cannot determine compatibility automatically — neither is a blocker when your
  own `describe-addon-versions` queries resolved every addon.
- **Helm chart version** — the cluster functions without the latest chart.
- **A missing or `NOT_INSTALLED` component** — absent components need no
  upgrade.

If you believe something not listed above should block the upgrade, still emit
the spec with every version resolved, set `FEASIBILITY: READY`, raise `RISK:`
to `HIGH`, and describe the concern in the risks section. A human reviews every
generated PR before it merges, so a flagged risk is seen; a `NEEDS_REMEDIATION`
that halts the pipeline is not.

## Step 9: Produce recommendations

Your summary MUST include a `### CDK Change Spec` section inside a fenced code block.
Downstream automation parses this block — it MUST contain **only resolved values** from your
API queries above. Do NOT reproduce the format template below with angle brackets or "e.g."
examples in your output — emit only concrete version strings.

**FORMAT (for reference only — replace every placeholder with a real value):**

```
CLUSTER_VERSION: <resolved target, e.g. 1.31>
KUBECTL_LAYER_PACKAGE: @aws-cdk/lambda-layer-kubectl-v<resolved minor>
ADDON vpc-cni: <resolved, e.g. v1.21.2-eksbuild.2>
ADDON kube-proxy: <resolved>
ADDON coredns: <resolved>
HELM aws-load-balancer-controller: <resolved chart version, or NOT_INSTALLED>
FEASIBILITY: READY | BLOCKED | NEEDS_REMEDIATION
BLOCKERS: <comma-separated list, or NONE>
ROLLBACK_AVAILABLE: YES | NO
RISK: LOW | MEDIUM | HIGH
```

**YOUR OUTPUT must look like this (example with concrete values):**

### CDK Change Spec

```
CLUSTER_VERSION: 1.31
KUBECTL_LAYER_PACKAGE: @aws-cdk/lambda-layer-kubectl-v31
ADDON vpc-cni: v1.21.2-eksbuild.2
ADDON kube-proxy: v1.31.14-eksbuild.18
ADDON coredns: v1.11.4-eksbuild.39
HELM aws-load-balancer-controller: 1.12.0
FEASIBILITY: READY
BLOCKERS: NONE
ROLLBACK_AVAILABLE: YES
RISK: LOW
```

**Rules:**
- Every ADDON value MUST be a full `vX.Y.Z-eksbuild.N` string from `describe-addon-versions`.
- Use `NOT_INSTALLED` only for HELM if the chart is not present in the cluster.
- FEASIBILITY must be exactly one of: `READY`, `BLOCKED`, `NEEDS_REMEDIATION`,
  chosen strictly by the FEASIBILITY rules in Step 8. Default to `READY`
  whenever every version resolved — node group AMI type, AL2 deprecation, and
  insights in `ERROR`/`UNKNOWN` are advisories, never blockers.
- BLOCKERS must be `NONE` whenever FEASIBILITY is `READY`.
- Do NOT include angle brackets `< >`, the word "e.g.", or any placeholder text.

Also include a human-readable summary with:
- Current vs target versions for each component
- Upgrade sequence with expected durations
- Rollback availability (7-day window from upgrade completion; note any conditions that would prevent rollback)
- Any risks or warnings
