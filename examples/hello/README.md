# hello

The smallest useful app: one stack, `hello`, with one S3 bucket that stays
private — public access blocked on all four settings and encrypted at rest.
A parameter decides whether the bucket keeps every version of an object, and
an output gives its name, so one deploy exercises both.

The point of this app is the three commands. Nothing here is needed beyond
Ruby and the gem.

## The three commands

```sh
ruby-cdk synth     # writes cdk.out/hello.template.json and cdk.out/manifest.json,
                   # and prints the template
ruby-cdk deploy    # shows the change set, asks, then deploys it
ruby-cdk destroy   # asks for the stack name, then deletes the stack
```

Run them from this directory: the app file is `cdk.rb`, and a stack without an
`env` deploys wherever your credentials point, after the command prints the
target. For a deploy that does not stop to ask, add `--yes`:

```sh
ruby-cdk deploy --yes
```

## What the stack is

`hello/stack.rb` is a `RubyCdk::Stack` subclass. Its `build` declares:

- a parameter `Versioning` — `Suspended` by default, `Enabled` or `Suspended`;
- one `AWS::S3::Bucket` with `PublicAccessBlockConfiguration` on all four
  settings, AES256 encryption, and `VersioningConfiguration` from the parameter;
- an output `BucketName` with the bucket's name.

The bucket keeps the retention default for S3 (`DeletionPolicy:
RetainExceptOnCreate`), so `destroy` deletes the stack and CloudFormation
deletes the bucket with it — a failed first deploy, though, leaves nothing
behind either.

## Files

```
cdk.rb          the app file: requires the gem, creates exactly one RubyCdk::App
hello/stack.rb  the stack
```
