# frozen_string_literal: true

# The sweeper's logic, with a fake port and no client: WF-5 rule 6's decisions,
# and the report that leaves every physical resource to a person. The run
# against AWS itself belongs to `rake sweep`, which nothing in the suite runs.

require "test_helper"
require_relative "../../integration/sweeper"

# A CloudFormation port with stacks in it, for the sweeper. A stack carries its
# tags, its resources and the timestamp of its creation event, which is what
# the sweeper reads its age from. A delete_stack moves the stack to
# DELETE_IN_PROGRESS — what a real account answers in the seconds after the
# ask — unless the test says it ends otherwise; a scripted error refuses the
# deletion and the stack stays as it was.
class SweepFakeClient
  Stack = Data.define(:name, :id, :status)
  Resource = Data.define(:logical_id, :physical_id, :status)
  Event = Data.define(:resource_status, :timestamp)

  attr_reader :calls

  def initialize
    @stacks = {}
    @tags = {}
    @resources = {}
    @events = {}
    @delete_errors = {}
    @ghosts = []
    @calls = []
  end

  # after: what the listing shows once its deletion was asked for. nil, the
  # stack is gone from the listing; a status, and it is listed with that.
  def stack(name, id: "arn:aws:cloudformation:eu-central-1:111122223333:stack/#{name}/id-1", status: "CREATE_COMPLETE",
    tags: [], resources: [], created: nil, after: "DELETE_IN_PROGRESS")
    @stacks[name] = { stack: Stack.new(name: name, id: id, status: status), after: after }
    @tags[name] = tags
    @resources[id] = resources
    @events[id] = created ? [ Event.new(resource_status: "CREATE_IN_PROGRESS", timestamp: created) ] : []
    self
  end

  # Listed only while the first listing is read, and stack_info answers nil
  # for it: it vanished between the two calls of the pass.
  def ghost(name, id: "arn:aws:cloudformation:eu-central-1:111122223333:stack/#{name}/id-9", status: "CREATE_COMPLETE")
    @ghosts << Stack.new(name: name, id: id, status: status)
    self
  end

  def fails_to_delete(id, with:)
    @delete_errors[id] = with
    self
  end

  # --- the port

  def stack_info(name)
    @calls << [ :stack_info, name ]
    @stacks.dig(name, :stack)
  end

  def stack_tags(name)
    @calls << [ :stack_tags, name ]
    @tags.fetch(name, [])
  end

  def list_stacks
    @calls << [ :list_stacks ]
    found = @stacks.values.map { |record| record[:stack] }
    if @calls.count([ :list_stacks ]) == 1
      found + @ghosts
    else
      found
    end
  end

  def list_resources(id)
    @calls << [ :list_resources, id ]
    @resources.fetch(id, [])
  end

  def delete_stack(id)
    @calls << [ :delete_stack, id ]
    raise @delete_errors.fetch(id) if @delete_errors.key?(id)

    name, record = @stacks.find { |_, candidate| candidate[:stack].id == id }
    return unless record

    if record[:after].nil?
      @stacks.delete(name)
    else
      @stacks[name] = { stack: record[:stack].with(status: record[:after]), after: record[:after] }
    end
  end

  def events(name_or_id, after:)
    @calls << [ :events, name_or_id ]
    @events.fetch(name_or_id, []).select { |event| event.timestamp > after }
  end
end

module Integration
  class SweeperTest < Minitest::Test
    NOW = Time.utc(2026, 11, 25, 12, 0, 0)
    TEN_HOURS_AGO = NOW - (10 * 3600)
    ONE_HOUR_AGO = NOW - 3600
    TAG = [ { key: Sweeper::TAG_KEY, value: Sweeper::TAG_VALUE } ]

    def sweep(client, **options)
      Sweeper.new(client: client, log: StringIO.new, now: NOW, **options).run
    end

    def test_an_old_tagged_stack_is_deleted_by_its_id_which_was_read_first
      client = SweepFakeClient.new.stack("ruby-cdk-it-lambda", created: TEN_HOURS_AGO, tags: TAG, after: nil)

      result = sweep(client)

      assert_equal [
        Sweeper::DeletedStack.new(name: "ruby-cdk-it-lambda",
          id: "arn:aws:cloudformation:eu-central-1:111122223333:stack/ruby-cdk-it-lambda/id-1")
      ], result.deleted
      assert_empty result.kept
      assert_empty result.failed_deletions
      assert_empty result.remaining, "a stack the listing no longer names is not reported"
      refute result.leftover?

      sequence = client.calls.map(&:first)
      assert_includes sequence, :delete_stack
      assert_operator sequence.index(:stack_info), :<, sequence.index(:delete_stack), "the ID is read before the deletion"
      assert_operator sequence.index(:events), :<, sequence.index(:delete_stack), "the age is read before the deletion"
      id_call = client.calls.find { |call| call.first == :delete_stack }
      assert_equal "arn:aws:cloudformation:eu-central-1:111122223333:stack/ruby-cdk-it-lambda/id-1", id_call[1],
        "the deletion is of the ID, not of the name"
    end

    def test_a_fresh_tagged_stack_is_kept
      client = SweepFakeClient.new.stack("ruby-cdk-it-hello", created: ONE_HOUR_AGO, tags: TAG)

      result = sweep(client)

      assert_empty result.deleted
      assert_empty client.calls.select { |call| call.first == :delete_stack }
      assert_equal [ "ruby-cdk-it-hello" ], result.kept.map(&:name)
      assert_in_delta 1.0, result.kept.first.age_hours, 0.01
      refute result.leftover?
    end

    def test_the_bootstrap_stack_is_never_matched
      client = SweepFakeClient.new
        .stack("ruby-cdk-bootstrap", created: TEN_HOURS_AGO, tags: TAG, resources: [
          SweepFakeClient::Resource.new(logical_id: "Bucket", physical_id: "rn:bootstrap-bucket", status: "CREATE_COMPLETE")
        ])
        .stack("ruby-cdk-it-lambda", created: TEN_HOURS_AGO, tags: TAG, after: nil)

      result = sweep(client)

      touched = client.calls.flatten
      refute_includes touched, "ruby-cdk-bootstrap", "no call reaches the bootstrap stack"
      assert_equal [ "ruby-cdk-it-lambda" ], result.deleted.map(&:name)
      assert_empty result.remaining, "a stack the prefix does not name is not this sweeper's leftover"
    end

    def test_a_prefixed_stack_without_the_tag_is_never_deleted_and_is_reported
      client = SweepFakeClient.new.stack("ruby-cdk-it-sneaky", created: TEN_HOURS_AGO, tags: [])

      result = sweep(client)

      assert_empty result.deleted
      leftover = result.remaining.first
      assert_equal "ruby-cdk-it-sneaky", leftover.name
      assert leftover.failure, "it is reported as needing a person"
      assert_includes leftover.reason, "tag ruby-cdk-integration=true"
      assert result.leftover?
    end

    def test_a_prefixed_stack_whose_tag_value_is_not_true_is_not_deleted
      client = SweepFakeClient.new.stack("ruby-cdk-it-half", created: TEN_HOURS_AGO,
        tags: [ { key: Sweeper::TAG_KEY, value: "false" } ])

      result = sweep(client)

      assert_empty result.deleted
      assert result.remaining.one? { |left| left.name == "ruby-cdk-it-half" && left.failure }
    end

    def test_a_stack_of_unknown_age_is_never_deleted
      client = SweepFakeClient.new.stack("ruby-cdk-it-mute", created: nil, tags: TAG)

      result = sweep(client)

      assert_empty result.deleted
      assert_empty client.calls.select { |call| call.first == :delete_stack }
      leftover = result.remaining.first
      assert leftover.failure
      assert_includes leftover.reason, "age is not known"
      assert result.leftover?
    end

    def test_a_deletion_that_fails_is_recorded_and_the_rest_still_deleted
      old_id = "arn:aws:cloudformation:eu-central-1:111122223333:stack/ruby-cdk-it-stuck/id-1"
      client = SweepFakeClient.new
        .stack("ruby-cdk-it-stuck", id: old_id, created: TEN_HOURS_AGO, tags: TAG, resources: [
          SweepFakeClient::Resource.new(logical_id: "Bucket", physical_id: "rn:kept-bucket", status: "CREATE_COMPLETE")
        ])
        .stack("ruby-cdk-it-lambda", created: TEN_HOURS_AGO, tags: TAG, after: nil)
        .fails_to_delete(old_id, with: RubyCdk::PreconditionError.new("Stack ruby-cdk-it-stuck is protected from deletion"))

      result = sweep(client)

      assert_equal [ "ruby-cdk-it-lambda" ], result.deleted.map(&:name), "one refusal does not stop the pass"
      assert_equal [ "ruby-cdk-it-stuck" ], result.failed_deletions.map(&:name)
      assert_includes result.failed_deletions.first.reason, "protected from deletion"
      leftover = result.remaining.find { |left| left.name == "ruby-cdk-it-stuck" }
      assert leftover.failure
      assert_includes leftover.reason, "its deletion failed"
      assert_equal [ "Bucket (rn:kept-bucket)" ], leftover.physical_ids,
        "the physical IDs of what CloudFormation kept are reported"
      assert result.leftover?
    end

    def test_a_stack_still_deleting_after_its_deletion_was_asked_for_is_in_flight_and_not_a_failure
      client = SweepFakeClient.new.stack("ruby-cdk-it-lambda", created: TEN_HOURS_AGO, tags: TAG, after: "DELETE_IN_PROGRESS")

      result = sweep(client)

      assert_equal [ "ruby-cdk-it-lambda" ], result.deleted.map(&:name)
      leftover = result.remaining.first
      refute leftover.failure
      assert_includes leftover.reason, "carrying it out"
      refute result.leftover?
    end

    def test_a_stack_asked_to_delete_but_still_listed_as_it_was_needs_a_person
      client = SweepFakeClient.new.stack("ruby-cdk-it-stuck", created: TEN_HOURS_AGO, tags: TAG, after: "CREATE_COMPLETE")

      result = sweep(client)

      leftover = result.remaining.first
      assert leftover.failure
      assert_includes leftover.reason, "still listed as"
      assert result.leftover?
    end

    def test_the_leftover_report_carries_the_physical_ids_of_what_was_not_deleted
      kept_resource = SweepFakeClient::Resource.new(logical_id: "Table", physical_id: "arn:aws:dynamodb:table/kept", status: "DELETE_SKIPPED")
      gone_resource = SweepFakeClient::Resource.new(logical_id: "Queue", physical_id: "https://queue", status: "DELETE_COMPLETE")
      client = SweepFakeClient.new
        .stack("ruby-cdk-it-old", created: TEN_HOURS_AGO, tags: TAG, resources: [ kept_resource, gone_resource ],
          after: "DELETE_FAILED")
        .stack("ruby-cdk-it-young", created: ONE_HOUR_AGO, tags: TAG, resources: [
          SweepFakeClient::Resource.new(logical_id: "Bucket", physical_id: "rn:young-bucket", status: "CREATE_COMPLETE")
        ])

      result = sweep(client)

      old = result.remaining.find { |left| left.name == "ruby-cdk-it-old" }
      assert_equal [ "Table (arn:aws:dynamodb:table/kept)" ], old.physical_ids,
        "a deleted resource is not reported, a kept one is"
      young = result.remaining.find { |left| left.name == "ruby-cdk-it-young" }
      assert_equal [ "Bucket (rn:young-bucket)" ], young.physical_ids, "a kept stack's live resources are reported too"
      refute young.failure
    end

    def test_a_stack_that_vanished_between_the_listing_and_the_ask_is_not_touched
      client = SweepFakeClient.new.ghost("ruby-cdk-it-gone")

      result = sweep(client)

      assert_empty result.deleted
      assert_empty result.remaining
      refute result.leftover?
      assert_empty client.calls.select { |call| call.first == :delete_stack }
    end

    def test_a_stack_that_could_not_be_read_between_the_two_listings_is_reported
      client = SweepFakeClient.new.stack("ruby-cdk-it-appear", created: ONE_HOUR_AGO, tags: [])
      client.define_singleton_method(:stack_info) do |name|
        @calls << [ :stack_info, name ]
        nil # it is gone before the sweeper can read it, yet listed at the end
      end

      result = sweep(client)

      assert_empty result.deleted
      leftover = result.remaining.first
      assert leftover.failure
      assert_includes leftover.reason, "appeared while the sweep ran"
    end

    def test_six_hours_is_the_default_and_the_variable_overrides_it
      assert_equal 6.0, Sweeper.hours(nil)
      assert_equal 6.0, Sweeper.hours("")
      assert_equal 6.0, Sweeper.hours("  ")
      assert_equal 0.5, Sweeper.hours("0.5")
      assert_equal 12.0, Sweeper.hours("12")

      variable = Sweeper::AFTER_VARIABLE
      begin
        ENV[variable] = "1"
        assert_equal 1.0, Sweeper.new(client: SweepFakeClient.new, log: StringIO.new, now: NOW).hours
      ensure
        ENV.delete(variable)
      end
    end

    def test_a_cutoff_that_is_not_a_positive_number_of_hours_refuses
      [ "six", "0", "-2", "NaN", "Infinity", [ 6 ] ].each do |value|
        error = assert_raises(RubyCdk::PreconditionError) { Sweeper.hours(value) }

        assert_includes error.message, Sweeper::AFTER_VARIABLE
        assert_includes error.message, "Nothing was deleted"
      end
    end

    def test_the_hours_option_moves_the_cutoff
      client = SweepFakeClient.new.stack("ruby-cdk-it-recent", created: NOW - (2 * 3600), tags: TAG, after: nil)

      result = sweep(client, hours: 1)

      assert_equal [ "ruby-cdk-it-recent" ], result.deleted.map(&:name), "two hours is old when the sweep is told one"
      refute result.leftover?
    end

    def test_the_report_names_the_protocol_and_the_what_of_every_stack
      buffer = StringIO.new
      client = SweepFakeClient.new
        .stack("ruby-cdk-it-old", created: TEN_HOURS_AGO, tags: TAG, after: nil)
        .stack("ruby-cdk-it-young", created: ONE_HOUR_AGO, tags: TAG)

      Sweeper.new(client: client, log: buffer, now: NOW).run

      report = buffer.string
      assert_includes report, "ruby-cdk-it-"
      assert_includes report, "#{Sweeper::TAG_KEY}=#{Sweeper::TAG_VALUE}"
      assert_includes report, "older than 6.0h"
      assert_includes report, "delete asked for ruby-cdk-it-old"
      assert_includes report, "kept ruby-cdk-it-young"
    end

    def test_a_clean_pass_reports_nothing_left_behind
      buffer = StringIO.new
      client = SweepFakeClient.new.stack("ruby-cdk-it-lambda", created: TEN_HOURS_AGO, tags: TAG, after: nil)

      Sweeper.new(client: client, log: buffer, now: NOW).run

      assert_includes buffer.string, "nothing left behind"
    end
  end
end
