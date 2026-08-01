---
name: eks-failure-root-cause
description: >
  Root cause analysis for CloudFormation deployment failures. Use ONLY
  when the incident description mentions CloudFormation rollback,
  UPDATE_ROLLBACK_COMPLETE, ROLLBACK_COMPLETE, or deployment failure.
  Do NOT use for planned lifecycle events or upgrade planning.
scoped_to: Incident RCA
---

# EKS Failure Root Cause Analysis

When an EKS upgrade deployment fails (CloudFormation rollback), investigate:

## Step 1: Identify the failed resources
Check the CloudFormation stack events for resources with status *_FAILED.

## Step 2: Analyze failure reasons
For each failed resource, determine whether the failure is:
- Addon version incompatibility
- API deprecation in the target Kubernetes version
- Node group AMI / CNI mismatch
- Helm chart version incompatibility
- Transient control plane issue

## Step 3: Evaluate rollback as recovery option

Before recommending a code fix, determine whether EKS version rollback is the simpler recovery path:

1. Check if the upgrade was completed within the last 7 days (rollback window still open).
2. Query cluster insights for rollback readiness conditions.
3. Assess whether the failure root cause would be resolved by rollback (e.g., addon incompatibility, control plane issue) vs. problems rollback cannot fix (deprecated API removal, forward-only data migration).

**Recommend rollback when:**
- The upgrade completed within 7 days AND
- The failure is caused by version incompatibility (addon, AMI, chart) AND
- Cluster insights show no rollback blockers

**Do NOT recommend rollback when:**
- The 7-day window has expired
- The failure involves deprecated API removal (old version won't have the APIs either after re-registration)
- Node groups were already upgraded and have version skew
- Addon changes are forward-only incompatible

## Step 4: Produce root cause

Output a structured root cause with:
### Root Cause:
<concise statement>

### Evidence:
<supporting CloudFormation events, CloudWatch logs, or API responses>

### Affected Components:
<list of resources that need remediation>

### Recovery Recommendation:
<ROLLBACK or FIX_FORWARD>

If ROLLBACK:
- Confirm rollback window status (days remaining)
- Note any rollback readiness warnings from cluster insights
- Provide rollback command: `aws eks update-cluster-version --name <cluster> --kubernetes-version <previous-version> --region <region>`

If FIX_FORWARD:
- Proceed to Mitigation Agent activation (existing pipeline)
