# lambda

One function whose `Code` is a zipped directory of files, in the shape of the
CDK's file-asset integ scenario (`aws-cdk-lib`, `aws-s3-assets/test/
integ.assets.directory.lit.ts` at `a2c633f`, Apache-2.0; the function that
consumes such an asset is `aws-lambda/test/integ.assets.lit.ts` in the same
commit). There the CDK says `code: lambda.Code.fromAsset(path.join(__dir__,
"my-lambda-handler"))`; here the same scenario is `asset.zip(__dir__.to_s,
exclude: ["stack.rb"])` — a directory walked, hashed and zipped at deploy, no
build step and nothing to vendor. The stack also carries the role Lambda
assumes (the `AWSLambdaBasicExecutionRole` managed policy, which is what gives
the function its CloudWatch Logs permissions) and the log group
`/aws/lambda/<function name>`, which the function is made to depend on so that
CloudFormation creates it before the function does.

The point of this app is the three commands. Nothing here is needed beyond
Ruby and the gem.

## The three commands

```sh
ruby-cdk synth     # writes cdk.out/lambda.template.json and cdk.out/manifest.json,
                   # and prints the template
ruby-cdk deploy    # uploads the asset, shows the change set, asks, then deploys it
ruby-cdk destroy   # asks for the stack name, then deletes the stack
```

Run them from this directory: the app file is `cdk.rb`. The app pins an env —
account `111122223333`, region `eu-central-1` — because an asset needs a
concrete one: the name of its bucket is made of the account and the region,
and synthesis never calls AWS to discover them. **Replace both in `cdk.rb`
with your own before deploying**: a stack with an `env` deploys only into that
account and region.

For a deploy that does not stop to ask, add `--yes`:

```sh
ruby-cdk deploy --yes
```

## What the stack is

`lambda/stack.rb` is a `RubyCdk::Stack` subclass. Its `build` declares:

- an `AWS::IAM::Role` trusted by `lambda.amazonaws.com`, with the
  `AWSLambdaBasicExecutionRole` managed policy;
- an `AWS::Logs::LogGroup` named `/aws/lambda/<function name>`, keeping logs
  for 7 days, and the function declared `depends_on:` it, as the CDK orders
  the two when a log group is explicit;
- one `AWS::Lambda::Function` whose `Code` is the `S3Bucket` and `S3Key` of
  the asset — the bucket `ruby-cdk-assets-<account>-<region>`, the key
  `<asset hash>.zip` — with `Handler: app.handler`, and outputs for the
  function's name and ARN.

The function's name comes from `stack.unique_name("function")`: stable across
deploys, made of the stack's env, so the log group's name agrees with it.

**The runtime.** The vendored resource specification puts no enum on
`Runtime`, so the identifier is not checked at synthesis. `ruby3.4` is a
runtime AWS currently supports; when AWS retires it, change the string here
and the validator keeps the rest of the template honest.

## Why a one-byte change is a new asset

The identity of an asset is the SHA-256 of a manifest of its files, one
`<mode> <relative path> <content hash>` line per file, sorted by path. Every
byte of every file is in there: edit `lambda/app.rb` — even one character —
and its content hash changes, so the manifest hash changes, so the object key
changes, and the next deploy uploads a new `<hash>.zip` and points `Code` at
it. What is *not* in there is anything but the bytes: paths of the directory
on your machine, modification times, file order, the owner's non-executable
permission bits. The same files give the same asset on every machine, and the
same files always deploy.

`exclude: ["stack.rb"]` keeps the zip to the code Lambda runs: the stack's own
`stack.rb` declares the asset, it is not part of the package.

## Files

```
cdk.rb          the app file: requires the gem, creates exactly one RubyCdk::App
lambda/stack.rb the stack
lambda/app.rb   the code of the function: the file the asset zips
```
