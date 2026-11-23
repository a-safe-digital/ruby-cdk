# frozen_string_literal: true

# Thresholds that the test suite and the Rakefile share.
module Tools
  # Percent of lines under lib/ and exe/ that the tests must execute.
  # It rises as waves land: 85 now, 90 at the 0.1.0 gate.
  COVERAGE_LINE_FLOOR = 85
end
