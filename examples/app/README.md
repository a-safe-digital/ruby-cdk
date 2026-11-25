# app

A function, a table, a bucket and one least-privilege role for them all —
the four resources every small project needs, built with the curated
constructs (`RubyCdk::S3::Bucket`, `RubyCdk::DynamoDB::Table`,
`RubyCdk::IAM::Role`, `RubyCdk::Lambda::Function`) and their grants. This is
Wave 7's own scenario (`docs/07-testing.md` §9), after the CDK's integ
scenarios `aws-iam/test/integ.role.ts` and `aws-lambda/test/integ.lambda.ts`
(`aws-cdk` at `c070afb54b9e4dbddd52a85a21077fe970354985`, Apache-2.0). Where
the CDK says `lambda.Code.fromAsset(path.join(__dirname, ...))`, the same
scenario is `asset.zip(__dir__.to_s, exclude: ["stack.rb"])` — a directory
walked, hashed and zipped at deploy, no build step and nothing to vendor.

The point of this app is the grants. The role is least-privilege in three
lines:

```ruby
table.grant_read_write_data(role)
bucket.grant_read_write(role)
```

and the statements those two lines write are all the data permissions the
role has — no service-wide actions, no `*` resources. The role carries the
`AWSLambdaBasicExecutionRole` managed policy, which is what gives the
function its CloudWatch Logs permissions, exactly what the CDK's default
`ServiceRole` carries.

## The three commands

```sh
ruby-cdk synth     # writes cdk.out/app.template.json and cdk.out/manifest.json,
                   # and prints the template
ruby-cdk deploy    # uploads the asset, shows the change set, asks, then deploys it
ruby-cdk destroy   # asks for the stack name, then deletes the stack
```

Run them from this directory: the app file is `cdk.rb`. The app pins an env —
account `111122223333`, region `eu-central-1` — because an asset needs a
concrete one: the name of its bucket is made of the account and the region,
and synthesis never calls AWS to discover them. **Replace both in `cdk.rb`
with your own before deploying**: a stack with an `env` deploys only into
that account and region.

For a deploy that does not stop to ask, add `--yes`.

## What the stack is

`app/stack.rb` is a `RubyCdk::Stack` subclass whose `build` declares:

- one `RubyCdk::IAM::Role` trusted by `lambda.amazonaws.com`, carrying the
  basic-execution managed policy, named `unique_name("notes-role")`;
- one `RubyCdk::DynamoDB::Table` with a string partition key, on-demand
  billing and point-in-time recovery on — the constructs' safe defaults —
  named `unique_name("notes")`;
- one `RubyCdk::S3::Bucket` with versioning on, public access blocked on all
  four settings and SSE-S3 encryption written out — again the defaults;
- one `RubyCdk::Lambda::Function` whose code is the asset, running
  `ruby3.4`, with the log group `/aws/lambda/<function name>` the function
  construct makes (kept 731 days), and the role passed in above;
- the two grants, and outputs for the function's name and ARN and the
  table's and bucket's names.

The names come from `stack.unique_name`: stable across deploys, made of the
stack's env, so the log group always agrees with the function.

**The runtime.** The vendored resource specification puts no enum on
`Runtime`, so the identifier is not checked at synthesis. `ruby3.4` is the
runtime the constructs pin (dated in
`lib/ruby_cdk/constructs/function.rb`); when AWS retires it, pass
`runtime:` with the current identifier.

## What the grants write

`table.grant_read_write_data(role)` writes one statement on the role's
default policy: the twelve DynamoDB data actions (reads, writes,
`DescribeTable`) on the table's ARN. `bucket.grant_read_write(role)` writes
one statement: the three read actions and the delete and put actions on the
bucket's ARN and on `arn:...:/*` for its objects. Both are the CDK's own
action lists, from `aws-dynamodb/lib/table-grants.ts` and
`aws-s3/lib/bucket-grants.ts` at the pinned commit. `ruby-cdk synth` prints
them; they are also pinned by the ported tests in `test/cdk/constructs/`.

## Files

```
cdk.rb          the app file: requires the gem, creates exactly one RubyCdk::App
app/stack.rb    the stack
app/app.rb      the code of the function: the file the asset zips
```
