# frozen_string_literal: true

require "json"

module RubyCdk
  module Diff
    # The diff, as text for a person. What is printed is the CDK's
    # formatDifferences (cloudformation-diff, lib/format.ts at eca1b73d):
    # the stack's name, then the sections in its order -- the template's own
    # attributes, the security tables, Parameters, Metadata, Mappings,
    # Conditions, Resources with the property changes under each resource, and
    # Outputs, with anything else under Other Changes. A resource carries one
    # of the markers [+], [-] and [~], the words "replace", "may be replaced",
    # "destroy" and "orphan" for what happens to it, and a line per changed
    # property path with the values on both sides.
    #
    # Two departures from the CDK, both recorded (architecture section 21):
    # its tables are drawn with unicode box characters and colour; this
    # rendering is plain text, so that a golden test can hold it and a pipe
    # carries it whole. And it does not print the CDK's warning that its
    # security view may miss changes, because this one reads every property a
    # template carries policy statements in and misses none.
    module Render
      module_function

      # The text of one stack's diff. quiet leaves out the stack's name and
      # the nothing-to-do lines, as the CDK's --quiet does; security_only
      # shows the security view alone, as its --security-only does.
      def call(diff, quiet: false, security_only: false)
        lines = [ header(diff, quiet, security_only) ]
        lines.concat(security_only ? security_only_view(diff, quiet) : full_view(diff, quiet))
        lines.compact.join("\n").chomp
      end

      # The stack's name, printed whenever there is something to read, even
      # under --quiet with changes, and even over an empty diff without quiet
      # -- the CDK's rule (stackName && (!options.quiet || !diff.isEmpty)).
      def header(diff, quiet, security_only)
        changed = security_only ? diff.security.has_changes? : !diff.empty?
        return nil if diff.stack_name.nil? || (quiet && !changed)

        "Stack #{diff.stack_name}"
      end

      def full_view(diff, quiet)
        return [] if quiet && diff.empty?
        return [ NO_CHANGES ] if diff.empty?

        [ *template_section(diff), *security_section(diff), *simple_sections(diff), *resources_section(diff) ]
      end

      def security_only_view(diff, quiet)
        return [] if quiet && !diff.security.has_changes?
        return [ NO_SECURITY_CHANGES ] unless diff.security.has_changes?

        [ *warning(diff.security.broadening?), *tables(diff.security) ]
      end

      def template_section(diff)
        lines = []
        lines << value_line(diff.format_version, "AWSTemplateFormatVersion") if diff.format_version
        lines << value_line(diff.transform, "Transform") if diff.transform
        lines << value_line(diff.description, "Description") if diff.description
        section("Template", lines)
      end

      # The security view: the warning when the deployment broadens what the
      # deployed template may do, then the statement table, then the managed
      # policy table, then the capabilities that appeared.
      def security_section(diff)
        security = diff.security
        return [] unless security.has_changes?

        [ *warning(security.broadening?), *tables(security), "" ]
      end

      def warning(broadening)
        return [] unless broadening

        [ "This deployment will make potentially sensitive changes according to your current security approval level.",
          "Please confirm you intend to make the following modifications:" ]
      end

      def tables(security)
        lines = []
        if security.statement_additions.any? || security.statement_removals.any?
          rows = security.statement_additions.map { |statement| row("+", statement) } +
            security.statement_removals.map { |statement| row("-", statement) }
          rows.sort_by! { |cells| cells[1].to_s }
          lines << "IAM Statement Changes"
          lines.concat(table([ "", "Resource", "Effect", "Action", "Principal", "Condition" ], rows))
          lines << ""
        end
        if security.managed_policy_additions.any? || security.managed_policy_removals.any?
          rows = security.managed_policy_additions.map { |attachment| [ "+", attachment.identity, attachment.arn ] } +
            security.managed_policy_removals.map { |attachment| [ "-", attachment.identity, attachment.arn ] }
          rows.sort_by! { |cells| cells[1].to_s }
          lines << "IAM Policy Changes"
          lines.concat(table([ "", "Resource", "Managed Policy ARN" ], rows))
          lines << ""
        end
        if security.capabilities_added.any?
          reason = if security.capabilities_added.include?("CAPABILITY_NAMED_IAM")
            "the new template creates IAM resources, some with explicit names"
          else
            "the new template creates IAM resources"
          end
          lines << "New capabilities needed: #{security.capabilities_added.join(", ")}, because #{reason}."
        end
        lines
      end

      # One row of the statement table, the CDK's summarizeStatements: the
      # marker, then what the statement says, rendered for a person.
      def row(marker, statement)
        rendered = statement.render
        [ marker, rendered[:resource], rendered[:effect], rendered[:action], rendered[:principal], rendered[:condition] ]
      end

      def simple_sections(diff)
        lines = []
        {
          "Parameters" => "Parameter",
          "Metadata" => "Metadata",
          "Mappings" => "Mapping",
          "Conditions" => "Condition",
          "Outputs" => "Output"
        }.each do |title, entry_type|
          entries = diff.sections[title]
          next if entries.empty?

          lines.concat(section(title, entries.map { |name, difference| value_line(difference, entry_type, name) }))
        end
        lines.concat(section("Other Changes", diff.unknown.map { |key, difference| value_line(difference, "Unknown", key) }))
        lines
      end

      def resources_section(diff)
        changes = diff.changes
        return [] if changes.empty?

        lines = [ "Resources" ]
        changes.each do |change|
          lines << resource_line(change)
          lines.concat(property_lines(change.properties))
        end
        lines << ""
        lines
      end

      # A titled section, printed only when it has lines to show, closed by an
      # empty line as the CDK's printSectionFooter is.
      def section(title, lines)
        return [] if lines.empty?

        [ title, *lines, "" ]
      end

      # `[~] AWS::S3::Bucket Bucket replace` -- the marker, the type, the
      # logical ID, and what happens to the resource when it is more than an
      # update.
      def resource_line(change)
        parts = [ "[#{marker_for(change)}] #{change.old_type || change.new_type} #{change.logical_id}" ]
        parts << change.word if change.word
        parts.join(" ")
      end

      def marker_for(change)
        return "-" if change.removal?
        return "+" if change.addition?
        return "+" if change.import?

        "~"
      end

      # One line per changed property path, values on both sides under it. The
      # last property closes its tree with └─, the others with ├─.
      def property_lines(properties)
        properties.each_with_index.flat_map do |property, index|
          last = index == properties.length - 1
          branch = last ? "└" : "├"
          stem = last ? "   " : "│  "
          annotation = property.annotation ? " (#{property.annotation})" : ""
          [ " #{branch}─ [#{property.tag}] #{property.path.join(".")}#{annotation}" ] +
            values_of(property).map { |line| " #{stem}#{line}" }
        end
      end

      # The two sides of a property change, as the CDK's formatObjectDiff
      # prints them for a scalar: the old value struck out with [-], the new
      # one added with [+]. A value that is not a string is its JSON.
      def values_of(property)
        if property.update?
          [ "├─ [-] #{shown(property.old_value)}", "└─ [+] #{shown(property.new_value)}" ]
        elsif property.removal?
          [ "└─ [-] #{shown(property.old_value)}" ]
        else
          [ "└─ [+] #{shown(property.new_value)}" ]
        end
      end

      def shown(value)
        value.is_a?(String) ? value : JSON.generate(value)
      end

      # `[+] Parameter EnvType: prod`, `[~] Parameter EnvType: prod to
      # staging`, `[-] Parameter EnvType` -- the CDK's formatDifference.
      def value_line(difference, entry_type, name = nil)
        values = if difference.update?
          "#{shown(difference.old_value)} to #{shown(difference.new_value)}"
        elsif difference.removal?
          shown(difference.old_value)
        else
          shown(difference.new_value)
        end
        marker = difference.update? ? "~" : (difference.removal? ? "-" : "+")
        "[#{marker}] #{entry_type}#{name ? " #{name}" : ""}: #{values}"
      end

      # A plain-text table: every column as wide as its widest line, two
      # spaces between columns, a cell that wraps onto several lines keeping
      # its column. The CDK draws a box with unicode rules and colour; this is
      # the same rows without them.
      def table(header, rows)
        all_rows = [ header ] + rows
        widths = header.length.times.map do |column|
          all_rows.flat_map { |cells| (cells[column] || "").to_s.split("\n", -1) }.map(&:length).max || 0
        end
        all_rows.flat_map do |cells|
          cell_lines = cells.map { |cell| (cell || "").to_s.split("\n", -1) }
          height = cell_lines.map(&:length).max
          height.times.map do |line|
            cell_lines.each_with_index.map { |lines, column| (lines[line] || "").ljust(widths[column]) }.join("  ").rstrip
          end
        end
      end

      NO_CHANGES = "There were no differences"
      NO_SECURITY_CHANGES = "There were no security-related changes"
    end
  end
end
