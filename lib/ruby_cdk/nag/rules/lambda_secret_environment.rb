# frozen_string_literal: true

require_relative "../rule"

module RubyCdk
  module Nag
    module Rules
      # RC-LAMBDA-002. A function is compliant when no environment variable
      # whose name looks like a secret holds a value that is written out in
      # the template. A variable that takes its value from somewhere else, a
      # Ref or an intrinsic, is not evaluated: the rule cannot see it.
      #
      # No rule of cdk-nag (da5bed77c1b08e584e3de2d67534c76871af957f) and
      # none of cfn-nag (8b5f03da74202ba323a145e9d037ddce6cab9dec) reads a
      # function's environment, so the rule is the wave card's own. From cfn-nag
      # (MIT, Copyright (c) 2016-2021 Stelligent), lib/cfn-nag/util/
      # enforce_string_or_dynamic_reference.rb, it ports the one kind of string
      # that is not a literal in the clear: a dynamic reference to Secrets
      # Manager or to a secure SSM parameter.
      #
      # What changed: cfn-nag's PasswordBaseRule, which uses that helper, also
      # follows a Ref into the Parameters section, to report a parameter whose
      # Default holds the secret. That is not ported: here every intrinsic is
      # dynamic and is counted as not evaluated, as the wave card decides for
      # the whole rule pack.
      class LambdaSecretEnvironment < Rule
        id "RC-LAMBDA-002"
        description "Lambda environment holds no literal value in a variable named like a secret"
        severity :high
        applies_to "AWS::Lambda::Function"

        VARIABLES = "Properties.Environment.Variables"

        # The words the wave card names, anywhere in the variable's name.
        SECRET_NAME = /KEY|SECRET|PASSWORD|TOKEN|CREDENTIAL/i

        def audit
          v = values
          check(VARIABLES) { v.keys(VARIABLES) }.to_a.each do |name|
            audit_variable(name) if SECRET_NAME.match?(name)
          end
        end

        private

        def audit_variable(name)
          v = values
          path = v.full_path("#{VARIABLES}.#{name}")
          check(path) do
            value = v.entry(VARIABLES, name)
            next if Values.secret_dynamic_reference?(value)

            violate(path,
              "is named like a secret and its value is written in the template: pass it from Secrets Manager " \
              "or from a secure SSM parameter instead")
          end
        end
      end
    end
  end
end
