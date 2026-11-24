# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin:  packages/@aws-cdk/toolkit-lib/test/api/deployments/cloudformation-deployments.test.ts,
#            in aws/aws-cdk-cli
#   Commit:  eca1b73d682d7763955bec30ab5dd52bbc4327b6 (main, read on 2026-11-24)
#   Licence: Apache-2.0
#
# The origin holds 31 test declarations and 2 test.each tables with 2 rows
# each: 35 cases. None of them reaches this tool's engine, and this file holds
# no test: at this commit the origin no longer tests the deploy seam through
# this file (that moved to deploy-stack.test.ts, ported beside this file). It
# tests the Deployments facade — role assumption, bootstrap-version checks,
# the two-phase prepareStack, the rollback command, the reading of nested
# stacks' templates, and the caches of the asset publisher — a layer this tool
# does not have: the engine is RubyCdk::Deploy::Deployer, called with a client
# the adapters built, and every case below would test a class that does not
# exist here rather than a behaviour of one that does. What is portable of the
# substance (the skip rule, the no-change handling, the execution) is carried
# by the deploy-stack port; what the engine already does about a failed
# rollback state is pinned by its own unit tests (test/unit/deploy/).
#
# Not ported, with the reason, case by case:
#
#   A later wave builds what these need (outcome 3), the asset bucket and the
#   bootstrap stack:
#   - deployment fails if bootstrap stack is missing (requiresBootstrapStackVersion
#     with no toolkit info);
#   - deployment fails if bootstrap stack is too old (requires '99', found '5');
#   - bootstrap version failure keeps the BootstrapError as cause (the cause
#     chain carries the environment);
#   - if toolkit stack be found: false but SSM parameter name is present
#     deployment succeeds (test.each row);
#   - if toolkit stack be found: true but SSM parameter name is present
#     deployment succeeds (test.each row);
#   - cachedPublisher > does not reuse a publisher across different
#     environments for the same AssetManifest;
#   - cachedPublisher > reuses the cached publisher for repeat calls with the
#     same environment;
#   - allowCrossAccountAssetPublishingForEnv > does not reuse the answer
#     across different environments;
#   - allowCrossAccountAssetPublishingForEnv > reuses the cached answer for
#     repeat calls with the same environment.
#
#   Hotswap, which a later wave builds (outcome 3):
#   - passes through deploymentMethod with hotswap to deployStack().
#
#   A difference by design (outcome 4):
#   - the two-phase prepare and the internal willExecuteChangeSet flag (the
#     engine has one deploy call): prepareStack calls deployStack with
#     execute: false and returns successful result; prepareStack passes
#     willExecuteChangeSet through to deployStack; prepareStack leaves
#     willExecuteChangeSet unset for a user-requested --no-execute prepare;
#     prepareStack returns undefined for non-success results; prepareStack
#     forwards stackEventPollingInterval to cleanupChangeSet as the
#     stabilization interval; passes through stackEventPollingInterval to
#     deployStack(); passes through stackEventPollingInterval to destroyStack().
#     The engine takes its pollers as arguments instead of an interval option.
#   - roles, which the port does not carry (no assumeRoleArn, no
#     cloudFormationExecutionRoleArn, no per-stack role assumption; the
#     client is built once by the adapters; not in section 21 — reported):
#     placeholders are substituted in CloudFormation execution role; role with
#     placeholders is assumed if assumerole is given.
#   - nested stacks (docs/07-testing.md section 12), whose deployed templates
#     readCurrentTemplateWithNestedStacks assembles: readCurrentTemplateWithNestedStacks()
#     can handle non-Resources in the template; readCurrentTemplateWithNestedStacks()
#     with a 3-level nested + sibling structure works; readCurrentTemplateWithNestedStacks()
#     on an undeployed parent stack with an (also undeployed) nested stack
#     works; readCurrentTemplateWithNestedStacks() caches calls to
#     listStackResources(); readCurrentTemplateWithNestedStacks() successfully
#     ignores stacks without metadata.
#   - the rollback command (cdk rollback; this engine refuses a stack that
#     needs repair, with the way to repair it, architecture section 9; the
#     command itself does not exist here): rollback stack assumes role if
#     necessary; rollback stack allows rolling back from UPDATE_FAILED;
#     rollback stack is not failed by a throttled stack event poll; rollback
#     stack allows continue rollback from UPDATE_ROLLBACK_FAILED; rollback
#     stack fails in UPDATE_COMPLETE state; continue rollback stack with
#     orphanFailedResources forces the rollback; continue rollback stack with
#     orphanLogicalIds skips exactly those resources; rollback reports the
#     resources CloudFormation skipped; rollback reports skipped resources in
#     nested stacks qualified by their parent stacks. (The one behaviour of
#     these the engine does have — an event poll that fails must not fail the
#     operation — is the engine's own and is tested in test/unit/deploy/
#     execution_test.rb and by the destroy port.)
#   - lookup roles (lookups are not in 0.1.0, D-022 and section 21):
#     stackExists > uses lookup role if requested: false (test.each row);
#     stackExists > uses lookup role if requested: true (test.each row).
#
# Parity: 35 cases in the origin; 0 ported; 35 not ported.

require "test_helper"
