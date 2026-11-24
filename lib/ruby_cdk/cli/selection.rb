# frozen_string_literal: true

require "json"
require_relative "failure"
require_relative "pairs"

module RubyCdk
  module Cli
    # Which stacks a command acts on, and in what order. The CDK's rules, read
    # in aws/aws-cdk-cli at eca1b73d682d7763955bec30ab5dd52bbc4327b6:
    #
    # - No name is the app's only stack when the app has exactly one, and a
    #   usage error otherwise, in the CDK's words. It is `explicitOrDefaultStacks`
    #   with `StackSelectionStrategy.ONLY_SINGLE` (packages/aws-cdk/lib/cli/cli.ts:800-819)
    #   and the message of `multipleStacksWithoutSelectorMessage`
    #   (packages/@aws-cdk/toolkit-lib/lib/api/cloud-assembly/private/stack-assembly.ts:386-404).
    # - `--all` is every stack, and `--all` with names is an error (cli.ts:292-294).
    # - A deploy brings the dependencies of the stacks it names, and a destroy
    #   the stacks that depend on them, unless `--exclusively` (cli.ts:821-839).
    #   A deploy goes dependencies first, a destroy dependents first.
    #
    # Two things are decided here against the CDK, and recorded with the reason:
    #
    # - Names are exact. The CDK also takes globs and `!` patterns; they are not
    #   ported in this wave, and a stack's name is known (`ruby-cdk ls`).
    # - A name that is no stack's is always an error. For a deploy that is the
    #   CDK's own `PATTERN_MUST_MATCH` (stack-assembly.ts:184-190). For a destroy
    #   the CDK treats a pattern that matches nothing as nothing to do
    #   (cli.ts:607-608); here it is an error too, because an exit code of 0
    #   after a mistyped name would tell a script that the stack is gone. The
    #   same for a name among others that do match, where the CDK deploys the
    #   ones that match and says nothing of the rest.
    #
    # A circle of dependencies never reaches this module: the tree refuses one
    # as it is built. The check below stays, as a backstop that names the circle.
    module Selection
      # The stacks a command acts on, among stacks, from the names it was given
      # and --all, in the order the app holds them. Raises Cli::Usage. command is
      # "deploy" or "destroy", for the line that says what to run next.
      def self.choose(stacks, names:, all:, command:)
        names = names.compact
        if names.any? && all
          Kernel.raise Usage.new("You must either specify a list of Stacks or the `--all` argument",
            next_step: "Run `ruby-cdk #{command} #{names.join(" ")}`, or `ruby-cdk #{command} --all`.")
        end
        return stacks.dup if all

        if names.empty?
          unless stacks.one?
            Kernel.raise Usage.new(no_single(stacks),
              next_step: "Run `ruby-cdk #{command} --all`, or `ruby-cdk #{command} STACK` for one of them.")
          end

          return stacks.dup
        end

        missing = names.uniq - stacks.map(&:stack_name)
        unless missing.empty?
          Kernel.raise Usage.new("No stacks match the name(s) #{missing.join(", ")}",
            next_step: "Run `ruby-cdk ls` to see the stacks of the app, then `ruby-cdk #{command} STACK`.")
        end
        stacks.select { |stack| names.include?(stack.stack_name) }
      end

      # The entries to act on: the selected stacks, with what they need and in
      # the order that works. direction is :up for a deploy, which needs a
      # stack's dependencies first, and :down for a destroy, which needs the
      # stacks that depend on it first. exclusively leaves the others alone.
      def self.ordered(entries, selected:, direction:, exclusively:)
        needed = exclusively ? selected.dup : closure(entries, selected, direction)
        sorted = dependencies_first(entries)
        sorted.reverse! if direction == :down
        sorted.select { |entry| needed.include?(entry.name) }
      end

      # The CDK's message when no stack was named and the app has more than one,
      # without the part about wildcards: they are not ported.
      def self.no_single(stacks)
        return "This app contains no stacks" if stacks.empty?

        "Since this app includes more than a single stack, specify which stacks to use or specify `--all`\n" \
          "Stacks: #{stacks.map(&:stack_name).join(" · ")}"
      end

      # Every entry, each after the ones it depends on. Raises Cli::Usage when
      # the dependencies form a circle, naming it.
      def self.dependencies_first(entries)
        by_name = entries.to_h { |entry| [ entry.name, entry ] }
        placed = {}
        order = []
        entries.each { |entry| place(entry.name, [], by_name, placed, order) }
        order
      end

      # The walk behind dependencies_first. trail is the stack's path here, so
      # that a circle is named by the road that led to it.
      def self.place(name, trail, by_name, placed, order)
        if trail.include?(name)
          Kernel.raise Usage, "The stacks depend on each other in a circle: #{(trail + [ name ]).join(" -> ")}"
        end
        entry = by_name[name]
        return if entry.nil? || placed[name]

        placed[name] = true
        Array(entry.dependencies).each { |dependency| place(dependency, trail + [ name ], by_name, placed, order) }
        order << entry
      end
      private_class_method :place

      # The names of the selected stacks and of everything they need in direction.
      def self.closure(entries, selected, direction)
        edges =
          if direction == :up
            entries.to_h { |entry| [ entry.name, entry.dependencies ] }
          else
            dependents = Hash.new { |hash, key| hash[key] = [] }
            entries.each { |entry| Array(entry.dependencies).each { |dependency| dependents[dependency] << entry.name } }
            dependents
          end

        needed = {}
        frontier = selected.dup
        until frontier.empty?
          name = frontier.pop
          next if needed[name]

          needed[name] = true
          frontier.concat(Array(edges[name]))
        end
        needed.keys
      end
    end
  end
end
