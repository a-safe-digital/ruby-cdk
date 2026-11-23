# frozen_string_literal: true

require "test_helper"
require_relative "../../support/deploy_fixtures"

# The errors the engine raises, the exit code each carries (architecture section
# 14), and the ports they are raised across: what a port does until something
# answers it, and that everything meant to answer one answers all of it.
class DeployErrorsTest < Minitest::Test
  include DeployFixtures
  D = RubyCdk::Deploy

  def test_the_exit_code_of_every_error_class_in_errors_rb
    { RubyCdk::RulesFailed => 6, RubyCdk::DeploymentFailed => 5, RubyCdk::ApprovalRefused => 4, RubyCdk::ChangeSetRejected => 3,
      RubyCdk::UsageError => 1, RubyCdk::PreconditionError => 1, RubyCdk::Error => 1 }.each do |klass, code|
      assert_equal code, D.exit_code_for(klass.new("x")), klass.name
    end
    assert_equal 2, D.exit_code_for(RubyCdk::ValidationError.new([]))
    assert_equal 2, D.exit_code_for(RubyCdk::ValidationError.new([ "rule V3 path: message" ]))
  end

  def test_anything_else_exits_1
    [ ArgumentError, NoMethodError, RuntimeError, StandardError ].each do |klass|
      assert_equal 1, D.exit_code_for(klass.new("a bug")), klass.name
    end
  end

  def test_the_engine_s_errors_carry_the_exit_code_of_their_situation
    one = [ D::TargetMismatch, D::AccountMismatch, D::AccountUnresolved, D::StackBusy, D::StackNeedsRepair, D::UnknownStackStatus,
      D::InvalidTemplate, D::TemplateTooLarge, D::DestroyRefused, D::WaitTimedOut ]
    one.each do |klass|
      assert_kind_of RubyCdk::PreconditionError, klass.new("x"), klass.name
      assert_equal 1, D.exit_code_for(klass.new("x")), klass.name
    end
    assert_kind_of RubyCdk::UsageError, D::AccountRequired.new("x")
    assert_kind_of RubyCdk::UsageError, D::ParametersMissing.new("x")
    assert_kind_of RubyCdk::ChangeSetRejected, D::ChangeSetFailed.new("x")
    assert_equal 3, D.exit_code_for(D::ChangeSetFailed.new("x"))
    assert_kind_of RubyCdk::ApprovalRefused, D::ApprovalRequired.new("x")
    assert_equal 4, D.exit_code_for(D::ApprovalRequired.new("x"))
  end

  # --- the ports

  PORTS = [ RubyCdk::Deploy::CfnClient, RubyCdk::Deploy::ObjectStore, RubyCdk::Deploy::Output ].freeze

  # What a port does until something answers it: it refuses.
  def test_a_port_refuses_until_something_answers_it
    PORTS.each do |port|
      bare = Object.new.extend(port)
      port.public_instance_methods(false).each do |name|
        parameters = port.instance_method(name).parameters
        positional = parameters.count { |kind, _parameter| kind == :req }
        keywords = parameters.filter_map { |kind, parameter| [ parameter, nil ] if kind == :keyreq }.to_h

        assert_raises(NotImplementedError, "#{port}##{name}") { bare.public_send(name, *Array.new(positional), **keywords) }
      end
    end
  end

  # And everything that is meant to answer a port answers all of it, with a
  # method of its own: a method left to the port would refuse at the worst time.
  def test_the_fakes_and_the_outputs_answer_every_method_of_their_ports
    { RubyCdk::Deploy::CfnClient => [ D::Fakes::CfnClient ],
      RubyCdk::Deploy::ObjectStore => [ D::Fakes::ObjectStore ],
      RubyCdk::Deploy::Output => [ D::Fakes::Output, D::Output::Base, D::Output::Human, D::Output::Quiet, D::Output::Json ] }.each do |port, answers|
      port.public_instance_methods(false).each do |name|
        answers.each do |klass|
          assert klass.method_defined?(name), "#{klass} does not answer #{name}"
          refute_equal port, klass.instance_method(name).owner, "#{klass}##{name} is only the port's refusal"
        end
      end
    end
  end

  def test_the_ports_are_the_ones_the_engine_s_tests_stand_on
    assert_equal %i[announce ask changes confirm event failure outputs retained target],
      RubyCdk::Deploy::Output.public_instance_methods(false).sort
    assert_includes RubyCdk::Deploy::CfnClient.public_instance_methods(false), :list_stacks
    assert_equal %i[name id status], RubyCdk::Deploy::ListedStack.members
  end
end
