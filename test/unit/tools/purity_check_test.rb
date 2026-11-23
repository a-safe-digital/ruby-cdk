# frozen_string_literal: true

require "test_helper"
require_relative "../../../tools/purity_check"

class PurityCheckTest < Minitest::Test
  def check(source)
    Tools::PurityCheck.violations_in_source(source, "probe.rb")
  end

  # The single violation, having checked that there is exactly one.
  def one(violations)
    assert_equal 1, violations.size, "expected exactly one violation, got #{violations.inspect}"
    violations.first
  end

  def test_a_process_call_is_a_violation
    assert_match(/`system` starts a process/, one(check(%(system("ls")))))
    assert_match(/`spawn` starts a process/, one(check("spawn('ls')")))
    assert_match(/`popen` starts a process/, one(check("IO.popen('ls')")))
    assert_match(/`capture3` starts a process/, one(check("Open3.capture3('ls')")))
  end

  def test_a_backtick_string_is_a_violation
    assert_match(/backticks run a shell command/, one(check("out = `ls`")))
  end

  def test_a_backtick_inside_an_ordinary_string_is_not_a_violation
    assert_empty check(%(raise "did you mean `Fn.ref(...)`?"))
  end

  def test_a_toolchain_name_in_a_string_is_a_violation
    assert_match(/names the JavaScript toolchain: "npx"/, one(check('tool = "npx"')))
    assert_match(/names the JavaScript toolchain: "jsii"/, one(check(":jsii")))
    assert_empty check('tool = "node_modules_are_not_a_tool"')
  end

  def test_a_toolchain_name_in_a_comment_is_not_a_violation
    assert_empty check("# never call node")
  end

  def test_the_marker_allows_toolchain_names
    assert_empty check("# purity: allow-node-words\nwords = %w[node npx]")
  end

  def test_ruby_that_does_none_of_this_is_clean
    assert_empty check(<<~RUBY)
      require "json"
      def render(value)
        JSON.generate(value)
      end
    RUBY
  end

  def test_code_that_does_not_parse_is_reported
    assert_match(/does not parse/, one(check("def broken(")))
  end

  def test_text_lines
    violations = Tools::PurityCheck.violations_in_text(
      [
        "      - uses: actions/checkout@v7",
        "      - run: npx cdk synth",
        "      # npm is mentioned here in a comment",
        "      - run: bundle exec rake   # purity, style"
      ],
      ".github/workflows/ci.yml",
    )

    assert_equal [ ".github/workflows/ci.yml:2: names the JavaScript toolchain: - run: npx cdk synth" ], violations
  end

  def test_this_repository_is_clean
    root = File.expand_path("../../..", __dir__)

    assert_equal [], Tools::PurityCheck.violations_in_repo(root)
  end
end
