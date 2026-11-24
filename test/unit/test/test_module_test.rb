# frozen_string_literal: true

require "test_helper"
require "prism"
require "ruby_cdk/test"

# This tool's own tests of RubyCdk::Test as a module: what it loads, and the
# surface it offers. The CDK's own tests of its content are under
# test/cdk/assertions.
class TestModuleTest < Minitest::Test
  # RubyCdk::Test, by a short name.
  T = RubyCdk::Test

  LIB = File.expand_path("../../../lib", __dir__)

  # The module's files, relative to lib/: what the component map gives to test_kit.
  OWN = [ "ruby_cdk/test.rb", "ruby_cdk/test" ].freeze

  # The matcher factories and the arguments of one call of each.
  MATCHERS = {
    absent: [], array_with: [ [] ], array_equals: [ [] ], exact: [ 1 ], object_like: [ {} ], object_equals: [ {} ],
    not_: [ 1 ], serialized_json: [ {} ], any_value: [], string_like_regexp: [ "x" ]
  }.freeze

  # The name a matcher carries into a message: that of the CDK's matcher, which is
  # the method's name here except for not_, since `not` is a Ruby keyword.
  NAMES = MATCHERS.keys.to_h { |name| [ name, name == :not_ ? "not" : name.to_s ] }.freeze

  def test_every_file_of_the_module_loads_only_json_or_another_of_them
    violations = own_files.flat_map do |file|
      loads_in(File.read(file)).filter_map do |line, target, kind|
        problem = if target.nil?
          "#{kind} without a literal argument"
        elsif kind == :require_relative
          resolved = File.expand_path("#{target}.rb", File.dirname(file))
          owned?(resolved) ? nil : "requires #{target}, which is not a file of the module"
        elsif target != "json"
          "loads #{target}"
        end
        "#{file.delete_prefix("#{LIB}/")}:#{line}: #{problem}" if problem
      end
    end

    assert_empty violations, violations.join("\n")
  end

  def test_the_module_loads_nothing_with_load_or_autoload
    kinds = own_files.flat_map { |file| loads_in(File.read(file)) }.map(&:last).uniq.sort

    assert_equal [ :require, :require_relative ], kinds
  end

  def test_requiring_the_module_loads_every_file_of_it
    loaded = $LOADED_FEATURES.select { |feature| File.file?(feature) }.to_h { |feature| [ File.realpath(feature), true ] }
    missing = own_files.map { |file| File.realpath(file) }.reject { |file| loaded[file] }

    assert_empty missing, "not loaded by require \"ruby_cdk/test\": #{missing.join(", ")}"
  end

  def test_requiring_the_module_twice_changes_nothing
    before = $LOADED_FEATURES.length
    require "ruby_cdk/test"

    assert_equal before, $LOADED_FEATURES.length
  end

  def test_the_matchers_are_module_functions_named_as_the_user_calls_them
    MATCHERS.each do |name, arguments|
      matcher = T.public_send(name, *arguments)

      assert T::Matcher.matcher?(matcher), "RubyCdk::Test.#{name} is not a Matcher"
      assert_equal NAMES.fetch(name), matcher.name
      assert_equal T::Matcher, matcher.class.superclass, "#{name} is not one of the engine's own matchers"
    end
  end

  def test_the_matchers_are_also_on_match_as_in_the_cdk
    MATCHERS.each_key do |name|
      assert_respond_to T::Match, name, "RubyCdk::Test::Match.#{name} is missing"
      assert_equal NAMES.fetch(name), T::Match.public_send(name, *MATCHERS.fetch(name)).name
    end
  end

  def test_the_module_names_what_a_user_needs
    [ T::Template, T::Capture, T::Matcher, T::MatchResult, T::Match, T::AssertionError, T::UNDEFINED ].each do |constant|
      assert constant, "#{constant.inspect} is not defined"
    end
    assert_kind_of Class, T::Template
    assert_kind_of Class, T::Capture
    assert T::Capture < T::Matcher
  end

  def test_template_cannot_be_built_with_new
    assert_raises(NoMethodError) { T::Template.new({}) }
  end

  def test_the_matcher_base_class_is_abstract
    matcher = T::Matcher.new

    assert_equal false, T::Matcher.matcher?(Object.new)
    assert_raises(NotImplementedError) { matcher.name }
    assert_raises(NotImplementedError) { matcher.test(1) }
  end

  # Under Minitest, which test_helper.rb loads first, a failed assertion is a
  # Minitest::Assertion, so that Minitest reports it as a failure.
  def test_a_failed_assertion_is_a_minitest_assertion_here
    assert_operator T::AssertionError, :<, Minitest::Assertion

    error = T::AssertionError.new("nope")

    assert_equal "nope", error.message
    assert_equal "assertion", error.type
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/, error.time)
    assert_match(/\ARubyCdk::Test::AssertionError\z/, error.class.name)
  end

  def test_a_failed_assertion_comes_out_of_an_assertion_method
    error = assert_raises(T::AssertionError) { T.from_json({}).resource_count_is("AWS::S3::Bucket", 1) }

    assert_equal "Expected 1 resources of type AWS::S3::Bucket but found 0", error.message
  end

  private

  def own_files
    OWN.flat_map do |relative|
      full = File.join(LIB, relative)
      File.directory?(full) ? Dir[File.join(full, "**", "*.rb")] : [ full ]
    end
  end

  def owned?(path)
    relative = path.delete_prefix("#{LIB}/")
    OWN.any? { |owned| relative == owned || relative.start_with?("#{owned}/") }
  end

  # [[line, target, kind], ...] for every require, require_relative, load and
  # autoload in the source. target is nil when its argument is not a literal.
  def loads_in(source)
    found = []
    stack = [ Prism.parse(source).value ]
    until stack.empty?
      node = stack.pop
      if node.is_a?(Prism::CallNode) && LOADERS.key?(node.name) && node.arguments
        argument = node.arguments.arguments.first
        target = argument.is_a?(Prism::StringNode) ? argument.unescaped : nil
        found << [ node.location.start_line, target, LOADERS.fetch(node.name) ]
      end
      stack.concat(node.compact_child_nodes)
    end
    found
  end

  LOADERS = { require: :require, require_relative: :require_relative, load: :load, autoload: :autoload, require_or_load: :require_or_load }.freeze
end
