# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Four more curated constructs.** `SSM::Parameter` (String and StringList,
  the CDK's grants, SecureString refused with the KMS reason), a
  `SecretsManager::Secret` reference by name (partial ARN as one `Fn::Sub`,
  the `{{resolve:secretsmanager:...}}` value), `Events::Rule` with
  `Schedule` and pattern merging, and `ApiGateway::RestApi` with a Lambda
  proxy (`{proxy+}`, ANY, a prod stage, the CDK's method-set hash on the
  Deployment). Parity now 1,755 cases, 485 ported.

## [0.1.0] - 2026-11-27

### Added

- **Synthesis.** `RubyCdk::App`/`Stack`/`Construct`: Ruby objects synthesize
  byte-identical CloudFormation templates (serialization contract, two-space
  indent, written only when the bytes changed). `Fn` carries the CDK's
  functions (`cfn-fn.ts`), with `AWS::LanguageExtensions` declared
  automatically where AWS requires it. Safe defaults per resource type from
  the CDK's own retained list (`RetainExceptOnCreate`/`Retain`/`Snapshot`).
- **Validation before deploy.** A vendored model of 2,154 AWS resource types,
  rebuilt weekly from the two sources AWS publishes (`rake spec:update`),
  loaded in tens of milliseconds. The normalizer resolves `snake_case` keys
  to CloudFormation's names, and rules V1–V23 find what CloudFormation would
  reject — measured against a corpus of 400 templates the CDK itself
  synthesized, with zero errors and zero unexplained warnings. The commands:
  `validate`, `synth --no-validate`, `--strict-types`.
- **Deployment.** Deploy and destroy through change sets only, with the six
  stack states, the account rule (an `env` deploys and destroys only there;
  an unattended deploy names its account), the skip rule (unchanged template,
  parameters and tags mean nothing to do), events streamed as they happen,
  outputs, termination protection, `--no-rollback` refused on a replacement,
  large templates placed in the asset bucket and deployed by URL, and a
  scripted fake of CloudFormation that runs the whole state machine in tests.
- **Assets.** A directory of files hashed into an identity (relative paths,
  modes, content hashes; nothing time- or machine-derived), zipped
  deterministically at deploy, uploaded to
  `ruby-cdk-assets-<account>-<region>` with the bucket's expected owner
  named on every call. The bootstrap stack with its pre-flight, and
  `ruby-cdk bootstrap`.
- **Security rules.** `rake nag`: seventeen rules over a template as a plain
  Hash (open security groups, wildcard principals, secrets in the
  environment, unencrypted storage, retired runtimes), suppressions from
  resource metadata or `.ruby-cdk/nag.yml`, measured against cfn-nag's own
  fixture templates.
- **The test kit.** `RubyCdk::Test`, the equivalent of the CDK's assertions:
  the ten matchers, `Capture`, and `Template` with its queries, so
  infrastructure tests read like CDK tests.
- **Curated constructs.** `S3::Bucket`, `IAM::Role`, `Lambda::Function`,
  `DynamoDB::Table`, `SQS::Queue`, `SNS::Topic`, `Logs::LogGroup`, with the
  Grant shape and `PolicyStatement`: the CDK's action sets, granted to
  identities only, with an app example that deploys for real.
- **The diff.** `ruby-cdk diff`: the deployed template against the synthesized
  one, normalized copies compared deep-equal, replacements priced from the
  vendored model, replacement propagated through `Ref`/`Fn::` references, and
  a security view that walks every policy-document property in every
  resource. It writes nothing to the account.
- **The command line.** `synth`, `ls`, `deploy`, `destroy`, `validate`,
  `bootstrap`, `version` — with the CDK's stack-selection rules, approval
  questions that refuse when no terminal can answer, an exit code per
  failure class, `--json`, `--help` on every command, and an examples
  directory (`hello`, `lambda`, `app`).
- **CI.** Every gate check as its own parallel job; determinism (every
  example, cross-seed); the parity scoreboard against 1,551 cases of the
  CDK's own tests (445 ported, all passing, the rest listed with their
  reason); a deploy-and-destroy run against the AWS Emulator in a container;
  weekly refreshes of the CDK corpus and the AWS schema sources, opening
  pull requests when they move.

### Changed

- The logical-ID rules of the CDK applied where the developer meets them:
  letters and digits, refused where an element is declared. A description
  over 512 characters and a cycle between stacks are refused the same way.

## [0.0.1] - 2026-11-23

### Added

- Gem skeleton and a CLI with `ruby-cdk version`.
- Rakefile gates: tests that run with no AWS credential reachable, a coverage
  floor, style, types, and a purity check that fails on Node usage or on a
  subprocess call in the shipped code.
- A CI workflow that runs every check as its own parallel job, plus a clean
  install in an image with no build tools.

[Unreleased]: https://github.com/a-safe-digital/ruby-cdk
[0.0.1]: https://github.com/a-safe-digital/ruby-cdk/releases/tag/v0.0.1
