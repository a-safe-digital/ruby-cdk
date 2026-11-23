# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Gem skeleton and a CLI with `ruby-cdk version`.
- Rakefile gates: tests that run with no AWS credential reachable, a coverage
  floor, style, types, and a purity check that fails on Node usage or on a
  subprocess call in the shipped code.
- A CI workflow that runs every check as its own parallel job, plus a clean
  install in an image with no build tools.
