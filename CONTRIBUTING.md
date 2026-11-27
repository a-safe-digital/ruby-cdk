# Contributing

## Setup

Ruby 4.0 (the project pins the current 4.0 patch release with [mise](https://mise.jdx.dev); `mise.toml` holds the version), then:

```sh
bundle install
bundle exec rake
```

The default `rake` is the gate every change goes through: the test suite, a coverage floor, RuboCop, Sorbet, determinism (every example synthesized twice with different Ruby hash seeds, byte-identical), the parity scoreboard against the AWS CDK's own tests, the nag security rules, and the purity check (no process spawning, no JavaScript toolchain). CI runs the same checks as parallel jobs, plus a deploy-and-destroy against an AWS emulator.

## Running a single test file

```sh
mise x -- bundle exec ruby -Itest test/unit/constructs/bucket_test.rb
```

The suite never reaches AWS: tests use scripted fakes, and anything that needs a real account runs behind an allowlist guard that is off in normal development.

## Ported code

A file ported from the AWS CDK (Apache-2.0) keeps an attribution header naming the original file and the commit it was read at, and ends with a `# Parity:` line accounting for every case of the original: ported, or not, with the reason. `rake parity` enforces the accounting. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Behaviour questions are answered by the CDK's source. When a deliberate difference is made, it is written down next to the code that differs.

## Style

RuboCop is the rule (`rubocop-rails-omakase`); `bundle exec rubocop -a` fixes the mechanical ones. Shipped code is Sorbet-checked at `typed: true`; tests and tools are judged by running.

## Reporting a security issue

Not here. Follow [SECURITY.md](SECURITY.md): private vulnerability reporting on GitHub, never a public issue.
