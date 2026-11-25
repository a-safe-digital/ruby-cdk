# frozen_string_literal: true

# The gem is on the load path by the time this file is read: `rake sweep`
# requires the gem first, and the suite's test_helper does too. The errors are
# the gem's.

module Integration
  # The sweeper of WF-5 rule 6 (docs/06-workflows.md): the integration stacks
  # older than six hours that a crashed run left behind are deleted, matched by
  # the prefix `ruby-cdk-it-` and the tag `ruby-cdk-integration=true`, and the
  # physical IDs of everything the prefix still names afterwards are reported,
  # for a person to decide about. Nothing here ever deletes a physical resource
  # by hand (WF-5 rule 6): a stack is deleted whole, through CloudFormation,
  # which deletes its resources with it, and a resource CloudFormation skipped
  # is reported, never touched.
  #
  # Everything goes through the CloudFormation port, so a fake drives the tests
  # (test/unit/integration/sweeper_test.rb) and `rake sweep` drives the real
  # adapter. The port carries no creation time, so a stack's age goes through
  # the port as well: the timestamp of its oldest event, which is its creation.
  # A stack of which no event can be read is never deleted — its age is not
  # known, and the report leaves it to a person.
  #
  # One pass of this class is: list, match, ask for the old ones to be deleted,
  # then list again and report what remains. A deletion CloudFormation is
  # still carrying out is reported as in flight and does not fail the sweep;
  # it ends on its own, and the next sweep sees the result.
  class Sweeper
    # WF-5 rule 3: the prefix every integration stack is named with, and the
    # tag every one carries. Both must match before a stack is deleted: the
    # prefix alone is not proof, and `ruby-cdk-bootstrap` never matches.
    PREFIX = "ruby-cdk-it-"
    TAG_KEY = "ruby-cdk-integration"
    TAG_VALUE = "true"

    # Six hours, as WF-5 rule 6 says. AFTER_VARIABLE names the variable that
    # overrides it, in hours: RUBY_CDK_SWEEP_AFTER=<hours>.
    DEFAULT_HOURS = 6.0
    AFTER_VARIABLE = "RUBY_CDK_SWEEP_AFTER"

    # What CloudFormation answers while it carries out a deletion, and for a
    # resource it deleted.
    DELETING = "DELETE_IN_PROGRESS"
    DELETED = "DELETE_COMPLETE"

    # What the pass decided about one matched stack, before the final listing
    # is read. kind is one of :no_id, :untagged, :unknown_age, :delete_asked,
    # :delete_failed, :kept.
    Fate = Struct.new(:name, :id, :status, :kind, :reason, :age_hours, keyword_init: true)

    # One stack the prefix still names after the pass. failure is true when a
    # person has to decide something: a kept one (too young) and one whose
    # deletion is still in flight are not failures. physical_ids are the
    # resources of the stack that are not deleted, as "logical (physical)".
    Remaining = Struct.new(:name, :id, :status, :reason, :failure, :physical_ids, keyword_init: true)

    DeletedStack = Struct.new(:name, :id, keyword_init: true)
    FailedDeletion = Struct.new(:name, :id, :reason, keyword_init: true)
    KeptStack = Struct.new(:name, :id, :age_hours, keyword_init: true)

    # What one run did, for `rake sweep` to exit on.
    Result = Struct.new(:deleted, :kept, :failed_deletions, :remaining, keyword_init: true) do
      # True when something remains that needs a person.
      def leftover?
        remaining.any?(&:failure)
      end
    end

    attr_reader :client, :log, :hours

    # client is the CloudFormation port: the adapter behind `Deploy::Sdk`, or a
    # fake in the tests. log is where the report goes: standard output in a
    # run, a buffer in a test. now pins the clock of the whole pass, so a test
    # is not timing's hostage; hours overrides the age after which a stack is
    # swept, and nil reads AFTER_VARIABLE, falling back to six hours.
    def initialize(client:, log: $stdout, now: nil, hours: nil)
      @client = client
      @log = log
      @now = now
      @hours = hours.nil? ? self.class.hours(ENV[AFTER_VARIABLE]) : self.class.hours(hours)
    end

    # The age after which a stack is swept, in hours, read once. nil and blank
    # mean the default. A value that is not a positive, finite number refuses
    # the run rather than falling back in silence: a typo in
    # RUBY_CDK_SWEEP_AFTER must not mean "sweep everything now".
    def self.hours(value)
      return DEFAULT_HOURS if value.nil? || (value.respond_to?(:strip) && value.strip.empty?)

      begin
        hours = Float(value)
      rescue ArgumentError, TypeError
        raise RubyCdk::PreconditionError, "#{AFTER_VARIABLE} is #{value.inspect}, which is not a number of hours. " \
          "Nothing was deleted. Set it to a positive number, such as #{AFTER_VARIABLE}=12, or unset it for the default of #{DEFAULT_HOURS}."
      end
      raise RubyCdk::PreconditionError, positive_hours_message(value) unless hours.finite? && hours.positive?

      hours
    end

    def self.positive_hours_message(value)
      "#{AFTER_VARIABLE} is #{value.inspect}, which is not a positive number of hours. Nothing was deleted. " \
        "Set it to a positive number, such as #{AFTER_VARIABLE}=12, or unset it for the default of #{DEFAULT_HOURS}."
    end

    # One pass. See the class comment for its shape.
    def run
      now = @now || Time.now
      cutoff = now - (@hours * 3600)
      result = Result.new(deleted: [], kept: [], failed_deletions: [], remaining: [])
      decided = {}

      each_matched do |name|
        info = client.stack_info(name)
        next if info.nil? # it is gone between the listing and the ask

        fate = decide(name, info, cutoff, now, result)
        decided[fate.name] = fate
      end

      result.kept = decided.values.select { |fate| fate.kind == :kept }
        .map { |fate| KeptStack.new(name: fate.name, id: fate.id, age_hours: fate.age_hours) }
      result.remaining = report_remaining(decided)
      print_report(result, now)
      result
    end

    private

    # The stacks with the prefix, one name at a time. The port lists every
    # stack that is not deleted; the prefix is this sweeper's to apply, as the
    # runner applies it, and nothing the prefix does not name is touched.
    def each_matched
      Array(client.list_stacks).map { |stack| field(stack, :name) }.compact.each do |name|
        yield name if name.start_with?(PREFIX)
      end
    end

    # What becomes of one matched stack: nothing it is not proven old enough
    # to be, deleted only when the prefix, the tag and the age all say so.
    def decide(name, info, cutoff, now, result)
      id = field(info, :id)
      return Fate.new(name: name, id: nil, status: field(info, :status), kind: :no_id,
        reason: "its ID could not be read, so it can neither be deleted nor listed by it") if id.nil?

      unless tagged?(name)
        return Fate.new(name: name, id: id, status: field(info, :status), kind: :untagged,
          reason: "it carries the prefix but not the tag #{TAG_KEY}=#{TAG_VALUE}, so it is not known to be an integration stack")
      end

      created = created_at(id)
      if created.nil?
        return Fate.new(name: name, id: id, status: field(info, :status), kind: :unknown_age,
          reason: "no event could be read for it, so its age is not known, and nothing is deleted on a guess")
      end

      return Fate.new(name: name, id: id, status: field(info, :status), kind: :kept,
        reason: "#{((now - created) / 3600.0).round(1)}h old, younger than #{@hours}h",
        age_hours: (now - created) / 3600.0) if created >= cutoff

      deleted = Fate.new(name: name, id: id, status: nil, kind: :delete_asked)
      begin
        client.delete_stack(id) # the ID was read first, as WF-5 rule 5 asks
        result.deleted << DeletedStack.new(name: name, id: id)
      rescue StandardError => e
        deleted.kind = :delete_failed
        deleted.reason = "its deletion failed: #{e.message}"
        result.failed_deletions << FailedDeletion.new(name: name, id: id, reason: e.message)
      end
      deleted
    end

    # True when the stack carries the integration tag with the value the
    # protocol fixed. The tags arrive as { key:, value: }.
    def tagged?(name)
      Array(client.stack_tags(name)).any? do |pair|
        field(pair, :key) == TAG_KEY && field(pair, :value) == TAG_VALUE
      end
    end

    # The moment the stack was created: the timestamp of its oldest event.
    # nil when none can be read.
    def created_at(id)
      Array(client.events(id, after: Time.at(0)))
        .filter_map { |event| field(event, :timestamp) }.min
    end

    # The final listing: everything the prefix still names, whatever became of
    # it in the pass, each with the physical IDs of its resources that are not
    # deleted. decided is what the pass concluded, by name; a stack it did not
    # decide about appeared while it ran.
    def report_remaining(decided)
      Array(client.list_stacks).filter_map do |stack|
        name = field(stack, :name)
        next unless name&.start_with?(PREFIX)

        id = field(stack, :id)
        status = field(stack, :status)
        fate = decided[name]
        record =
          if fate.nil?
            [ status, "it appeared while the sweep ran; a run is in flight, and a person decides", true ]
          elsif fate.kind == :kept
            [ status, "#{fate.reason} — kept", false ]
          elsif fate.kind == :delete_asked
            if status == DELETING
              [ status, "this sweep asked for its deletion and CloudFormation is carrying it out; the next sweep sees the result", false ]
            else
              [ status, "this sweep asked for its deletion, but it is still listed as #{status.inspect}", true ]
            end
          else
            [ status || fate.status, fate.reason, true ]
          end

        Remaining.new(name: name, id: id, status: record[0], reason: record[1], failure: record[2],
          physical_ids: physical_ids_of(id))
      end
    end

    # What CloudFormation did not delete, by its physical ID. A listing that
    # cannot be read is noted, not raised: the report is the product here.
    def physical_ids_of(id)
      return [] if id.nil?

      Array(client.list_resources(id))
        .reject { |resource| field(resource, :status) == DELETED }
        .map { |resource| "#{field(resource, :logical_id)} (#{field(resource, :physical_id)})" }
    rescue StandardError => e
      [ "its resources could not be listed (#{e.message})" ]
    end

    # The port's answers arrive as Structs or as plain Hashes, and whether
    # they are read by a key or by a method is the adapter's to settle, as the
    # runner's field read says.
    def field(object, name)
      if object.respond_to?(:[])
        object[name] || object[name.to_s]
      else
        object.public_send(name)
      end
    end

    # The report, in the order a person reads it: what went, what was kept,
    # what refused, what remains.
    def print_report(result, now)
      cutoff = now - (@hours * 3600)
      log.puts "sweep: stacks named #{PREFIX}…, tagged #{TAG_KEY}=#{TAG_VALUE}, created before #{cutoff.utc.iso8601} " \
        "(older than #{@hours}h)"
      result.deleted.each { |gone| log.puts "sweep: delete asked for #{gone.name} (#{gone.id})" }
      result.kept.each do |kept|
        log.puts "sweep: kept #{kept.name} (#{kept.id}): #{kept.age_hours.round(1)}h old, younger than #{@hours}h"
      end
      result.failed_deletions.each do |failure|
        log.puts "sweep: the deletion of #{failure.name} (#{failure.id}) failed: #{failure.reason}"
      end

      if result.remaining.empty?
        log.puts "sweep: nothing left behind"
      else
        result.remaining.each do |left|
          log.puts "sweep: #{left.failure ? "left behind" : "in flight"}: #{left.name} (#{left.id}, #{left.status.inspect}): #{left.reason}"
          left.physical_ids.each { |physical| log.puts "sweep:   #{physical}" }
        end
        failures = result.remaining.count(&:failure)
        log.puts "sweep: #{failures} stack(s) left behind need a person; nothing deletes a physical resource by hand (WF-5)"
      end
    end
  end
end
