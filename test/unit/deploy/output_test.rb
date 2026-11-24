# frozen_string_literal: true

require "test_helper"
require "stringio"
require_relative "../../support/deploy_fixtures"

# The three outputs: one for a person, one for --quiet, one for --json. None of
# them may print a credential. What crosses the interface is an account ID (an
# identifier, printed whole), a region, a profile name, changes, events and
# outputs; the values of template properties and of parameters never are.
class DeployOutputTest < Minitest::Test
  D = RubyCdk::Deploy
  ACCOUNT = "111122223333"

  # A standard input to answer from: with a terminal behind it, or without.
  class Stdin
    attr_reader :lines

    def initialize(lines, terminal: false)
      @lines = lines
      @terminal = terminal
    end

    def tty?
      @terminal
    end

    def gets
      @lines.shift
    end
  end

  # An input that is interrupted when read, as Ctrl-C at a question.
  class Interrupted < Stdin
    def gets
      raise Interrupt
    end
  end

  Screen = Struct.new(:log, :result, :output)

  # An output of the class, writing to two strings. color is for Human alone.
  def screen(klass, color: nil, stdin: Stdin.new([], terminal: false))
    log = StringIO.new
    result = StringIO.new
    options = { io: log, stdin: stdin, result_io: result }
    options[:color] = color if klass == D::Output::Human
    Screen.new(log, result, klass.new(**options))
  end

  def human(**options)
    screen(D::Output::Human, color: false, **options)
  end

  def secret_change
    D::Change.new(
      action: "Modify",
      logical_id: "Database",
      resource_type: "AWS::RDS::DBInstance",
      replacement: "Conditional",
      detail: [
        { "target" => { "attribute" => "Properties", "name" => "MasterUserPassword", "before_value" => "hunter2-old",
          "after_value" => "hunter2-new" } },
        { "target" => { "attribute" => "Properties", "name" => "AllocatedStorage", "before_value" => "5", "after_value" => "20" } }
      ]
    )
  end

  # --- for a person

  def test_the_target_names_the_account_whole_the_region_and_the_profile
    shown = human

    shown.output.target(account: ACCOUNT, region: "eu-west-1", profile: "work")

    assert_equal "Target: account #{ACCOUNT}, region eu-west-1, profile work\n", shown.log.string
    assert_equal "", shown.result.string, "what happens is not a result"
  end

  def test_without_a_profile_the_default_chain_is_named_as_such
    shown = human

    shown.output.target(account: ACCOUNT, region: "eu-west-1", profile: nil)

    assert_match(/profile the default credential chain/, shown.log.string)
  end

  def test_the_change_view_shows_what_changes_and_never_a_property_value
    shown = human
    add = D::Change.new(action: "Add", logical_id: "Bucket", resource_type: "AWS::S3::Bucket", replacement: "False")
    gone = D::Change.new(action: "Remove", logical_id: "Old", resource_type: "AWS::SQS::Queue")

    shown.output.changes([ add, secret_change, gone ], capabilities: %w[CAPABILITY_IAM CAPABILITY_NAMED_IAM])

    text = shown.log.string
    assert_match(/^Changes$/, text)
    assert_match(/^\s+Add\s+Bucket\s+AWS::S3::Bucket$/, text)
    assert_match(/^\s+Remove\s+Old\s+AWS::SQS::Queue$/, text)
    assert_match(/Modify\s+Database\s+AWS::RDS::DBInstance\s+Conditional/, text)
    assert_match(/Properties: MasterUserPassword, Properties: AllocatedStorage/, text, "the properties are named")
    refute_includes text, "hunter2", "never their values"
    refute_includes text, "20"
    assert_match(/Capabilities needed: CAPABILITY_IAM, CAPABILITY_NAMED_IAM, because the template creates IAM resources, some with explicit names/, text)
  end

  def test_an_empty_change_view_prints_nothing
    shown = human

    shown.output.changes([], capabilities: [])

    assert_equal "", shown.log.string
  end

  def test_a_question_is_answered_yes_only_by_y_or_yes
    %w[y Y yes YES].each do |answer|
      shown = human(stdin: Stdin.new([ "#{answer}\n" ], terminal: true))

      assert shown.output.ask("Deploy?"), answer
    end
    %w[n no later yep ""].each do |answer|
      shown = human(stdin: Stdin.new([ "#{answer}\n" ], terminal: true))

      refute shown.output.ask("Deploy?"), answer.inspect
    end
  end

  def test_an_end_of_input_is_not_a_yes
    shown = human(stdin: Stdin.new([], terminal: true))

    refute shown.output.ask("Deploy?")
  end

  def test_without_a_terminal_nobody_can_answer_so_nothing_is_asked
    shown = human(stdin: Stdin.new([ "y\n" ], terminal: false))

    refute shown.output.ask("Deploy?")
    refute shown.output.confirm("blog"), "the answer that was waiting is not read"
    assert_equal "", shown.log.string, "a question nobody can answer is not written; the engine says what to do instead"
  end

  def test_interrupting_the_question_is_not_a_yes
    shown = human(stdin: Interrupted.new([], terminal: true))

    refute shown.output.ask("Deploy?")
    refute shown.output.confirm("blog")
  end

  def test_a_confirmation_needs_the_text_exactly_around_its_whitespace
    question = nil
    [ "blog", "blog\n", " blog \n" ].each do |typed|
      shown = human(stdin: Stdin.new([ typed ], terminal: true))
      question ||= shown

      assert shown.output.confirm("blog"), typed.inspect
    end
    [ "Blog", "blog2", "blog and more", "" ].each do |typed|
      shown = human(stdin: Stdin.new([ "#{typed}\n" ], terminal: true))

      refute shown.output.confirm("blog"), typed.inspect
    end
    assert_match(/To confirm, type "blog"/, question.log.string)
  end

  def test_an_event_shows_its_time_status_type_and_name_and_a_reason_only_when_it_failed
    shown = human
    at = Time.utc(2026, 1, 1, 12, 30, 59)

    shown.output.event(D::Event.new(resource_status: "CREATE_IN_PROGRESS", logical_id: "Bucket", resource_type: "AWS::S3::Bucket",
      status_reason: "Resource creation Initiated", timestamp: at))
    shown.output.event(D::Event.new(resource_status: "CREATE_FAILED", logical_id: "Bucket", resource_type: "AWS::S3::Bucket",
      status_reason: "Name already exists", timestamp: at + 1))

    lines = shown.log.string.lines
    assert_match(/12:30:59Z\s+CREATE_IN_PROGRESS\s+AWS::S3::Bucket\s+Bucket$/, lines[0])
    refute_includes lines[0], "Initiated"
    assert_match(/12:31:00Z\s+CREATE_FAILED\s+AWS::S3::Bucket\s+Bucket\s+Name already exists$/, lines[1])
    assert_match(/--:--:--/, human.tap { |screen| screen.output.event(D::Event.new(resource_status: "CREATE_COMPLETE")) }.log.string)
  end

  def test_the_outputs_are_the_result_and_go_to_standard_out
    shown = human

    shown.output.outputs({ "Url" => "https://example.invalid", "Arn" => "arn:aws:s3:::data" })
    shown.output.outputs({})

    assert_equal "Outputs:\n  Url = https://example.invalid\n  Arn = arn:aws:s3:::data\n", shown.result.string
    assert_equal "", shown.log.string
  end

  def test_a_failure_what_will_be_kept_and_announcements_are_written_to_the_log
    shown = human
    kept = D::RetainedResource.new(logical_id: "Data", resource_type: "AWS::DynamoDB::Table", deletion_policy: "RetainExceptOnCreate")

    shown.output.failure("It failed.\n  Bucket: because")
    shown.output.retained([ kept ])
    shown.output.retained([])
    shown.output.announce("Deleting it, then creating it again.")

    assert_equal "It failed.\n  Bucket: because\n" \
      "Kept after the stack is deleted (their DeletionPolicy says so):\n" \
      "  Data  AWS::DynamoDB::Table  RetainExceptOnCreate\n" \
      "Deleting it, then creating it again.\n", shown.log.string
  end

  def test_colour_is_put_on_what_to_look_at_and_only_when_asked_for
    plain = human(color: false)
    coloured = human(color: true)
    coloured.output.target(account: ACCOUNT, region: "eu-west-1", profile: nil)
    coloured.output.changes([ secret_change ])
    coloured.output.event(D::Event.new(resource_status: "CREATE_COMPLETE", timestamp: Time.utc(2026, 1, 1)))
    coloured.output.event(D::Event.new(resource_status: "CREATE_FAILED", timestamp: Time.utc(2026, 1, 1)))
    coloured.output.failure("no")

    assert_includes coloured.log.string, "\e[1m"
    assert_includes coloured.log.string, "\e[32m"
    assert_includes coloured.log.string, "\e[31m"
    refute_includes human.log.string, "\e[", "colour is off unless it is asked for"
    assert_equal "", plain.log.string
  end

  def test_what_has_no_colour_of_its_own_is_written_plain
    shown = human(color: true)

    shown.output.changes([ D::Change.new(action: "Dynamic", logical_id: "X", resource_type: "AWS::CloudFormation::CustomResource") ])

    lines = shown.log.string.lines
    assert_match(/^\s+Dynamic\s+X\s+AWS::CloudFormation::CustomResource$/, lines.last)
    refute_includes lines.last, "\e[", "the line of the change itself is plain"
    assert_equal 4, shown.log.string.count("\e["), "and only the heading is coloured, on and off"
  end

  def test_a_colour_says_whether_a_status_failed_is_under_way_or_succeeded
    red = "\e[31m"
    yellow = "\e[33m"
    green = "\e[32m"
    shown = human(color: true)
    status_of = lambda { |line| line[/\e\[(\d+)m/, 1] }

    %w[CREATE_FAILED UPDATE_ROLLBACK_FAILED ROLLBACK_COMPLETE UPDATE_ROLLBACK_COMPLETE DELETE_FAILED].each do |status|
      shown.output.event(D::Event.new(resource_status: status))
      assert_equal "31", status_of.call(shown.log.string.lines.last), "#{status} is red: it went wrong, or was rolled back"
    end
    %w[CREATE_IN_PROGRESS ROLLBACK_IN_PROGRESS UPDATE_ROLLBACK_IN_PROGRESS UPDATE_ROLLBACK_COMPLETE_CLEANUP_IN_PROGRESS DELETE_IN_PROGRESS].each do |status|
      shown.output.event(D::Event.new(resource_status: status))
      assert_equal "33", status_of.call(shown.log.string.lines.last), "#{status} is yellow: a rollback under way is not a failure yet"
    end
    %w[CREATE_COMPLETE UPDATE_COMPLETE IMPORT_COMPLETE].each do |status|
      shown.output.event(D::Event.new(resource_status: status))
      assert_equal "32", status_of.call(shown.log.string.lines.last), "#{status} is green"
    end
    assert_equal [ red, yellow, green ].uniq, [ red, yellow, green ]
  end

  def test_the_plain_output_is_an_output_of_its_own_with_no_colour_and_its_questions_asked
    shown = screen(D::Output::Base, stdin: Stdin.new([ "y\n" ], terminal: true))

    shown.output.target(account: ACCOUNT, region: "eu-west-1", profile: nil)
    shown.output.changes([ secret_change ], capabilities: %w[CAPABILITY_IAM])
    shown.output.event(D::Event.new(resource_status: "CREATE_COMPLETE", timestamp: nil))
    assert shown.output.ask("Deploy?")

    assert_equal "Target: account #{ACCOUNT}, region eu-west-1, profile the default credential chain\n" \
      "Changes\n" \
      "  Modify  Database  AWS::RDS::DBInstance  Conditional\n" \
      "          Properties: MasterUserPassword, Properties: AllocatedStorage\n" \
      "  Capabilities needed: CAPABILITY_IAM, because the template creates IAM resources.\n" \
      "  --:--:--  CREATE_COMPLETE\n" \
      "? Deploy? [y/N] \n", shown.log.string
    refute_includes shown.log.string, "\e["
  end

  def test_colour_follows_the_terminal_unless_it_is_set
    terminal = StringIO.new
    def terminal.tty? = true
    shown = D::Output::Human.new(io: terminal, stdin: Stdin.new([]), result_io: StringIO.new)

    shown.failure("no")

    assert_includes terminal.string, "\e[31m"
    refute_includes D::Output::Human.new(io: StringIO.new, stdin: Stdin.new([]), result_io: StringIO.new)
      .tap { |output| output.failure("no") }.then { "" }, "\e["
  end

  # --- for --quiet

  def test_quiet_leaves_out_the_progress_and_keeps_what_a_decision_needs
    shown = screen(D::Output::Quiet, stdin: Stdin.new([ "y\n" ], terminal: true))
    kept = D::RetainedResource.new(logical_id: "Data", resource_type: "AWS::DynamoDB::Table", deletion_policy: "Retain")

    shown.output.announce("creating")
    shown.output.changes([ secret_change ])
    shown.output.event(D::Event.new(resource_status: "CREATE_COMPLETE"))
    shown.output.target(account: ACCOUNT, region: "eu-west-1", profile: nil)
    shown.output.retained([ kept ])
    shown.output.failure("It failed.")
    shown.output.outputs({ "Url" => "https://example.invalid" })
    assert(shown.output.ask("Deploy?"), "a question is still asked where it can be answered")

    assert_equal "Target: account #{ACCOUNT}, region eu-west-1, profile the default credential chain\n" \
      "Kept after the stack is deleted (their DeletionPolicy says so):\n" \
      "  Data  AWS::DynamoDB::Table  Retain\n" \
      "It failed.\n" \
      "? Deploy? [y/N] \n", shown.log.string
    assert_equal "Outputs:\n  Url = https://example.invalid\n", shown.result.string
  end

  # --- for --json

  def test_json_writes_one_object_per_line_each_with_a_type_and_nothing_to_standard_out
    shown = screen(D::Output::Json, stdin: Stdin.new([ "y\n", "blog\n" ], terminal: true))
    at = Time.utc(2026, 1, 1, 12, 30, 59, 123456)

    shown.output.target(account: ACCOUNT, region: "eu-west-1", profile: nil)
    shown.output.changes([ secret_change ], capabilities: %w[CAPABILITY_IAM])
    shown.output.announce("creating")
    shown.output.event(D::Event.new(resource_status: "CREATE_COMPLETE", timestamp: at))
    shown.output.retained([])
    shown.output.failure("It failed.")
    shown.output.outputs({ "Url" => "https://example.invalid" })
    assert shown.output.ask("Deploy?")
    assert shown.output.confirm("blog")

    lines = shown.log.string.lines.map { |line| JSON.parse(line) }
    assert_equal %w[target changes announce event retained failure outputs ask confirm], lines.map { |line| line["type"] }
    assert_equal({ "type" => "target", "account" => ACCOUNT, "region" => "eu-west-1", "profile" => nil }, lines[0])
    assert_equal(
      { "type" => "changes",
        "changes" => [ { "action" => "Modify", "logical_id" => "Database", "resource_type" => "AWS::RDS::DBInstance",
          "replacement" => "Conditional", "properties" => [ "Properties: MasterUserPassword", "Properties: AllocatedStorage" ] } ],
        "capabilities" => %w[CAPABILITY_IAM] },
      lines[1], "the properties by name, never their values"
    )
    assert_equal "2026-01-01T12:30:59.123456Z", lines[3]["event"]["timestamp"], "a time is written as CloudFormation writes it"
    assert_equal({ "type" => "ask", "question" => "Deploy?" }, lines[7])
    assert_equal({ "type" => "confirm", "text" => "blog" }, lines[8])
    assert_equal "", shown.result.string, "standard out is left whole for the command's result"
  end

  def test_json_without_a_terminal_does_not_ask_for_an_answer
    shown = screen(D::Output::Json, stdin: Stdin.new([ "y\n" ], terminal: false))

    refute shown.output.ask("Deploy?")

    assert_equal [ "ask" ], shown.log.string.lines.map { |line| JSON.parse(line)["type"] }, "the question is still written"
  end

  # --- no credential is ever printed

  def test_nothing_any_output_receives_can_carry_a_credential
    [ D::Output::Human, D::Output::Quiet, D::Output::Json ].each do |klass|
      screen_of = screen(klass, color: true)
      output = screen_of.output

      output.target(account: ACCOUNT, region: "eu-west-1", profile: "work")
      output.changes([ secret_change ], capabilities: %w[CAPABILITY_IAM])
      output.event(D::Event.new(resource_status: "CREATE_FAILED", status_reason: "secret-looking reason", timestamp: Time.utc(2026, 1, 1)))
      output.outputs({ "Url" => "https://example.invalid" })
      output.failure("failed")
      output.retained([])
      output.announce("announced")

      text = screen_of.log.string + screen_of.result.string
      refute_includes text, "hunter2", klass.name
      assert_includes text, ACCOUNT, "an account ID is an identifier and is printed where it helps"
    end
  end

  def test_through_a_whole_deploy_no_value_of_the_template_or_of_a_parameter_reaches_the_output
    body = JSON.generate(
      "Parameters" => { "Password" => { "Type" => "String", "NoEcho" => true } },
      "Resources" => { "Database" => { "Type" => "AWS::RDS::DBInstance", "Properties" => { "MasterUserPassword" => { "Ref" => "Password" },
        "DBName" => "template-secret" } } }
    )
    %i[Human Quiet Json].each do |name|
      client = D::Fakes::CfnClient.new
      client.on(:describe_change_set, ->(call) {
        D::ChangeSet.new(id: call.args[1], status: "CREATE_COMPLETE", changes: [ secret_change ])
      })
      shown = screen(D::Output.const_get(name), color: true)

      D::Deployer.new(client: client, store: D::Fakes::ObjectStore.new, output: shown.output, poller: D::Poller.instant,
        operation_poller: D::Poller.instant).deploy(stack: DeployFixtures::Stack.new, template: body, identity: client.identity,
        options: D::DeployOptions.new(yes: true, account: ACCOUNT, parameters: { "Password" => "parameter-secret" }))

      text = shown.log.string + shown.result.string
      assert_includes text, "MasterUserPassword", "#{name}: the property is named" unless name == :Quiet
      refute_includes text, "hunter2", name.to_s
      refute_includes text, "template-secret", name.to_s
      refute_includes text, "parameter-secret", name.to_s
    end
  end
end
