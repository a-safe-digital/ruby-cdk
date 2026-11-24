# frozen_string_literal: true

require "json"
require "stringio"
require "fileutils"
require "tmpdir"
require "ruby_cdk/cli"
require "ruby_cdk/deploy/fakes"
require "support/assets_fake_store"

# Shared by the tests of the command line. Everything runs in process: the
# command line is asked for its exit code (`CLI.run`), never to exit, and the
# one object that builds AWS clients is replaced by a fake before any command
# that could need one runs. No test builds a client.
module CliHelpers
  ACCOUNT = "111122223333"
  REGION = "eu-west-1"
  TARGET = RubyCdk::Env.new(account: ACCOUNT, region: REGION)

  # What the adapters answer for one region, as the contract has it.
  Clients = Data.define(:cfn, :store)

  # The object that builds clients, replaced. It answers what the test chose
  # and keeps what it was asked. cfn and store are the engine's own fakes, so
  # that the deploy goes through the whole engine with no AWS behind it.
  class FakeAws
    attr_reader :cfn, :store, :region_calls, :client_calls

    # region is what a stack with no env and no --region resolves to.
    def initialize(region: REGION, cfn: nil, store: nil)
      @region = region
      @cfn = cfn || RubyCdk::Deploy::Fakes::CfnClient.new
      @store = store || RubyCdk::Deploy::Fakes::ObjectStore.new
      @region_calls = []
      @client_calls = []
      @region_error = nil
    end

    # The next region question raises this, as the adapters do when nothing names a region.
    def fail_region_with(error)
      @region_error = error
      self
    end

    def region(profile:, region:)
      @region_calls << [ profile, region ]
      raise @region_error if @region_error

      @region
    end

    def clients(profile:, region:)
      @client_calls << [ profile, region ]
      Clients.new(cfn: @cfn, store: @store)
    end
  end

  # For a command that must never ask for a client: synth, ls, version.
  class NoAws
    class Asked < StandardError; end

    def region(**)
      raise Asked, "the command asked the adapters for a region"
    end

    def clients(**)
      raise Asked, "the command asked the adapters for clients"
    end
  end

  # Standard out that is a terminal, for the colour rule.
  class Terminal < StringIO
    def tty?
      true
    end
  end

  class TestCase < Minitest::Test
    # What one run answered: the exit code and the two streams.
    Result = Data.define(:code, :out, :err) do
      # With --json, one object per line of standard out.
      def records
        out.string.lines.map { |line| JSON.parse(line) }
      end
    end

    # An app of one stack without env, which goes wherever the credentials point.
    ONE_STACK = <<~RUBY
      require "ruby-cdk"
      RubyCdk::App.new do |app|
        RubyCdk::Stack.new(app, "hello") do
          resource("Queue", "AWS::SQS::Queue")
        end
      end
    RUBY

    def setup
      RubyCdk::App.reset!
      @dir = Dir.mktmpdir("ruby-cdk-cli")
    end

    def teardown
      RubyCdk::App.reset!
      FileUtils.remove_entry(@dir)
    end

    attr_reader :dir

    # Writes an app file into the test's directory, and the directories of its path.
    def write_app(body, name = "cdk.rb")
      path = File.join(@dir, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, body)
      name
    end

    # Runs the command line in process, from the test's directory. aws is what
    # builds the clients; terminal makes standard out a terminal, so that
    # colour is allowed unless the options say otherwise. Never exits.
    #
    # Not named run: that is the method Minitest itself calls to run a test.
    def cli(*words, aws: NoAws.new, terminal: false)
      out = terminal ? Terminal.new : StringIO.new
      err = StringIO.new
      io = RubyCdk::Cli::Io.new(out:, err:, stdin: StringIO.new)
      code = Dir.chdir(@dir) { RubyCdk::CLI.run(words.map(&:to_s), io:, aws:) }
      Result.new(code:, out:, err:)
    end

    # `--yes` for a stack without env needs --account (architecture section 13).
    def unattended
      [ "--yes", "--account", CliHelpers::ACCOUNT ]
    end
  end
end
