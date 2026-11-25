# ruby-cdk

Infrastructure as code in **pure Ruby**, in the style of the AWS CDK: define stacks as Ruby objects, synthesize deterministic CloudFormation templates validated against the schemas AWS publishes, and deploy them through change sets with the AWS SDK for Ruby. No Node.js, no jsii, no npm anywhere in the toolchain.

> **Status: 0.0.1, pre-release.** Nothing is published to [rubygems.org](https://rubygems.org) yet — install from source. The API is still settling; see [Status](#status).

## What it is

The AWS CDK's programming model, reimplemented in Ruby. Your app file creates one `RubyCdk::App`; stacks are classes with a `build` method that declares resources, parameters and outputs; synthesis turns the object tree into CloudFormation templates whose every byte is specified, and the `ruby-cdk` CLI deploys them through change sets. Properties are written with CloudFormation's names, or in `snake_case` — the keys are normalized against AWS's own resource schemas before anything is written.

"Measured against the CDK" is a number, not a claim. The CDK's own test suites are ported and run in the default gate (`rake parity`): 675 cases across thirteen of its test files, 343 of them ported, every ported case passing, and each of the other 332 listed in a ported file's header with the reason it is not ported. The whole suite — 1,706 runs, 23,544 assertions — passes with no AWS credential reachable; the same gate keeps line coverage at 99% over a floor of 85%, and proves that every example synthesizes byte-identical output across two runs with different Ruby hash seeds.

## Install

From source. There is no gem on rubygems.org yet.

```sh
git clone https://github.com/a-safe-digital/ruby-cdk.git
cd ruby-cdk
bundle install
bundle exec rake install:local   # builds the gem and installs it into your gems
```

    $ ruby-cdk version
    0.0.1

The gem ships no native code, so no compiler is needed.

## Quickstart

With the gem installed (above), `ruby-cdk new` scaffolds the smallest useful app — one stack, one S3 bucket that stays private, a parameter, and the three commands in its README:

```sh
ruby-cdk new my-app
cd my-app
bundle install --local    # ruby-cdk is not on rubygems.org yet: this resolves the
                          # Gemfile from the gem installed on this machine, nothing more
```

The directory holds the app file, `cdk.rb` — one `RubyCdk::App`, one stack:

```ruby
require "ruby-cdk"
require_relative "my_app/my_app_stack"

RubyCdk::App.new do |app|
  MyApp::Stack.new(app, "my-app")
end
```

and the stack, `my_app/my_app_stack.rb`, declares what the template holds — a parameter for versioning, and a bucket with public access blocked on all four settings and AES256 encryption:

```ruby
module MyApp
  class Stack < RubyCdk::Stack
    def build
      versioning = parameter("Versioning", type: "String", default: "Suspended", allowed_values: [ "Suspended", "Enabled" ],
        description: "Whether the bucket keeps every version of an object")

      resource("Bucket", "AWS::S3::Bucket", properties: {
        "BucketEncryption" => {
          "ServerSideEncryptionConfiguration" => [
            { "ServerSideEncryptionByDefault" => { "SSEAlgorithm" => "AES256" } }
          ]
        },
        "PublicAccessBlockConfiguration" => {
          "BlockPublicAcls" => true,
          "BlockPublicPolicy" => true,
          "IgnorePublicAcls" => true,
          "RestrictPublicBuckets" => true
        },
        "VersioningConfiguration" => { "Status" => Fn.ref(versioning) }
      })
    end
  end
end
```

Synthesize it:

```sh
bundle exec ruby-cdk synth
```

This validates the tree, writes `cdk.out/my-app.template.json` and `cdk.out/manifest.json`, and prints the template, with a `Synthesis time: …` line on standard error first:

```json
{
  "AWSTemplateFormatVersion": "2010-09-09",
  "Parameters": {
    "Versioning": {
      "Type": "String",
      "Default": "Suspended",
      "Description": "Whether the bucket keeps every version of an object",
      "AllowedValues": [
        "Suspended",
        "Enabled"
      ]
    }
  },
  "Resources": {
    "Bucket": {
      "Type": "AWS::S3::Bucket",
      "DeletionPolicy": "RetainExceptOnCreate",
      "UpdateReplacePolicy": "Retain",
      "Properties": {
        "BucketEncryption": {
          "ServerSideEncryptionConfiguration": [
            {
              "ServerSideEncryptionByDefault": {
                "SSEAlgorithm": "AES256"
              }
            }
          ]
        },
        "PublicAccessBlockConfiguration": {
          "BlockPublicAcls": true,
          "BlockPublicPolicy": true,
          "IgnorePublicAcls": true,
          "RestrictPublicBuckets": true
        },
        "VersioningConfiguration": {
          "Status": {
            "Ref": "Versioning"
          }
        }
      }
    }
  }
}
```

`ruby-cdk validate` runs the same rules without writing anything (its section is below), so a template CloudFormation would reject is caught here, before any deploy.

Deploy it:

```sh
bundle exec ruby-cdk deploy
```

The command prints the target — account, region, profile — before the first request, creates the change set, prints every change in it and the IAM capabilities it would add, and then asks, in a terminal:

    Deploy these changes to stack my-app in account 123456789012 (eu-central-1)?

Yes executes the change set and follows the operation, printing each event as it arrives and the outputs at the end. Anything else stops: the change set is deleted, and a not-yet-created stack is deleted with it, so a refused deploy leaves nothing behind. A stack without an `env` deploys wherever your credentials point, after the command prints the target. Useful options:

- `--yes` — deploy without asking. Without a terminal the command stops at the question anyway (exit 4, nothing deployed), so unattended runs must say `--yes`.
- `--parameters K=V,K=V` and `--tags K=V,K=V` — template parameters and stack tags.
- `--outputs-file PATH` — the outputs of each stack as JSON.
- `--no-execute` — create the change set and leave it for the console.
- `--on-failure DELETE|ROLLBACK|DO_NOTHING` — what CloudFormation does when a first deploy fails (default `DELETE`, so a failed creation cleans up after itself).
- `--force` — deploy even when the deployed template, parameters and tags are unchanged (unchanged means the deploy is skipped).
- `--all`, `-e/--exclusively` — every stack of the app in dependency order, or only the ones named.

`bundle exec ruby-cdk destroy` prints what the stack retains, then asks you to type the stack's name — a yes/no is not enough for an irreversible act — and deletes it. `--yes` skips the question; a termination-protected stack is refused.

`examples/hello` is this same app kept by hand, with more commentary on what each line does, and the generated project's README carries the three commands with the notes a first deploy needs: where a stack without an `env` deploys, what deploy asks, and that an asset (`asset.zip`) needs a pinned env, because the bucket its zip lands in is named after the account and the region and synthesis never calls AWS to discover them.

## Validation before deploy

Mistakes are caught while synthesizing, not by CloudFormation after. The normalizer resolves every key against the model AWS publishes, so both spellings work:

```ruby
resource("Queue", "AWS::SQS::Queue", properties: {
  queue_name: "todo",          # -> "QueueName"
  visibility_timeout: 300      # -> "VisibilityTimeout"
})
```

A key that matches nothing is an error with the closest names as suggestions — `visibilty_timeout` answers *"did you mean VisibilityTimeout?"* — and an ambiguous one lists every candidate. On top of the normalizer run rules V1–V23: unknown types and logical IDs (V1–V2), property names, required properties and literal kinds (V3–V7), intrinsics — `Ref`, `GetAtt`, `Sub` — checked against the stack (V8–V11), quotas and stack names (V12–V13), circular dependencies (V14), a warning on a stateful type deleted outright (V15), deletion and replacement policies (V16), strings standing where numbers or booleans belong (V17), allowed values and patterns (V18–V19), and the malformed templates CloudFormation itself refuses (V20–V23). The rules pass over a committed sample of 400 templates the CDK has synthesized — real templates CloudFormation accepted — with no exception on file.

`ruby-cdk validate` runs the same rules without writing anything:

    $ ruby-cdk validate
    typo
      V3 Resources.Queue.Properties.visibilty_timeout: "visibilty_timeout" is not a property of AWS::SQS::Queue; did you mean VisibilityTimeout?
        write the CloudFormation name, or in snake_case: visibility_timeout
    typo: 1 error(s), 0 warning(s)

Exit 0 when every selected stack is clean of errors, 2 otherwise; warnings are reported but not fatal. An unknown resource type (V1) is a warning that leaves the resource's keys as written, so `Custom::*` and registry types work.

`--strict-types` re-registers the rules so that V1 reports an error instead of a warning. It does not work in this release: `ruby-cdk validate --strict-types` fails before synthesis with `NameError: uninitialized constant RubyCdk::Validation`. It is listed here because the option exists; use it only to see the failure, not to gate anything.

## Assets

`examples/lambda` shows a file asset: a directory walked, hashed and zipped at deploy, in the shape of the CDK's file-asset scenario. The function's `Code` is the asset's S3 location:

```ruby
function = resource("Function", "AWS::Lambda::Function", depends_on: [ log_group ], properties: {
  "Code" => asset.zip(__dir__.to_s, exclude: [ "stack.rb" ]).s3_location,
  ...
})
```

Synthesizing that example puts, in the template:

```json
"Code": {
  "S3Bucket": "ruby-cdk-assets-111122223333-eu-central-1",
  "S3Key": "3479630be1c6bd65929a6623ef407d0b1af8364fd29e2e93801094d0f6db1207.zip"
}
```

The key is the asset's hash, and the hash is the SHA-256 of a manifest — one `<mode> <relative path> <content hash>` line per file, sorted by path, with only `0644` and `0755` as modes and no timestamps. The same files give the same hash on every machine, and one byte of one file gives a new one: editing the example's `app.rb` by a single character moves the key from `3479630b…07.zip` to `a735bc12…64.zip`, and the next deploy uploads the new object and points `Code` at it. `exclude:` takes plain globs; `.git`, `.DS_Store` and `*.log` are excluded by default. An asset needs a concrete `env` — the bucket's name is made of the account and the region, and synthesis never calls AWS to discover them — and belongs to the stack that declared it.

The bucket comes from `ruby-cdk bootstrap`, which deploys a stack named `ruby-cdk-bootstrap` holding `ruby-cdk-assets-<account>-<region>`: versioning, encryption at rest, public access blocked, a deny-without-TLS bucket policy, read granted to the principal named with `--deployer ARN` (the caller's own by default), and the bucket retained when the stack is deleted. A stack without assets deploys into an account that was never bootstrapped. Templates above 51,200 bytes go into the same bucket and deploy by URL.

## Testing your infrastructure

`RubyCdk::Test` is the CDK's assertions module, ported: the same method names, snake_cased. A stack's template in a plain Minitest:

```ruby
# test/hello_stack_test.rb
require "minitest/autorun"
require "ruby-cdk"
require "ruby_cdk/test"

require_relative "../hello/stack"

class HelloStackTest < Minitest::Test
  def test_the_bucket_stays_private_and_is_encrypted
    stack = Hello::Stack.new(RubyCdk::App.new, "hello")
    template = RubyCdk::Test.template(stack)

    template.resource_count_is("AWS::S3::Bucket", 1)
    template.has_resource_properties("AWS::S3::Bucket", {
      "BucketEncryption" => {
        "ServerSideEncryptionConfiguration" => [
          { "ServerSideEncryptionByDefault" => RubyCdk::Test.object_like("SSEAlgorithm" => "AES256") }
        ]
      },
      "PublicAccessBlockConfiguration" => RubyCdk::Test.object_equals(
        "BlockPublicAcls" => true,
        "BlockPublicPolicy" => true,
        "IgnorePublicAcls" => true,
        "RestrictPublicBuckets" => true
      )
    })
    template.has_resource("AWS::S3::Bucket",
      "DeletionPolicy" => "RetainExceptOnCreate",
      "UpdateReplacePolicy" => "Retain")
    template.has_parameter("Versioning", "Type" => "String", "Default" => "Suspended")
    template.has_output("BucketName", "Value" => RubyCdk::Test.any_value)
    template.template_matches("Parameters" => RubyCdk::Test.any_value)
    assert_equal "RetainExceptOnCreate",
      template.get("Resources.Bucket.DeletionPolicy").as_string
  end
end
```

That test runs:

    1 runs, 1 assertions, 0 failures, 0 errors, 0 skips

`template(source)` takes a stack (anything with `to_template`), a Hash, or a JSON string; `from_string` and `from_json` are there too. The assert methods — `resource_count_is`, `has_resource_properties`, `has_resource`, `all_resources`, `template_matches`, `has_parameter`, `has_output`, `has_condition`, `has_mapping`, and the `find_*` pair for each — raise `RubyCdk::Test::AssertionError` when they fail, which is a `Minitest::Assertion` in a Minitest run (require `minitest/autorun` before `ruby_cdk/test`). The matchers are the CDK's: `object_like`, `object_equals`, `array_with`, `array_equals`, `exact`, `not_`, `any_value`, `absent`, `string_like_regexp`, `serialized_json`. `template.get(path)` reads one value at a dotted path through the typed captures (`as_string`, `as_number`, `as_array`, and the rest), which the CDK's module does not have and a Ruby test with no jest snapshots wants.

## Security defaults

- **Change sets only.** There is no `update_stack` path: a deploy is a change set you are shown before it executes (`lib/ruby_cdk/deploy/deployer.rb`). A failed first deploy passes `OnStackFailure: DELETE`, and a refused creation deletes the stack it created, so nothing half-made is left behind.
- **Stateful types are retained, not deleted.** The types the CDK retains — S3 buckets, DynamoDB tables, log groups, KMS keys, and the rest of its list — get `DeletionPolicy: RetainExceptOnCreate` and `UpdateReplacePolicy: Retain` from the first synth; RDS instances and clusters get `Snapshot`. `RetainExceptOnCreate` rather than `Retain`, so a creation that rolls back leaves no orphan behind; every change set also executes with `RetainExceptOnCreate: true`, which protects plain-`Retain` templates too (`lib/ruby_cdk/core/stateful.rb`).
- **The account rule.** A stack with an `env` deploys and is destroyed only into that account — the command resolves who it is with STS and refuses on a mismatch. A stack without one goes wherever the credentials point, with the target printed first; an unattended deploy (`--yes`) of such a stack refuses without `--account ID` naming it (`lib/ruby_cdk/deploy/deployer.rb`).
- **The asset bucket's owner is checked on every call.** `HeadBucket`, `HeadObject` and `PutObject` all carry `expected_bucket_owner`; a bucket that exists and is not yours stops the deploy before anything is uploaded (`lib/ruby_cdk/assets/uploader.rb`).
- **Nothing executes without approval.** The change view is printed, then the question; `--yes` must be exactly `true`; without a terminal the command refuses at the question and leaves nothing deployed. `destroy` asks for the stack's name to be typed, not for a yes (`lib/ruby_cdk/deploy/ports.rb`).

## Requirements

- Ruby 4.0 or newer. The gemspec refuses older (`required_ruby_version ">= 4.0.0"`).
- AWS credentials reachable through the SDK's standard chain — environment, shared files, SSO — narrowed by `--profile`. Nothing is stored, nothing is logged, and synthesis never calls AWS.
- The four runtime gems (`aws-sdk-cloudformation`, `aws-sdk-s3`, `thor`, `rubyzip`) install with the gem. No Node, no build tools, no native extensions.

## Status

Works today:

- `ruby-cdk synth`, `validate`, `ls`, `deploy`, `destroy`, `new`, `bootstrap` (`ruby-cdk help COMMAND` for each). `new PROJECT` scaffolds an app: `cdk.rb`, one stack with one private bucket, a Gemfile, `.gitattributes` and `.gitignore`.
- Schema-backed synthesis with the normalizer and rules V1–V23.
- File assets with content hashing, zipping at deploy, and the bootstrap bucket; templates above 51,200 bytes deploy by URL.
- The nag rule pack — seventeen security rules over every template of `cdk.out`, run with `rake nag`, suppressed per resource or in `.ruby-cdk/nag.yml`.
- The test kit, `RubyCdk::Test`, with the CDK's assertions ported.
- Deploy and destroy run end to end in CI against an emulator that speaks CloudFormation's real API (`rake integration`).

Next: `ruby-cdk diff` and curated L2 constructs — everything in the examples today is an L1 resource written with CloudFormation's own property names. After that, context providers (lookups of existing resources) and hotswap.

And the honest part: this is 0.0.1. The APIs — `Stack`, `App`, `Test`, the CLI options — may still change between versions, the `--strict-types` defect above is real, and nothing is published to rubygems.org. Pin the commit you build from.

## Development

```sh
git clone https://github.com/a-safe-digital/ruby-cdk.git
cd ruby-cdk
bundle install
bundle exec rake        # everything that must pass before a commit
```

The default gate is an explicit list: `test`, `rubocop`, `typecheck` (Sorbet), `coverage:check` (floor 85%), `determinism`, `purity`, `parity`. It never touches the network and never calls AWS. `rake -T` lists the rest — `rake nag`, `rake mutation`, and the network tasks `spec:update` and `corpus:update`, which CI runs weekly and everyone else runs by hand, on purpose.

The tests: `test/unit/` for each component alone, `test/cdk/` for the CDK's suites ported (every file's header names the origin path, commit and licence), `test/architecture/` for the component map — the set of components and their dependencies, enforced by a test so no shortcut crosses a boundary — and `test/integration/`, of which only the in-process part runs in the gate. The design documents under `docs/` are not part of a fresh clone: the owner keeps them local (decision D-025), so the code comments and this README are the public record.

Rules for contributors and for coding agents are in [CLAUDE.md](CLAUDE.md).

## License

[MIT](LICENSE)
