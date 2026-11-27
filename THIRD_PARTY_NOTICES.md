# Third-party notices

This gem contains code and tests ported from the AWS Cloud Development Kit (AWS CDK), and will contain test fixtures taken from other open-source projects as later waves port their suites. Every ported file starts with a header that names its origin path, the commit it was read at, its licence and what was changed. This file lists them all, and carries the licence texts.

The gem's own code is under the licence in the `LICENSE` file. A ported file, and the ported parts of a file, remain under the licence of the work they were ported from.

## How to add a suite

1. Give the upstream project its own `###` heading below, with its copyright line and its repository. If the project is already there, add to its table.
2. Add one row per ported file: the file in this repository, the path of the file it was ported from, the full commit it was read at, the licence, and whether it is code or tests.
3. If the licence is not yet reproduced at the end of this file, add its full text there.

## Ported files

### AWS Cloud Development Kit

Copyright 2018-2026 Amazon.com, Inc. or its affiliates. All Rights Reserved.

Repository: <https://github.com/aws/aws-cdk>. Licence: Apache-2.0, the full text of which is at the end of this file.

The files of the test kit were read at commit `025a6f67fec3d37a6ffdc6168f8a751a04918f66` (the head of `main` on 2026-11-23); the commit each other table was read at stands in the line above it, and a table whose rows read at different commits carries a `Read at` column. The matcher engine of the CDK lives in the internal `matching` package, which the `assertions` package re-exports: the files ported from it say so.

#### Code: `RubyCdk::Test`, the equivalent of `aws-cdk-lib/assertions`

| File in this repository | Ported from | Licence | What it is |
|---|---|---|---|
| `lib/ruby_cdk/test.rb` | `packages/aws-cdk-lib/assertions/lib/index.ts`, `packages/aws-cdk-lib/matching/lib/match.ts` | Apache-2.0 | The public surface of the module and the `Match` factories |
| `lib/ruby_cdk/test/matcher.rb` | `packages/aws-cdk-lib/matching/lib/matcher.ts` | Apache-2.0 | `Matcher`, `MatchResult` and its rendering |
| `lib/ruby_cdk/test/match.rb` | `packages/aws-cdk-lib/matching/lib/match.ts` | Apache-2.0 | The ten matchers |
| `lib/ruby_cdk/test/capture.rb` | `packages/aws-cdk-lib/matching/lib/capture.ts` | Apache-2.0 | `Capture` |
| `lib/ruby_cdk/test/template.rb` | `packages/aws-cdk-lib/assertions/lib/template.ts` | Apache-2.0 | `Template` |
| `lib/ruby_cdk/test/private/error.rb` | `packages/aws-cdk-lib/matching/lib/private/error.ts` | Apache-2.0 | `AssertionError` |
| `lib/ruby_cdk/test/private/type.rb` | `packages/aws-cdk-lib/matching/lib/private/type.ts` | Apache-2.0 | The type of a value, as the messages name it |
| `lib/ruby_cdk/test/private/sorting.rb` | `packages/aws-cdk-lib/matching/lib/private/sorting.ts` | Apache-2.0 | Sorting by a key |
| `lib/ruby_cdk/test/private/sparse_matrix.rb` | `packages/aws-cdk-lib/matching/lib/private/sparse-matrix.ts` | Apache-2.0 | What `array_with` remembers of its backtracking |
| `lib/ruby_cdk/test/private/absent.rb` | `packages/aws-cdk-lib/matching/lib/private/matchers/absent.ts` | Apache-2.0 | The matcher behind `absent` |
| `lib/ruby_cdk/test/private/section.rb` | `packages/aws-cdk-lib/assertions/lib/private/section.ts` | Apache-2.0 | Matching one section of a template |
| `lib/ruby_cdk/test/private/resources.rb` | `packages/aws-cdk-lib/assertions/lib/private/resources.ts` | Apache-2.0 | The `Resources` section |
| `lib/ruby_cdk/test/private/cyclic.rb` | `packages/aws-cdk-lib/assertions/lib/private/cyclic.ts` | Apache-2.0 | The check for dependency cycles |
| `lib/ruby_cdk/test/private/outputs.rb` | `packages/aws-cdk-lib/assertions/lib/private/outputs.ts` | Apache-2.0 | The `Outputs` section |
| `lib/ruby_cdk/test/private/parameters.rb` | `packages/aws-cdk-lib/assertions/lib/private/parameters.ts` | Apache-2.0 | The `Parameters` section |
| `lib/ruby_cdk/test/private/mappings.rb` | `packages/aws-cdk-lib/assertions/lib/private/mappings.ts` | Apache-2.0 | The `Mappings` section |
| `lib/ruby_cdk/test/private/conditions.rb` | `packages/aws-cdk-lib/assertions/lib/private/conditions.ts` | Apache-2.0 | The `Conditions` section |

`lib/ruby_cdk/test/private/js.rb` is not ported from a file: the CDK has none to translate. It reproduces in Ruby the JavaScript the CDK's messages are written in (`typeof`, `String()`, `JSON.stringify`), so that a failure reads the same in both.

#### Code: the curated constructs (Waves 7 and 8)

All read at commit `c070afb54b9e4dbddd52a85a21077fe970354985` (aws/aws-cdk, `main`, read 2026-11-25 and 2026-11-27); Apache-2.0.

| File in this repository | Ported from | Licence | What it is |
|---|---|---|---|
| `lib/ruby_cdk/constructs/bucket.rb` | `packages/aws-cdk-lib/aws-s3/lib/bucket.ts` | Apache-2.0 | The L2 bucket: encryption and the public access block written out, grants |
| `lib/ruby_cdk/constructs/function.rb` | `packages/aws-cdk-lib/aws-lambda/lib/function.ts` | Apache-2.0 | The L2 function: code, handler, runtime, environment, grants |
| `lib/ruby_cdk/constructs/log_group.rb` | `packages/aws-cdk-lib/aws-logs/lib/log-group.ts` | Apache-2.0 | The L2 log group: retention, the `/aws/lambda/<name>` shape |
| `lib/ruby_cdk/constructs/queue.rb` | `packages/aws-cdk-lib/aws-sqs/lib/queue.ts` | Apache-2.0 | The L2 queue and its grants |
| `lib/ruby_cdk/constructs/topic.rb` | `packages/aws-cdk-lib/aws-sns/lib/topic.ts` | Apache-2.0 | The L2 topic and its grants |
| `lib/ruby_cdk/constructs/table.rb` | `packages/aws-cdk-lib/aws-dynamodb/lib/table.ts` | Apache-2.0 | The L2 table: billing, point-in-time recovery, grants |
| `lib/ruby_cdk/constructs/role.rb` | `packages/aws-cdk-lib/aws-iam/lib/role.ts` | Apache-2.0 | The L2 role: trust policy, managed policies, grants |
| `lib/ruby_cdk/constructs/ssm_parameter.rb` | `packages/aws-cdk-lib/aws-ssm/lib/parameter.ts` | Apache-2.0 | `StringParameter` and `StringListParameter` as one class: name checks, tiers, allowed pattern, read/write grants |
| `lib/ruby_cdk/constructs/secret.rb` | `packages/aws-cdk-lib/aws-secretsmanager/lib/secret.ts`, `packages/aws-cdk-lib/core/lib/secret-value.ts` | Apache-2.0 | `fromSecretNameV2` and `SecretValue.secretsManager` as reference-only helpers: no tree node, no lookup, no grants |
| `lib/ruby_cdk/constructs/schedule.rb` | `packages/aws-cdk-lib/aws-events/lib/schedule.ts` | Apache-2.0 | The `Schedule` factories: `rate`, `cron`, `expression` |
| `lib/ruby_cdk/constructs/events_rule.rb` | `packages/aws-cdk-lib/aws-events/lib/rule.ts` | Apache-2.0 | The `Rule`: schedule and event pattern, pattern merging, targets |
| `lib/ruby_cdk/constructs/restapi.rb` | `packages/aws-cdk-lib/aws-apigateway/lib/lambda-api.ts`, `integrations/lambda.ts`, `restapi.ts` | Apache-2.0 | `LambdaRestApi` over `RestApi`: the proxy resource, the ANY methods, the deployment and stage, the endpoint output |

#### Tests: the CDK's own tests of that package, ported

| File in this repository | Ported from | Licence | Cases |
|---|---|---|---|
| `test/cdk/assertions/match_test.rb` | `packages/aws-cdk-lib/assertions/test/match.test.ts` | Apache-2.0 | 35 ported, 0 not ported |
| `test/cdk/assertions/capture_test.rb` | `packages/aws-cdk-lib/assertions/test/capture.test.ts` | Apache-2.0 | 12 ported, 0 not ported |
| `test/cdk/assertions/render_test.rb` | `packages/aws-cdk-lib/assertions/test/render.test.ts`, `packages/aws-cdk-lib/assertions/test/__snapshots__/render.test.ts.snap` | Apache-2.0 | 11 ported, 0 not ported |
| `test/cdk/assertions/section_test.rb` | `packages/aws-cdk-lib/assertions/test/private/section.test.ts` | Apache-2.0 | 2 ported, 0 not ported |
| `test/cdk/assertions/template_test.rb` | `packages/aws-cdk-lib/assertions/test/template.test.ts` | Apache-2.0 | 82 ported, 3 not ported (listed in the header of the file) |

Two files of the package are not ported, because they test what this tool does not have: `annotations.test.ts` (23 cases, the CDK's synth-time annotations) and `tags.test.ts` (12 runtime cases, the `Tags` aspect).

#### Tests: other suites of the CDK, ported

| File in this repository | Ported from | Read at | Cases |
|---|---|---|---|
| `test/cdk/core/fn_test.rb` | `packages/aws-cdk-lib/core/test/fn.test.ts` | `78649cb7cf7399204ed63f629964779eeaa8b37a` | 14 of 23 ported; the others listed in the header |
| `test/unit/assets/hasher_test.rb` | `packages/aws-cdk-lib/core/test/fs/fs-fingerprint.test.ts`, `packages/aws-cdk-lib/aws-s3-assets/test/asset.test.ts`, `packages/aws-cdk-lib/core/test/staging.test.ts` | `78649cb7cf7399204ed63f629964779eeaa8b37a` | 9 ported; the others listed in the header |
| `test/unit/assets/record_test.rb` | `packages/aws-cdk-lib/aws-s3-assets/test/asset.test.ts` | `78649cb7cf7399204ed63f629964779eeaa8b37a` | 1 ported; the rest of asset.test.ts not ported (listed in the header) |
| `test/cdk/core/stack_test.rb` | `packages/aws-cdk-lib/core/test/stack.test.ts` | `622f51fa4999d5557c1d1da292c04cc186ac6818` | 36 ported, 132 not ported (listed in the header) |
| `test/cdk/core/resource_test.rb` | `packages/aws-cdk-lib/core/test/resource.test.ts` | `622f51fa4999d5557c1d1da292c04cc186ac6818` | 13 ported, 25 not ported (listed in the header) |
| `test/cdk/validation/valid_test.rb` | `packages/aws-cdk-lib/cloudformation-include/test/valid-templates.test.ts` | `68b2516c09791d78b199f30e455e4670dc9cde6d` | 56 ported, 26 not ported (listed in the header) |
| `test/cdk/validation/invalid_test.rb` | `packages/aws-cdk-lib/cloudformation-include/test/invalid-templates.test.ts` | `68b2516c09791d78b199f30e455e4670dc9cde6d` | 30 ported, 12 not ported (listed in the header) |

#### Tests: the constructs' own suites, ported

All read at commit `c070afb54b9e4dbddd52a85a21077fe970354985` (aws/aws-cdk, `main`, read 2026-11-25 and 2026-11-27); Apache-2.0.

| File in this repository | Ported from | Licence | Cases |
|---|---|---|---|
| `test/cdk/constructs/bucket_test.rb` | `packages/aws-cdk-lib/aws-s3/test/bucket.test.ts` | Apache-2.0 | 11 ported, 189 not ported (listed in the header) |
| `test/cdk/constructs/events_rule_test.rb` | `packages/aws-cdk-lib/aws-events/test/rule.test.ts` | Apache-2.0 | 15 ported, 28 not ported (listed in the header) |
| `test/cdk/constructs/function_test.rb` | `packages/aws-cdk-lib/aws-lambda/test/function.test.ts` | Apache-2.0 | 5 ported, 199 not ported (listed in the header) |
| `test/cdk/constructs/log_group_test.rb` | `packages/aws-cdk-lib/aws-logs/test/loggroup.test.ts` | Apache-2.0 | 5 ported, 48 not ported (listed in the header) |
| `test/cdk/constructs/queue_test.rb` | `packages/aws-cdk-lib/aws-sqs/test/sqs.test.ts` | Apache-2.0 | 6 ported, 53 not ported (listed in the header) |
| `test/cdk/constructs/restapi_test.rb` | `packages/aws-cdk-lib/aws-apigateway/test/restapi.test.ts`, `packages/aws-cdk-lib/aws-apigateway/test/lambda-api.test.ts` | Apache-2.0 | 3 ported, 95 not ported (listed in the header) |
| `test/cdk/constructs/role_test.rb` | `packages/aws-cdk-lib/aws-iam/test/role.test.ts` | Apache-2.0 | 16 ported, 41 not ported (listed in the header) |
| `test/cdk/constructs/ssm_parameter_test.rb` | `packages/aws-cdk-lib/aws-ssm/test/parameter.test.ts` | Apache-2.0 | 22 ported, 41 not ported (listed in the header) |
| `test/cdk/constructs/table_test.rb` | `packages/aws-cdk-lib/aws-dynamodb/test/dynamodb.test.ts` | Apache-2.0 | 12 ported, 154 not ported (listed in the header) |
| `test/cdk/constructs/topic_test.rb` | `packages/aws-cdk-lib/aws-sns/test/sns.test.ts` | Apache-2.0 | 10 ported, 44 not ported (listed in the header) |

#### Fixtures: the corpus sample

| Directory in this repository | Taken from | Read at | Licence | What it is |
|---|---|---|---|---|
| `test/fixtures/corpus/templates/` (400 files, chosen as `META.json` says) | every `*.template.json` of the repository, copied byte for byte | `622f51fa4999d5557c1d1da292c04cc186ac6818` | Apache-2.0 | Templates the CDK synthesized; the validator is measured against them |

The sample follows the CDK: the weekly job in `.github/workflows/audit.yml` fetches its templates again and moves the sample, and `META.json` then names the commit.

### AWS Cloud Development Kit CLI

Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.

Repository: <https://github.com/aws/aws-cdk-cli>. Licence: Apache-2.0, the full text of which is at the end of this file.

#### Tests: the publisher of assets, ported

| File in this repository | Ported from | Read at | Cases |
|---|---|---|---|
| `test/unit/assets/zipper_test.rb` | `packages/@aws-cdk/private-tools/test/zip/zip.test.ts`, `packages/@aws-cdk/cdk-assets-lib/test/archive.test.ts` | `eca1b73d682d7763955bec30ab5dd52bbc4327b6` | 7 ported; the others listed in the header |
| `test/unit/assets/uploader_test.rb` | `packages/@aws-cdk/cdk-assets-lib/test/files.test.ts`, `packages/@aws-cdk/cdk-assets-lib/test/zipping.test.ts` | `eca1b73d682d7763955bec30ab5dd52bbc4327b6` | 6 ported; the others listed in the header |

#### Tests: the deploy, destroy and diff commands, ported

All read at commit `eca1b73d682d7763955bec30ab5dd52bbc4327b6` (`main`, read 2026-11-24 and 2026-11-25); Apache-2.0.

| File in this repository | Ported from | Read at | Cases |
|---|---|---|---|
| `test/cdk/cli/deploy_stack_test.rb` | `packages/@aws-cdk/toolkit-lib/test/api/deployments/deploy-stack.test.ts` | `eca1b73d682d7763955bec30ab5dd52bbc4327b6` | 40 ported, 77 not ported (listed in the header) |
| `test/cdk/cli/cloudformation_deployments_test.rb` | `packages/@aws-cdk/toolkit-lib/test/api/deployments/cloudformation-deployments.test.ts` | `eca1b73d682d7763955bec30ab5dd52bbc4327b6` | 0 ported, 35 not ported (listed in the header) |
| `test/cdk/cli/destroy_test.rb` | `packages/@aws-cdk/toolkit-lib/test/actions/destroy.test.ts` | `eca1b73d682d7763955bec30ab5dd52bbc4327b6` | 4 ported, 21 not ported (listed in the header) |
| `test/cdk/diff/commands_diff_test.rb` | `packages/aws-cdk/test/commands/diff.test.ts` | `eca1b73d682d7763955bec30ab5dd52bbc4327b6` | 11 ported, 41 not ported (listed in the header) |
| `test/cdk/diff/diff_template_test.rb` | `packages/@aws-cdk/cloudformation-diff/test/diff-template.test.ts` | `eca1b73d682d7763955bec30ab5dd52bbc4327b6` | 26 ported, 5 not ported (listed in the header) |

### stelligent/cfn_nag

Copyright (c) 2016-2021 Stelligent Systems LLC. Licence: MIT, the full text of which is at `test/fixtures/nag/LICENSE.cfn_nag`.

Repository: <https://github.com/stelligent/cfn_nag>. Read at commit `8b5f03da74202ba323a145e9d037ddce6cab9dec`.

| File in this repository | Taken from | Licence | What it is |
|---|---|---|---|
| `test/fixtures/nag/cfn_nag/**` (54 templates, verbatim, paths kept) | `spec/test_templates` | MIT | Fixtures: the security rules are measured against the templates cfn-nag ships |
| `lib/ruby_cdk/nag/rules/policy_statements.rb` | `lib/cfn-nag/base_rules/…` and `cfn-model`'s statement listing | MIT | Rule logic, ported with changes; the file's header names its source |
| `test/support/nag_template.rb` | `cfn-model`'s YAML short-form handling | MIT | Test support: templates written as cfn-model reads them |

### cdklabs/cdk-nag

Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: Apache-2.0, the full text of which is at the end of this file.

Repository: <https://github.com/cdklabs/cdk-nag>. Read at commit `da5bed77c1b08e584e3de2d67534c76871af957f`.

| File in this repository | Ported from | Licence | What it is |
|---|---|---|---|
| `lib/ruby_cdk/nag/rules/**` | the rule packs (` Packs/NagSuppression…`, the pack rules of the same names) | Apache-2.0 | Rule logic, messages and the suppression design, ported with changes; each file's header names its source rule and what changed |
| `lib/ruby_cdk/nag/engine.rb` | `src/nag-pack.ts` | Apache-2.0 | The engine: every rule over every resource, suppressions and acknowledgements |

### stelligent/cfn-model

Copyright (c) 2016-2020 Stelligent Systems LLC. Licence: MIT, as published in that repository's `LICENSE` file. No cfn-model fixture is shipped here; the MIT text at `test/fixtures/nag/LICENSE.cfn_nag` is cfn_nag's, not this project's.

Repository: <https://github.com/stelligent/cfn-model>. Read at commit `3ca846093639c1bfdf2069d33c8050ad66122e6b` (v0.6.6, the version cfn-nag pins).

| File in this repository | Ported from | Licence | What it is |
|---|---|---|---|
| `lib/ruby_cdk/nag/rules/policy_statements.rb` | the resource models' statement listing | MIT | The statement listing and the wildcard-principal test |

## Licence texts

### Apache License, Version 2.0

The licence of the AWS CDK, as published in its repository.

```
                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "[]"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright 2018-2026 Amazon.com, Inc. or its affiliates. All Rights Reserved.

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
```
