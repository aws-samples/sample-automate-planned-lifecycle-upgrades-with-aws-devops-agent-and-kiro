# Impact Analysis: EKS Version Rollback Feature

**Date:** 2026-07-01  
**Source:** [AWS Blog — Upgrade Amazon EKS clusters with confidence using Kubernetes version rollbacks](https://aws.amazon.com/blogs/aws/upgrade-amazon-eks-clusters-with-confidence-using-kubernetes-version-rollbacks/)  
**EKS Documentation:** [Rollback cluster to previous Kubernetes version](https://docs.aws.amazon.com/eks/latest/userguide/rollback-cluster.html)

## Feature Summary

EKS now supports Kubernetes control plane version rollback — clusters can revert to the previous minor version **within 7 days** of an upgrade. This is available at no additional cost in all commercial AWS Regions.

Key details:
- Rolls back one minor version at a time (matches upgrade constraint)
- EKS evaluates rollback readiness via **cluster insights** (node version compatibility, addon dependencies, API compatibility)
- `--force` flag bypasses readiness checks if needed
- Control plane rollback takes ~20 minutes
- EKS Auto Mode clusters also roll back worker nodes (respects PodDisruptionBudgets)
- Cancel API available for Auto Mode node rollbacks

## Impact on Current Solution

### Core Assumption Invalidated

This pipeline was designed around the premise that control plane upgrades are **irreversible**. That assumption drove:
- Elaborate pre-upgrade validation (7-step planning skill)
- Multi-phase failure recovery (root cause → mitigation agent → code fix PR)
- High risk classification for all upgrades
- EventBridge Scheduler polling for mitigation completion

**Control plane upgrades are now reversible within a 7-day window.**

### Files Requiring Updates

| File | Current State | Required Change |
|------|--------------|-----------------|
| `instructions/global-instructions.md` | States "IRREVERSIBLE — cannot downgrade" | Update to reflect 7-day rollback window |
| `skills/eks-upgrade-planning/SKILL.md` | Lines 76, 141 state "IRREVERSIBLE" | Add rollback readiness check step; update language |
| `skills/eks-failure-root-cause/SKILL.md` | Assumes CDK code fix is only recovery | Add rollback as first-line recovery option |
| `instructions/mitigation-agent-instructions.md` | Only produces code fixes + CLI steps | Evaluate rollback before code fix |
| `kiro-cdk-instructions.md` | References irreversibility constraint | Update safety constraints section |

### Upgrade Planning Skill Changes Needed

The `eks-upgrade-planning` skill should add:
1. **Rollback readiness check** — query cluster insights before recommending upgrade
2. **7-day window documentation** — include in recommendations output
3. **Rollback-aware risk assessment** — risk can be lower when rollback is available
4. **CDK Change Spec update** — add `ROLLBACK_AVAILABLE: YES | NO` field

### Failure Recovery Path Simplification

Current failure flow:
```
CloudFormation rollback detected
  → eks-failure-root-cause skill (diagnose)
  → Mitigation Agent activated (PENDING_START)
  → EventBridge Scheduler polls completion
  → SNS: immediate CLI steps
  → GitHub Actions: Kiro CLI code fix PR
```

Simplified flow with rollback:
```
Upgrade issue detected (within 7 days)
  → Evaluate: Is rollback simpler than code fix?
    → YES: Initiate EKS version rollback (single API call)
    → NO: Fall through to existing mitigation pipeline
```

### Risk Assessment Changes

| Scenario | Previous Risk | Updated Risk | Rationale |
|----------|--------------|--------------|-----------|
| Standard upgrade (no blockers) | MEDIUM | LOW | Rollback available as safety net |
| Upgrade with addon concerns | HIGH | MEDIUM | Can revert if addons break |
| Upgrade past 7-day window | N/A | HIGH | Rollback no longer available |
| Upgrade with deprecated APIs in use | HIGH | HIGH | Rollback won't fix API removal issues |

### Considerations for Rollback

Rollback is not always the right answer:
- **After 7 days**: Window closes, rollback unavailable
- **Node version skew**: If nodes were already upgraded, rollback readiness checks may flag issues
- **Addon forward-only changes**: Some addon updates may not be backward-compatible
- **Data plane state**: etcd data is preserved but workloads using new K8s features won't work on older version
- **PodDisruptionBudgets**: Auto Mode node rollback respects PDBs, may take time

## Recommended Next Steps

1. Update safety constraint language across all instructions and skills
2. Add rollback as a recovery strategy in the failure root cause skill
3. Add rollback readiness assessment to upgrade planning skill
4. Consider simplifying the mitigation pipeline for cases where rollback suffices
5. Update CDK Change Spec format to include rollback availability
6. Add a new triage decision: "rollback vs. fix forward" before activating Mitigation Agent
