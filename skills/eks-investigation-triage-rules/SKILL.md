---
name: eks-investigation-triage-rules
description: >
  Triage rules for EKS upgrade pipeline investigations. Use during
  incident triage to determine whether new EKS-related incidents should
  be linked, skipped, or investigated independently.
scoped_to: Incident Triage
---

# EKS Investigation Triage Rules

## Never link these investigation types together

Upgrade-planning investigations (triggered by AWS Health planned lifecycle
events) and failure investigations (triggered by CloudFormation rollback
events) must ALWAYS proceed as independent investigations, even if they
relate to the same EKS cluster.

### Proceed as independent investigation when:
- The incident source is `aws.cloudformation` with a terminal rollback status
  AND there is an active upgrade-planning investigation for the same cluster
- The incident source is `aws.health` with eventTypeCode
  AWS_EKS_PLANNED_LIFECYCLE_EVENT AND there is an active failure investigation
- The incident description contains "daily skill review" AND there is an
  active upgrade-planning or failure investigation for the same cluster

### Correlation reasoning:
These are separate operational workstreams. An upgrade plan must not be
contaminated by failure analysis context, and failure root-cause analysis
must start fresh without assumptions from the upgrade plan.

Skill review investigations are periodic maintenance. Run them as
independent investigations. Never link a skill review to another
investigation, never defer one behind an active operational workflow, and
never skip one because an upgrade-planning or failure investigation is in
progress — an in-flight operational workflow is not a reason to decline the
review. "Must not interfere" means *stay isolated from*, not *yield to*: a
skill review only reads skill text and reaches no live cluster, so it cannot
disrupt operational work by running.

## Never skip an investigation

Nothing in this file authorises skipping or postponing an investigation.
Every rule above selects between *linking* and *proceeding independently*.
When no rule matches, proceed independently.
