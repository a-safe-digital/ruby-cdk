# frozen_string_literal: true

# Ported from the AWS CDK.
#
#   Origin: packages/aws-cdk-lib/matching/lib/private/sparse-matrix.ts
#   Commit: 025a6f67fec3d37a6ffdc6168f8a751a04918f66 (aws/aws-cdk, main)
#   Licence: Apache-2.0
#   Changed: nothing in behaviour. A Hash of Hashes stands for the Map of Maps,
#   and a row is a list of [ column, value ] pairs.

module RubyCdk
  module Test
    module Private
      # Values set at a few [ row, column ] positions of a grid.
      class SparseMatrix
        def initialize
          @matrix = {}
        end

        def get(row, column)
          @matrix[row]&.[](column)
        end

        # [ column, value ] pairs of a row, in the order they were set. Empty when none was.
        def row(row)
          (@matrix[row] || {}).to_a
        end

        def set(row, column, value)
          (@matrix[row] ||= {})[column] = value
        end
      end
    end
  end
end
