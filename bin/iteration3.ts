#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { Aspects } from 'aws-cdk-lib';
import { AwsSolutionsChecks } from 'cdk-nag';
import { EksUpgradePocStack } from '../lib/iteration3-stack';

const app = new cdk.App();

// Optional suffix for resource uniqueness within an account/region.
// Pass via `cdk deploy -c nameSuffix=alice` or set NAME_SUFFIX env var.
const nameSuffix = (app.node.tryGetContext('nameSuffix') ?? process.env.NAME_SUFFIX ?? '')
  .toString()
  .trim()
  .toLowerCase();

if (nameSuffix && !/^[a-z0-9-]{1,20}$/.test(nameSuffix)) {
  throw new Error(
    `Invalid nameSuffix "${nameSuffix}". Use 1-20 chars, lowercase alphanumeric or hyphens.`,
  );
}

// Optional DevOps Agent investigation task_id. The post-merge deploy workflow
// (eks-deploy.yml) parses it out of the merged PR body and passes it here via
// `cdk deploy -c investigationTaskId=<id>`. We apply it as a stack tag so the
// AWS-side failure detector can correlate any upgrade failure back to the
// investigation that produced this deploy.
const investigationTaskId = (app.node.tryGetContext('investigationTaskId') ?? '')
  .toString()
  .trim();

const stackName = nameSuffix ? `EksUpgradePocStack-${nameSuffix}` : 'EksUpgradePocStack';

const stack = new EksUpgradePocStack(app, stackName, {
  nameSuffix,
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION,
  },
});

if (investigationTaskId) {
  cdk.Tags.of(stack).add('InvestigationTaskId', investigationTaskId);
}

// cdk-nag: run the AWS Solutions rule pack as an Aspect during synthesis
// (cdk-nag v2). Any unsuppressed Error-level finding fails `cdk synth`, gating
// the scan. Suppressions for un-fixable CDK-generated resources live in the
// stack via NagSuppressions.
Aspects.of(app).add(new AwsSolutionsChecks({ verbose: true }));
