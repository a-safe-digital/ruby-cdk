# frozen_string_literal: true

# The curated L2 constructs (architecture section 3): one class per service,
# directly under RubyCdk, each building its L1 resources through
# Construct#resource, under the logical ID derivation of architecture section 3,
# so that a construct can be used twice in one stack.
#
#   RubyCdk::S3::Bucket, RubyCdk::IAM::Role, RubyCdk::Lambda::Function,
#   RubyCdk::DynamoDB::Table, RubyCdk::SQS::Queue, RubyCdk::SNS::Topic,
#   RubyCdk::Logs::LogGroup
#
# The sources behind the defaults were read in aws/aws-cdk at commit
# c070afb54b9e4dbddd52a85a21077fe970354985 (main, read on 2026-11-25,
# Apache-2.0); each construct file names the file it was read from.
#
# Two rules the whole directory shares:
#
#   - Building is immediate (architecture section 3): every L1 resource a
#     construct owns is registered in the tree while its constructor runs.
#     Values that grow after the resource exists - the statements of a role's
#     policy, managed policy ARNs added later - sit behind a Lazy, which
#     synthesis resolves once.
#   - A grant_* method answers a Constructs::Grant and, when the principal can
#     carry one, applies it: Grant.add_to_principal is the port of the CDK's
#     iam.Grant.addToPrincipal (aws-iam/lib/grant.ts, addToPrincipal), whose
#     statement lands in the principal's own policy through the grantee's
#     grantPrincipal (Role.grantPrincipal is the role itself, role.ts:462) and
#     its addToPrincipalPolicy (role.ts:653), which creates the DefaultPolicy
#     resource. This tool grants to identities only, so there is no resource
#     policy here and no Lambda::Permission: a grant never broadens a
#     resource's own policy.
#
# Anything where the CDK does differently from the safe defaults of
# architecture section 7 is decided for section 7 and listed in architecture
# section 21; each construct file states its own choices.

require_relative "errors"
require_relative "values"
require_relative "core"
require_relative "cfn"

module RubyCdk
  # What the curated constructs share: the Grant a grant_* method answers.
  module Constructs
  end
end

require_relative "constructs/policy_statement"
require_relative "constructs/grant"
require_relative "constructs/role"
require_relative "constructs/bucket"
require_relative "constructs/log_group"
require_relative "constructs/function"
require_relative "constructs/table"
require_relative "constructs/queue"
require_relative "constructs/topic"
