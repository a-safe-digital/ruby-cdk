# frozen_string_literal: true

# The gem is on the load path by the time this file is read: `rake
# integration` loads it first, and the suite's test_helper does too. The
# errors and the env are the gem's.

module Integration
  # The guard of WF-5 (docs/06-workflows.md): the safety protocol of the only
  # place in the repository that ever calls AWS. It refuses before any request
  # unless all three variables of the protocol name a value, then resolves who
  # the credentials are through the CloudFormation port, and refuses unless the
  # account and the region both are the ones the owner allowlisted. Nothing is
  # created before it has said yes, and everything that runs after it is also
  # under the engine's own account check (architecture §13), because every
  # integration stack carries an env (see env).
  #
  # Everything here goes through the port, so a test gives it a fake and no
  # client is ever built.
  class Guard
    # Exit 1: the run is refused, before any request.
    class Refused < RubyCdk::PreconditionError; end

    VARIABLES = %w[RUBY_CDK_AWS_PROFILE RUBY_CDK_ALLOW_ACCOUNT RUBY_CDK_ALLOW_REGION].freeze

    attr_reader :profile, :allow_account, :allow_region, :identity

    # port is the CloudFormation port: the adapter behind `Deploy::Sdk`, or a
    # fake in the tests. variables is where the three names are read from, ENV
    # in a run and a Hash in a test.
    def initialize(port:, variables: ENV)
      missing = VARIABLES.select { |name| variables[name].to_s.strip.empty? }
      unless missing.empty?
        raise Refused, "The integration run needs #{missing.join(", ")} in the environment, and none of the three may " \
          "be blank. They name the sandbox the owner approved for this wave, and they never enter the repository (WF-5): " \
          "set them in the shell that runs `rake integration`."
      end

      @profile = variables["RUBY_CDK_AWS_PROFILE"]
      @allow_account = variables["RUBY_CDK_ALLOW_ACCOUNT"]
      @allow_region = variables["RUBY_CDK_ALLOW_REGION"]

      @identity = port.resolve_identity
      unless @identity.account == @allow_account
        raise Refused, "The credentials of profile #{@profile} are for account #{@identity.account}, but " \
          "RUBY_CDK_ALLOW_ACCOUNT names #{@allow_account}. The run stops before anything is created. " \
          "Log in to the profile you meant, or correct the variable."
      end
      unless @identity.region == @allow_region
        raise Refused, "The client of profile #{@profile} is for region #{@identity.region}, but " \
          "RUBY_CDK_ALLOW_REGION names #{@allow_region}. The run stops before anything is created. " \
          "Correct the variable, or pass --region #{@allow_region}."
      end
    end

    # The env every integration stack is built with, so that the engine's own
    # account check (architecture §13) applies on top of this one.
    def env
      @env ||= RubyCdk::Env.new(account: @allow_account, region: @allow_region)
    end

    # What a run says about its target, for the log and for the evidence of the
    # pull request. The account ID is an identifier, not a credential (D-027).
    def to_s
      "integration target: account #{identity.account}, region #{identity.region}, profile #{profile}"
    end
  end
end
