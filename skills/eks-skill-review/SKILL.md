---
name: eks-skill-review
description: >
  Daily review of EKS upgrade pipeline skills for gaps caused by newly
  announced AWS/Amazon EKS changes. Use this skill when the incident
  description mentions "daily skill review". Checks whether the current
  skill content is still factually correct against AWS service reality.
  Does NOT inspect live clusters.
scoped_to: Incident RCA
---

# EKS Skill Review

## Goal

The incident description quotes the current content of four skills:

- `eks-upgrade-planning/SKILL.md`
- `eks-failure-root-cause/SKILL.md`
- `eks-investigation-triage-rules/SKILL.md`
- `eks-skill-review/SKILL.md` — this skill; review it on the same terms as
  the others. If a fetch failed, the description says so for that skill;
  review only the skills whose content is present.

Decide whether any of that content is now **factually wrong, incomplete, or
outdated** against current AWS/Amazon EKS reality, and emit a Skill Update Spec
describing the minimal edits that would fix it.

These skills go stale silently: supported EKS version lists, deprecated
Kubernetes API removal tables, addon behaviour, upgrade and rollback semantics,
and known CloudFormation failure modes all change on AWS's schedule, and nothing
else in the pipeline notices. That is the gap you are closing.

## How to verify

Verify every claim against authoritative AWS sources — live AWS APIs, AWS
documentation, and Amazon EKS/Kubernetes release notes. Do **not** rely on
recollection or training data: the whole point of this review is to catch
changes that post-date what any model already knows. Choose the tools and
queries yourself.

## Constraints

- Flag only **factual accuracy gaps** caused by AWS service or documentation
  changes. Not style, not organisation, not "best practice" suggestions.
- Do **NOT** query, describe, or inspect any live Amazon EKS cluster. This
  review is about whether the skill text matches AWS reality, not whether a
  particular cluster is healthy.
- If a lookup fails, a source is ambiguous, or you cannot confirm a change from
  an authoritative source, do **NOT** propose an edit. Silence is the correct
  answer when unsure.
- Prefer minimal, targeted edits over rewrites. Each suggested edit must be
  self-contained and independently mergeable.

## Output

Downstream automation parses the block below — reproduce the field names and
structure exactly.

If changes are needed:

```
### Skill Update Spec

SKILL: <skill-name>
SECTION: <which section needs updating>
CHANGE_TYPE: ADD | UPDATE | REMOVE
DESCRIPTION: <what changed in AWS and why the skill needs updating, citing the source>
SUGGESTED_EDIT: |
  <exact text to add or replace>

...repeat for each change...

CHANGES_FOUND: YES
```

If NO changes are needed:

```
### Skill Update Spec
CHANGES_FOUND: NO
REVIEW_SUMMARY: All skills are current as of <date>. No new AWS announcements affect the documented upgrade process.
```
