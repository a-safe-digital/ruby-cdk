# frozen_string_literal: true

require_relative "errors"

module RubyCdk
  # A value computed once, when its stack is resolved. Resolution happens after
  # the tree is complete, so a Lazy can refer to a resource defined later than
  # itself.
  class Lazy
    MAX_DEPTH = 10

    # A chain of Lazy values that leads back to itself, or that is deeper than MAX_DEPTH.
    class ChainError < Error; end

    def initialize(&block)
      raise ArgumentError, "Lazy needs a block" unless block

      @block = block
      @state = :pending
      @value = nil
    end

    # Evaluates the block with the stack. A chain of Lazy values is followed up
    # to MAX_DEPTH levels, so that a cycle is an error and not a hang.
    def resolve(stack)
      evaluate(stack, 0)
    end

    # True once the block has run.
    def resolved?
      @state == :resolved
    end

    private

    def evaluate(stack, depth)
      return @value if @state == :resolved

      raise ChainError, "A chain of Lazy values leads back to itself" if @state == :resolving
      raise ChainError, "A chain of Lazy values deeper than #{MAX_DEPTH} levels" if depth > MAX_DEPTH

      @state = :resolving
      begin
        value = @block.call(stack)
        value = value.send(:evaluate, stack, depth + 1) if value.is_a?(Lazy)
      rescue Exception
        @state = :pending
        raise
      end
      @value = value
      @state = :resolved
      @value
    end
  end
end
