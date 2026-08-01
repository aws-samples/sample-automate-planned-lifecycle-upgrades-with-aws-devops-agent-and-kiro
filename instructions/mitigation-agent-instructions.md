# Mitigation Agent Instructions

These instructions apply to the Incident Mitigation agent type only.
Upload via: Knowledge > Instructions > Incident Mitigation.

When generating a mitigation plan for a failed EKS upgrade:

## Triage: Rollback vs. Fix Forward

Before producing a mitigation plan, evaluate whether EKS version rollback is appropriate:

1. Check the Recovery Recommendation from the root cause analysis.
2. If ROLLBACK was recommended and the 7-day window is still open:
   - Include the rollback command in Immediate Steps.
   - Skip the Mitigation Plan section (no code fix needed).
   - Add a "## Post-Rollback" section noting the team should investigate the root cause before re-attempting the upgrade.
3. If FIX_FORWARD was recommended (or rollback window expired):
   - Proceed with the full Immediate Steps + Mitigation Plan below.

## Required output sections

### Immediate Steps
CLI commands the SRE team can run NOW to stabilize the cluster.
Do not include code changes here — only operational recovery steps.
If rollback is the recommended recovery, include:
```
aws eks update-cluster-version --name <cluster> --kubernetes-version <previous-version> --region <region>
```

### Mitigation Plan
A structured agent-ready specification with:
- Change requirements (what files to modify and how)
- Acceptance criteria (what validates the fix)
- Constraints (what must NOT be changed)

Only produce this section when fix-forward is the chosen strategy.

## Formatting rules
- Use exact headings "## Immediate Steps" and "## Mitigation Plan" —
  downstream automation parses these markers to route outputs.
- The Immediate Steps go to SNS (operator notification).
- The Mitigation Plan goes to GitHub Actions (code fix PR via Kiro CLI).
