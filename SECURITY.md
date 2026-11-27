# Security policy

## Supported versions

ruby-cdk is 0.1.0, pre-release. Nothing is published to rubygems.org; install from source and pin the commit you build from. Only the latest commit on `main` receives security fixes.

## Reporting a vulnerability

Report it privately through GitHub's vulnerability reporting for [a-safe-digital/ruby-cdk](https://github.com/a-safe-digital/ruby-cdk): the repository's **Security** tab, then **Report a vulnerability**. This opens a private advisory between you and the maintainers.

Do not open a public issue. Do not describe an unpatched vulnerability in a pull request.

Include:

- the commit you built from, and the commands you ran;
- what you did and what you expected, with a reproduction: an app file, a template, a command line;
- your assessment of the impact, and which account or data you believe is at risk;
- whether you want credit, and under which name.

## Scope

In scope:

- The tool as shipped: synthesis, validation, the deploy engine, assets and bootstrap, the command line (`lib/`, `exe/`).
- Its four runtime dependencies and their pinned transitive list (`aws-sdk-cloudformation`, `aws-sdk-s3`, `thor`, `rubyzip`).
- Anything in this repository's CI that touches the network or executes code.

Out of scope:

- A malicious or careless app file. The app file is Ruby and runs with the operator's permissions by design; see [docs/security.md](docs/security.md), "The trust model".
- Weaknesses in AWS services, in CloudFormation, or in the AWS SDK for Ruby that do not involve ruby-cdk's own code.
- An operator deploying with credentials they did not mean to use, where the tool followed its documented behaviour.
- The output of an automated scanner without a reproduction. The findings already triaged and accepted as design decisions are described in [docs/security.md](docs/security.md), "Accepted findings".

## What to expect

- Acknowledgement within five business days.
- An assessment, and a fix on `main` when the finding is accepted.
- Coordinated disclosure: the advisory stays private until a fix is on `main`. Credit in the advisory's closing note if you want it.
