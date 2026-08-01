# Global Instructions

These instructions apply to ALL agent types in this space (All agents).
Upload via: Knowledge > Instructions > All agents.

## EKS Upgrade Safety Constraints
- Control plane upgrades are REVERSIBLE within 7 days via EKS version rollback. After the 7-day window closes, the upgrade becomes permanent. Document rollback availability prominently.
- Before recommending rollback, check cluster insights for rollback readiness (node version compatibility, addon dependencies, API compatibility).
- vpc-cni addon MUST be updated before node groups (new AMIs expect updated CNI).
- Only one minor version at a time (e.g., 1.30 → 1.31, never 1.30 → 1.32).
- cdk diff must show Modify operations only. Replace = cluster destruction. STOP if any Replace is detected.

## EKS Version Rollback
- Rollback reverts one minor version (matches upgrade constraint).
- Available for 7 days after upgrade. After the window closes, rollback is unavailable.
- EKS evaluates rollback readiness via cluster insights before proceeding.
- Use `--force` flag to bypass readiness checks only when explicitly justified.
- Rollback is NOT appropriate when: deprecated APIs were already removed, addon updates are forward-only incompatible, or nodes were upgraded and have version skew issues.

## Investigation Isolation Rules
- Upgrade-planning investigations and failure investigations are INDEPENDENT workstreams.
- Never reference findings from an upgrade-planning investigation when performing failure root-cause analysis.
- Never reference failure investigation findings when performing upgrade planning.

## Output Format
- Always include the AWS Region and cluster name in findings.
- Structure output with clear markdown headings for downstream automation parsing.
