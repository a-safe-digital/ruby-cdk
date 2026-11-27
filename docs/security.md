# Security

The threat model and the security properties of the tool itself. The reporting policy is [SECURITY.md](../SECURITY.md) at the repository root; the README's "Security defaults" states the user-facing behaviour. This document says what the code does, with the file that does it.

## The trust model

**What ruby-cdk trusts:**

- **The operator.** The tool acts on an AWS account with the credentials the operator gives it, through a command the operator runs.
- **The app file.** It is Ruby, and it executes: `App.build!` loads the file named by `--app` with `load(path)` (`lib/ruby_cdk/core/app.rb`, the one load in the gem that is not a literal `require`). The tree it builds is what the template holds. This is the nature of the DSL, and the AWS CDK CLI sits in the same position.

**What ruby-cdk refuses, in its own code:**

- **Synthesis is deterministic and side-effect-free.** Nothing time-, randomness- or machine-derived enters a template, and synthesis never calls AWS. The `determinism` gate synthesizes every example twice with different Ruby hash seeds and compares the bytes; the templates carry no timestamp, the manifest carries what varies. The `purity` gate (`tools/purity_check.rb`) parses every shipped file with Prism and fails on a backtick, on any call that starts a process (`system`, `exec`, `spawn`, `popen`, Open3's capture family) and on any literal naming the JavaScript toolchain. Both gates run in the default `rake` and in CI.
- **The components stay sealed.** `test/architecture/component_boundaries_test.rb` enforces the map statically: literal `require`s only, code handed to `eval` and its kind only as a block and never as a string, the AWS SDK reachable only from the two adapters, the synthesis path (`require "ruby-cdk"`) free of the deploy engine.

## Credentials

- Credentials come from the AWS SDK's standard chain, narrowed by `--profile`. The tool stores nothing and writes nothing about them; `synth` loads no AWS SDK at all.
- The deploy engine prints SDK error messages verbatim. An error is diagnostic; rewriting it can hide the cause. The SDK redacts the secret access key and the session token in `#inspect`, and an access key id that appears in a message is an identifier, not a secret — AWS states that account IDs are "not considered secret, sensitive, or confidential information", and the tool treats the same distinction where it prints targets and evidence (decision D-027).
- `test/unit/deploy/credentials_test.rb` pins the promise: a real `Aws::Credentials` object in scope, an injected failure, and the captured output must carry the SDK's message and must not carry the secret, the session token, or the access key id.
- Tests cannot reach the chain even by mistake. `rake test` scrubs the environment before the suite (`Tools::AwsIsolation.scrub!`, `tools/aws_isolation.rb`): every `AWS_*` and `RUBY_CDK_*` variable removed, `AWS_CONFIG_FILE` and `AWS_SHARED_CREDENTIALS_FILE` pointed at `/dev/null`, `AWS_EC2_METADATA_DISABLED` set. `rake integration` is the only task that runs with the real environment, under the WF-5 protocol: the owner sets a profile, an allowed account and an allowed region in the shell, and the helper resolves the identity and aborts before creating anything unless both match.

## The deployment surface

- **Change sets only.** There is no `update_stack` path (`lib/ruby_cdk/deploy/deployer.rb`). Every mutation of a stack is a change set that was created, printed and approved in the same process.
- **Approval gates and non-interactive refusal.** The change view and the IAM capabilities are printed, then the question. An approval is exactly `true`. Without a terminal, deploy refuses at the question and leaves nothing deployed: the change set is deleted, and a stack the set had created is deleted with it. `destroy` prints what the stack retains and asks for the stack's name to be typed — a yes/no is not enough for an irreversible act (`lib/ruby_cdk/deploy/ports.rb`, `lib/ruby_cdk/deploy/deployer.rb`).
- **The account rule.** The engine resolves the caller with `sts.get_caller_identity` before the first request and prints the target: account, region, profile. A stack with an `env` deploys and is destroyed only there; on a mismatch the command refuses with `TargetMismatch`. An unattended deploy (`--yes`) of a stack without an `env` refuses without `--account` naming the account (`AccountRequired`) (`check_account`, `lib/ruby_cdk/deploy/deployer.rb`).
- **Safe deletion defaults.** The stateful types — S3 buckets, DynamoDB tables, log groups, KMS keys and the rest of the CDK's retained list — carry `DeletionPolicy: RetainExceptOnCreate` and `UpdateReplacePolicy: Retain` from the first synth; RDS instances and clusters carry `Snapshot` (`lib/ruby_cdk/core/stateful.rb`). Every change set executes with `RetainExceptOnCreate: true`, so even a plain-`Retain` template loses nothing when its own creation rolls back.
- **The tool never deletes a physical resource by hand.** Deletion happens only through CloudFormation: a `destroy`, or CloudFormation's own cleanup of a failed creation (`OnStackFailure: DELETE`). The integration sweeper reports leftovers; it does not delete services' objects.

## Assets and S3

- **The bucket's owner is checked on every call.** `HeadBucket`, `HeadObject` and `PutObject` all carry `expected_bucket_owner` (`lib/ruby_cdk/assets/uploader.rb` through the `ObjectStore` port). A bucket that exists and is not the deployer's stops the deploy before anything is uploaded. This closes the simplest attack on a bucket whose name is a function of public facts: registering `ruby-cdk-assets-<account>-<region>` first and receiving the uploads. A name claimed after the bucket's deletion is refused the same way; the README warns about that window.
- **Uploads are put-if-absent into content-addressed keys.** `put_object_unless_present` heads the key and skips when it exists, else puts (`lib/ruby_cdk/assets/uploader.rb`). Asset keys are `<sha256>.zip` at the bucket root; templates above 51,200 bytes go to `templates/<stack name>/<sha256>.json` and deploy by `TemplateURL`. An object already there is never re-read or trusted: its key is its content's hash, so a matching key is the same bytes.
- **Permissions implications.** The bootstrap bucket denies requests without TLS, blocks public access on all four settings, encrypts at rest with SSE-S3, and grants read on objects to the deployer principal named at bootstrap with `--deployer ARN` — the caller's own by default (`lib/ruby_cdk/bootstrap.rb`). CloudFormation reads a `TemplateURL` with the caller's permissions, which is why the read grant names the deployer and not a service principal. The bucket is retained when the bootstrap stack is deleted, because CloudFormation cannot delete a bucket that still holds objects.
- **The asset walk refuses what an asset should not silently contain:** a symbolic link, anything that is not a regular file, a name with a line break (it would split the canonical manifest line), a name with a backslash (readers that take it as a separator would merge two entries into one), and a name that is not valid UTF-8 (`lib/ruby_cdk/assets/hasher.rb`). The tool writes zips; it never reads one.

## Supply chain

- **Four runtime gems:** `aws-sdk-cloudformation`, `aws-sdk-s3`, `thor`, `rubyzip` (`ruby-cdk.gemspec`). Adding one needs the owner's approval and an entry in the dependency list of the design documents. There is no Node.js, no jsii and no npm anywhere in the toolchain; `lib/` spawns no process, which the purity gate proves on a syntax tree rather than by grep.
- **The transitive list is pinned** in `Gemfile.lock` with SHA-256 checksums. The vendored CloudFormation schema model (`data/spec/`) is pinned by the SHA-256 recorded in `META.json`, is built only by `rake spec:update`, and nobody hand-edits it.
- **Weekly jobs:** `bundler-audit` against the lockfile, and the schema refresh, which fails on a 404 or on ninety days without a change from AWS (`.github/workflows/audit.yml`).
- **CI has no cloud credentials.** The workflows declare `permissions: contents: read` and define no AWS secrets. The deploy-and-destroy job runs against an AWS emulator in a container, endpoint-isolated to `127.0.0.1` with `AWS_ENDPOINT_URL`; the emulator generates its own credentials, and the WF-5 allowlist guard checks them the same way it checks the sandbox's (`.github/workflows/ci.yml`).
- **The clean-install job** builds and installs the gem in an image with no build tools, which holds the promise that no dependency needs a compiler.

## Accepted findings

Four findings from the deep security scans of 2026-11-25 and 2026-11-27 are accepted design decisions or false positives. Each was reproduced as written, triaged, and kept. They are recorded here in full because the architecture document that first recorded them is not part of a fresh clone.

1. **`instance_eval(&block)` in `Stack#initialize`** — reported as code injection (CWE-95). Accepted: the call is the DSL. It passes the block the app file wrote to run in the stack's context, and it never accepts a string — the boundary test fails on `eval`-family calls given code as a string. No privilege boundary is crossed: the app file could call `eval` itself, with exactly the permissions it already has. `grep -n instance_eval lib/` finds the one call site.
2. **`violations_in_repo(ARGV[0])` in `tools/purity_check.rb`** — reported as a path-traversal entry (a command-line argument flowing into a file walk). Accepted: the tool is a local lint run by `rake purity` or by hand, by the developer, on their own checkout, and the argument is where the repository to check lives. There is no service here and no untrusted caller.
3. **`Mutations::ALL.fetch(ARGV.first)` in `tools/mutation_check.rb`** — reported as a tainted fetch reaching a security sink (2026-11-27 scan). Accepted, under the same rule as (2): the argument only *selects a key* from the committed mutation registry, and the key is validated against that registry before the fetch; the registry's entries are committed code, not data. A local tool run by rake on the developer's own checkout.
4. **`File.open(File::NULL, "w")` in `lib/ruby_cdk/schema/validator/structure.rb`** — reported as an unvalidated path (CWE-22). False positive: the path is the literal `/dev/null` constant, used to silence Ruby's warnings while compiling AWS's own regular expressions; no user-derived path is involved.

All fall under the same rule: ruby-cdk's security boundary is the operator. Code that only ever runs with the operator's own authority, on the operator's own files, is not an escalation path, and a report that it might be is triaged as a designed false positive rather than suppressed.

## What ruby-cdk does not protect against

- **A malicious app file can do anything Ruby can.** It runs with the operator's permissions before synthesis starts: read files, reach the network, build any tree it wants. Review an app file as you would review a script you are about to run, because it is one. The tool's guarantees are about its own code — determinism, purity, credential handling, the deploy surface — not about the code it is given.
- **The template is only as safe as the constructs it uses.** Validation (rules V1–V23) checks structure, and the nag rule pack warns on security-relevant patterns; neither refuses a template whose IAM policy grants everything to everyone. The nag rules are advisory: they fail a gate above a threshold and can be suppressed in `.ruby-cdk/nag.yml`. The approval question is where a person reads the change view — the security view lists every policy statement the template carries — and `--yes` skips exactly that reading.
- **What no local rule can validate:** IAM semantics, regional availability, property formats the published schemas do not describe. CloudFormation checks some of it when the change set is created, and the engine prints the failed set's `StatusReason` verbatim.
- **A stack without an `env` deploys wherever the credentials point.** The target is printed first and an unattended deploy must name its account, but the tool cannot know that the credentials themselves are the wrong ones.
- **The machine is trusted.** `cdk.out/`, `manifest.json`, `.ruby-cdk/nag.yml` and the app file are local files read and written without further verification.
