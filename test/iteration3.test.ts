import { execFileSync } from 'child_process';
import * as path from 'path';

// Proof that this project actively consumes cdk-nag.
//
// cdk-nag runs as an Aspect during synthesis (wired in bin/iteration3.ts) and
// fails `cdk synth` on any unsuppressed AwsSolutions finding. We assert that by
// actually synthesizing the app: a clean stack exits 0, and an unsuppressed
// violation makes synth exit non-zero. This is the same gate the CI/scan uses,
// so it stays faithful to real behavior (unlike Annotations.fromStack, which
// does not reliably capture cdk-nag findings on this nested-stack EKS app).
//
// The synth is slow (it resolves the kubectl Lambda layer), so allow a generous
// timeout.
describe('cdk-nag AwsSolutions gate', () => {
  const repoRoot = path.resolve(__dirname, '..');

  test('cdk synth succeeds with cdk-nag active (no unsuppressed findings)', () => {
    expect(() =>
      execFileSync('npx', ['cdk', 'synth', '--quiet'], {
        cwd: repoRoot,
        stdio: 'pipe',
      }),
    ).not.toThrow();
  }, 120_000);
});
