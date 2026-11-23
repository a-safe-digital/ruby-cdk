# ruby-cdk

Infrastructure as code in **pure Ruby**, in the style of the AWS CDK: compose stacks from Ruby objects, synthesize deterministic CloudFormation templates, and deploy them through the AWS SDK for Ruby. No Node.js, no jsii, no npm anywhere in the toolchain.

> **Status: pre-release, under construction.** Nothing is published to RubyGems yet. The gem, its tests and its CI are being built in the open; see [CHANGELOG.md](CHANGELOG.md) for what exists so far.

## Requirements

- Ruby 4.0 or newer.

## What it sets out to do

- Define infrastructure in idiomatic Ruby: `snake_case` keywords, blocks, plain objects.
- Catch mistakes before AWS does, validating every template at synth against the schemas AWS publishes.
- Synthesize byte-identical templates on every machine, with the bytes specified in writing.
- Deploy through change sets, showing the target account and every change before anything executes.
- Behave like the AWS CDK, and prove it with the CDK's own tests.

## Development

```sh
git clone https://github.com/a-safe-digital/ruby-cdk.git
cd ruby-cdk
bundle install
bundle exec rake        # everything that must pass before a commit
```

`rake -T` lists the individual checks. Rules for contributors and for coding agents are in [CLAUDE.md](CLAUDE.md).

## License

[MIT](LICENSE)
