# ruby-cdk: agent conventions

Pure-Ruby infrastructure as code in the style of the AWS CDK: Ruby objects synthesize deterministic CloudFormation templates and deploy them through the AWS SDK for Ruby. The plan is in `docs/05-plan.md`, the contracts in `docs/03-architecture.md`, the reasons in `docs/04-decisions.md`, what is built at any moment in `docs/08-progress.md`.

## Before writing code

- The planning documents under `docs/` are local and absent from a fresh clone (D-025). On a clone without them the rules in this file still apply in full; ask the owner for the wave card instead of guessing it.
- Read the wave card for the current wave in `docs/05-plan.md`. Implement what the card scopes, nothing more, and edit only the files its `Owns` column gives your task. Good ideas outside the scope go to the backlog section of that document.
- Read the contracts you touch in `docs/03-architecture.md`. They are binding, and Wave 1 starts by proving they compile. If a contract is wrong, change the document in the same wave as the code that needed it and say so.
- Technical questions are not questions for the owner. Decide them by the rule below, record the evidence, and move on. Only the four items in `docs/04-decisions.md` section 2 are the owner's.
- Know which kind of agent you are. A workflow subagent edits only its task's files, never commits and never calls AWS. The lead agent integrates, commits on the wave's branch when the go-ahead says so, and runs integration only after the wave's checkpoint. See `docs/06-workflows.md`, WF-1 and WF-5.

## Rules

- **The AWS CDK is the reference.** This is the CDK, in Ruby. When a question of behaviour has no reason to answer differently, do what the CDK CLI does, and read it in its source (`aws/aws-cdk-cli`, `aws/aws-cdk-lib`) rather than from memory. Every difference is listed in `docs/03-architecture.md` section 21; adding one means adding it there, with the reason.
- **Tests are the CDK's tests.** Port its suites; do not invent equivalents (`docs/07-testing.md`). Every ported file starts with a header naming the origin path, the commit, the licence (Apache-2.0, MIT or MIT-0) and what was changed. A case that is not ported is listed in the file header with its reason. A ported test is never changed to make it pass: that is a finding about this tool, and it goes in the pull request. The header ends with one line, `# Parity: N cases in the origin; P ported; Q not ported.`, which `rake parity` holds the file to: the numbers add up, and P is the number of tests in the file.
- **Components are sealed.** The map is `test/architecture/components.rb` and `test/architecture/component_boundaries_test.rb` enforces it. A component requires only itself and its dependencies, every load is a literal `require`, nothing requires the umbrella, and nothing below the adapters reaches the AWS SDK. Ruby's standard library is free for every component; anything else has to be in the component's row. The one load that is not a literal is the user's app file, in `core/app.rb`; anywhere else, and in any code given to `eval` as a string, it is a violation. A constant belongs to the component whose file defines it, and a component reads only what it or its dependencies define. The tree never names assets, validation or deployment: assets adds `Stack#asset` to the tree, and the pipeline learns the normalizer and the validators only through registration. No component registers itself with a higher one: `lib/ruby_cdk.rb`, the umbrella, is where what joins two components is written. Adding a dependency means changing the map, with a reason, in the same commit; never edit the map to match a shortcut. When the map blocks a sound design, say so with the evidence: the lead decides, in the open.
- **Verify before asserting.** A claim about AWS, the SDK, Ruby or the CDK that a design depends on is checked in a primary source or by running it before it is written down as fact. If it could not be checked, say so next to it.
- **The planning documents are local.** `docs/01-audit.md` to `docs/07-testing.md`, `docs/history/` and `docs/audits/` are never committed or pushed. They are in `.gitignore`. Do not remove them from it, and do not paste them into a commit message or a pull request.
- **English everywhere.** Identifiers, comments, test names, docs, commit messages and PR text. One exception: a workflow script's phase names, prompts and report titles are written in the language of the session that runs it.
- **Style is RuboCop's.** `rubocop-rails-omakase` decides: spaces inside brackets, `[ a, b ]` and `{ key: value }`, and no trailing commas. Run RuboCop on your files and follow it. And never define a method named `hash` that answers anything but an Integer: it replaces `Object#hash`, and the object can no longer be a Hash key or sit in a Set.
- **Pure Ruby.** Nothing this repository writes, ships or invokes uses Node, jsii, npm or npx: no JavaScript or TypeScript source outside `.zcode/workflows/`, no npm dependency, no call to a `node` binary. `lib/` never spawns a process: no `system`, `exec`, `spawn`, `IO.popen`, `Open3` or backticks. `rake purity` enforces both, on a syntax tree. GitHub's own runner actions run on the runner's Node; that is the host's runtime, not ours.
- **AWS is reached only through the AWS SDK for Ruby.** Never shell out to `aws` or `cdk`.
- **AWS access is human-gated.** Do not call any AWS API, and do not deploy, unless the owner approved it for the current wave. Integration runs happen only through `rake integration`, under the three variables of WF-5, and fail closed. Never use another profile, never the default chain by accident.
- **The account, as the CDK handles it.** A stack with an `env` deploys only into that account. A stack without one deploys wherever the credentials point, and the target is printed first. An unattended deploy (`--yes`) of a stack without `env` needs `--account`. Do not loosen the last rule and do not add stricter ones without a recorded reason.
- **Every S3 call names the bucket's expected owner.** A bucket that exists and is not ours stops the operation.
- **Stub credentials in tests.** Any test, fake or tool that only needs a client object passes stub credentials and an explicit region. The default credential chain searches for credentials and probes the EC2 metadata endpoint when it finds none. `rake test` runs with the AWS environment scrubbed; a test that needs it to be present is wrong. The same goes for any probe run by hand: nothing that loads the adapters runs outside the scrub (`Tools::AwsIsolation.scrub!` in `tools/aws_isolation.rb`) or against a path of your own instead of `~/.aws`.
- **No secrets.** Never commit, print or log credentials or session tokens. An account ID is an identifier, not a credential: print it where it helps someone recognise the target.
- **Determinism is a contract, down to the bytes.** Nothing time-, randomness- or machine-derived goes into a template, synthesis never calls AWS, and the serialization contract of `docs/03-architecture.md` §5 decides every byte. Every change to `lib/ruby_cdk/synth`, `core` or `cfn/resource.rb` keeps `rake determinism` green.
- **Safe defaults are a contract.** The resource types the CDK retains default to `RetainExceptOnCreate`, deploys go through change sets, a refused creation deletes the stack it created, and non-interactive deploys require `--yes`. Weakening any of these needs a decision change.
- **Dependencies are a contract.** Adding a runtime dependency requires an entry in the dependency list of `docs/03-architecture.md` and the owner's approval. No Rails, no ActiveSupport, no native extension beyond Ruby's default and bundled gems.
- **Generated data is never hand-edited.** Everything under `data/spec/` comes from `rake spec:update`.
- **Verify before claiming.** Run the wave's gate and report what actually ran. If something was not run, say so; do not describe untested work as done.
- **Nothing leaves the machine without the owner.** No `git push`, no tag, no `gem push`, no GitHub release, unless the owner asked for it in the current wave. Commits happen on the wave's branch only, and only when the wave's go-ahead covers them.

## Commands

Ruby 4.0.10 comes from mise (`mise.toml`). In a shell where mise is not activated, which is the case for most agents, prefix any command with `mise x --`.

The table says in which wave each command starts to exist. Until then it is not there.

| Command | Runs | From |
|---|---|---|
| `bundle exec rake` | An explicit list and nothing else: `test`, `rubocop`, `typecheck`, `coverage:check`, `determinism`, `purity`, `parity` from Wave 1b and `nag` from Wave 6. The default pre-merge gate. It never runs `spec:update` or `corpus:update`, which need the network, and never `integration` | 0 |
| `bundle exec rake test` | Minitest, in a child process with the AWS environment scrubbed: the unit tests, the CDK's own tests ported (`test/cdk/`), what crosses components in process (`test/integration/in_process/`), then the component map. Never `test/integration/aws/` | 0 |
| `bundle exec rake rubocop` | Style (rubocop-rails-omakase) | 0 |
| `bundle exec rake typecheck` | Sorbet (`srb tc`), from the Bundler group of its own | 0 |
| `bundle exec rake coverage:check` | Fails below the coverage floor | 0 |
| `bundle exec rake determinism` | Synthesizes every example twice and compares bytes | 1 |
| `bundle exec rake purity` | Fails on Node usage or subprocess calls in `lib/` | 0 |
| `bundle exec rake parity` | The CDK's tests, ported, and the corpus sample; prints the scoreboard of `docs/07-testing.md` §11 | 1b |
| `bundle exec rake corpus:update` | Fetches every template the CDK has synthesized, with git and nothing else. Network. Weekly in CI, never in the default gate | 2 |
| `bundle exec rake spec:update` | Downloads AWS's schema sources and rebuilds the vendored model. Network. Weekly in CI, by hand only on purpose | 2 |
| `bundle exec rake nag` | Security rules over every example template | 6 |
| `bundle exec rake integration` | Real CloudFormation in the sandbox. Never run without the owner's approval for the wave, and never without the three variables of WF-5 | 1 |

## Commits

- Conventional Commits (`feat:`, `fix:`, `docs:`, `test:`, `chore:`, `refactor:`), one logical change per commit.
- No AI attribution in commits: no `Co-Authored-By` trailer, no "assisted by" notes, in the message or anywhere else. The author is the repository owner's git identity.
- Never commit with a red `bundle exec rake`.
- Do not commit build output: `cdk.out/`, `coverage/`, `pkg/` and `sorbet/cache/` are git-ignored; keep it that way. `Gemfile.lock` is committed.
