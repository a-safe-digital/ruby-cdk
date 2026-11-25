# frozen_string_literal: true

require_relative "../errors"
require_relative "compare"

module RubyCdk
  module Diff
    # One value of the template, from one side of the diff to the other. A nil
    # old_value means the value is new to the template; a nil new_value means
    # it is gone. A Difference whose sides compare equal is not built: the
    # sections keep only what changed.
    Difference = Data.define(:old_value, :new_value) do
      def different?
        !Compare.equal?(old_value, new_value)
      end

      def addition?
        old_value.nil? && !new_value.nil?
      end

      def removal?
        !old_value.nil? && new_value.nil?
      end

      def update?
        !old_value.nil? && !new_value.nil?
      end
    end

    # One changed property path of a resource. name is the property at the top
    # of the resource's Properties (the name CloudFormation names in a change
    # set's detail); path is the way down to the change, segments being
    # property names with integers for list indexes; impact says what changing
    # the path costs, from the schema model's update behaviours:
    #
    #   :update       the resource is updated in place
    #   :replace      the path sits inside a create-only property: the resource is replaced
    #   :may_replace  the behaviour is conditional: the resource may be replaced
    PropertyChange = Data.define(:name, :path, :old_value, :new_value, :impact) do
      # The annotation the CDK prints after the property's name.
      ANNOTATIONS = { replace: "requires replacement", may_replace: "may cause replacement" }.freeze

      # The marker the CDK prints before a changed value: [+], [-] or [~].
      def tag
        return "~" if update?
        return "-" if removal?

        "+"
      end

      def addition?
        old_value.nil? && !new_value.nil?
      end

      def removal?
        !old_value.nil? && new_value.nil?
      end

      def update?
        !old_value.nil? && !new_value.nil?
      end

      def annotation
        ANNOTATIONS[impact]
      end

      # The replacement the change set reports for the property: "True",
      # "Conditional" or "False", as CloudFormation names them.
      def replacement_field
        case impact
        when :replace then "True"
        when :may_replace then "Conditional"
        else "False"
        end
      end

      def to_h
        { "path" => path.join("."), "old" => old_value, "new" => new_value, "replacement" => replacement_field }
      end
    end

    # The change of one resource, as a change set would report it: the action
    # (Add, Modify or Remove), whether the resource is replaced, and the
    # changed property paths. Carries both sides' whole resource definition for
    # the renderer and for the security view.
    class ResourceChange
      # How badly a change hits the resource that exists, costliest last. The
      # order is the CDK's (ResourceImpact and worstImpact in diff/types.ts).
      BADNESS = { none: 0, import: 0, update: 1, create: 2, orphan: 3, may_replace: 4, replace: 5, destroy: 6 }.freeze

      # What an impact reads as, for a person. The words are the CDK's; the
      # impacts it prints nothing for stay nil here.
      WORDS = {
        none: nil, update: nil, create: nil, import: "import",
        may_replace: "may be replaced", replace: "replace", destroy: "destroy", orphan: "orphan"
      }.freeze

      attr_reader :logical_id, :old_value, :new_value, :old_type, :new_type, :properties, :others

      def initialize(logical_id:, old_value: nil, new_value: nil, old_type: nil, new_type: nil, properties: [], others: {})
        @logical_id = logical_id
        @old_value = old_value
        @new_value = new_value
        @old_type = old_type
        @new_type = new_type
        @properties = properties
        @others = others
        @import = false
      end

      # Internal: the replacement propagation puts a replaced reference's
      # property changes on the resources that reference what is replaced.
      def with_properties(properties)
        change = self.class.new(logical_id:, old_value:, new_value:, old_type:, new_type:, properties:, others:)
        change.import! if @import
        change
      end

      def import!
        @import = true
      end

      def import?
        @import
      end

      def type_changed?
        !old_type.nil? && !new_type.nil? && old_type != new_type
      end

      def addition?
        old_value.nil? && !new_value.nil?
      end

      def removal?
        !old_value.nil? && new_value.nil?
      end

      def update?
        different? && !addition? && !removal?
      end

      def different?
        # A resource that only appears on one side, and a resource whose Type
        # changed, differ even with nothing else to show: the CDK's
        # isDifferent (oldResourceType !== newResourceType, its differenceCount
        # over the changes).
        old_type != new_type || properties.any? || others.any? { |_name, difference| difference.different? }
      end

      # The action CloudFormation's change set reports: "Add", "Modify" or
      # "Remove". A replacement is reported as a Modify that replaces, which is
      # why the replacement is its own field.
      def action
        return "Add" if addition?
        return "Remove" if removal?

        "Modify"
      end

      # What the change set's Replacement field reads: "True" when a
      # create-only path changed, "Conditional" when it may.
      def replacement_field
        return "True" if impact == :replace
        return "Conditional" if impact == :may_replace

        "False"
      end

      # The costliest consequence of the change. A removal is a destroy, or an
      # orphan when the resource's DeletionPolicy keeps it (Retain and
      # RetainExceptOnCreate both do, as the CDK decides). A change of the
      # resource's Type replaces it: CloudFormation has no such update.
      def impact
        return :import if @import

        if old_type != new_type
          return :create if old_type.nil?
          return :replace unless new_type.nil?
          return retained? ? :orphan : :destroy
        end

        base = others.any? { |_name, difference| difference.different? } ? :update : :none
        properties.map(&:impact).reduce(base) { |worst, candidate| costlier(worst, candidate) }
      end

      # The impact, for a person.
      def word
        WORDS.fetch(impact)
      end

      def to_h(security:)
        changed_others = others.select { |_name, difference| difference.different? }
        {
          "logical_id" => logical_id,
          "action" => action,
          "type" => old_type || new_type,
          "old_type" => old_type,
          "new_type" => new_type,
          "replacement" => replacement_field,
          "impact" => impact.to_s,
          "security" => security,
          "properties" => properties.map(&:to_h),
          "other" => changed_others.to_h { |name, difference| [ name, { "old" => difference.old_value, "new" => difference.new_value } ] }
        }
      end

      private

      # True when the resource as it is deployed keeps its physical self after
      # the stack: its DeletionPolicy retains it.
      def retained?
        policy = old_value.is_a?(Hash) ? old_value["DeletionPolicy"] : nil
        %w[Retain RetainExceptOnCreate].include?(policy)
      end

      def costlier(worst, candidate)
        BADNESS.fetch(candidate, 0) > BADNESS.fetch(worst, 0) ? candidate : worst
      end
    end

    # The change set of two templates: what would change between what is
    # deployed and what was synthesized. Sections are compared entry by entry,
    # resources by logical ID with the schema model's update behaviours, and
    # the security view is built from what both templates carry (architecture
    # section 10).
    #
    # A replacement is propagated the way the CDK's diffTemplate propagates it:
    # a resource that is replaced changes what every reference to it resolves
    # to, so a resource whose properties reference it is shown with the
    # property that uses the reference marked as replacing it too.
    class TemplateDiff
      # The template's own keys that are sections of their own. Everything else
      # that differs goes under "Other Changes", as the CDK does.
      SECTIONS = %w[Parameters Mappings Conditions Metadata Outputs].freeze

      attr_reader :stack_name, :format_version, :description, :transform, :unknown

      # old_template and new_template are normalized Hashes; nil answers an
      # empty template, which is how a stack that does not exist yet diffs
      # against nothing. stack_name is carried for the renderer and the JSON.
      def self.build(old_template, new_template, stack_name: nil)
        diff = new(stack_name:)
        diff.send(:compute, old_template || {}, new_template || {})
        diff
      end

      def initialize(stack_name: nil)
        @stack_name = stack_name
        @format_version = nil
        @description = nil
        @transform = nil
        @unknown = {}
        @sections = SECTIONS.to_h { |section| [ section, {} ] }
        @resources = {}
      end

      # { "Parameters" => { name => Difference }, ... }, only what changed.
      attr_reader :sections

      # Every resource of both templates, by logical ID: the changed ones and
      # also the ones that did not, because a reference into an unchanged
      # resource can still become a change through a replaced target.
      attr_reader :resources

      # The resources that change, in the order the CDK renders them: removals,
      # then additions, then updates.
      def changes
        removed = []
        added = []
        updated = []
        @resources.each_value do |change|
          next unless change.different?

          if change.removal?
            removed << change
          elsif change.addition?
            added << change
          else
            updated << change
          end
        end
        removed + added + updated
      end

      # How many things the template changes: the CDK's differenceCount.
      def change_count
        template_attributes.length + @sections.sum { |_name, entries| entries.length } + changes.length + @unknown.length
      end

      def empty?
        change_count.zero?
      end

      def security
        @security ||= Security.build(self)
      end

      # The whole diff as one machine object (--json, section 10).
      def to_h
        {
          "name" => stack_name,
          "has_changes" => !empty?,
          "description" => attribute_to_h(description),
          "format_version" => attribute_to_h(format_version),
          "transform" => attribute_to_h(transform),
          "sections" => @sections.to_h do |section, entries|
            [ section.downcase, entries.to_h { |name, difference| [ name, { "old" => difference.old_value, "new" => difference.new_value } ] } ]
          end,
          "resources" => changes.map { |change| change.to_h(security: security.security_change?(change)) },
          "other" => @unknown.to_h { |key, difference| [ key, { "old" => difference.old_value, "new" => difference.new_value } ] },
          "security" => security.to_h
        }.compact
      end

      private

      def attribute_to_h(attribute)
        return nil unless attribute

        { "old" => attribute.old_value, "new" => attribute.new_value }
      end

      def template_attributes
        [ format_version, description, transform ].compact
      end

      # The whole computation, the CDK's calculateTemplateDiff plus its
      # replacement propagation.
      def compute(old_template, new_template)
        compute_template_attributes(old_template, new_template)
        compute_sections(old_template, new_template)
        compute_resources(old_template, new_template)
        propagate_replacements(old_template, new_template)
      end

      def compute_template_attributes(old_template, new_template)
        @format_version = difference_for(old_template, new_template, "AWSTemplateFormatVersion")
        @description = difference_for(old_template, new_template, "Description")
        @transform = difference_for(old_template, new_template, "Transform")
      end

      def difference_for(old_template, new_template, key)
        old_value = old_template[key]
        new_value = new_template[key]
        return nil if Compare.equal?(old_value, new_value)

        Difference.new(old_value, new_value)
      end

      def compute_sections(old_template, new_template)
        SECTIONS.each do |section|
          entries = {}
          Compare.keyed(old_template[section], new_template[section]) do |name, old_value, new_value|
            next if Compare.equal?(old_value, new_value)

            entries[name] = Difference.new(old_value, new_value)
          end
          @sections[section] = entries
        end

        @unknown = {}
        Compare.keyed(old_template, new_template) do |key, old_value, new_value|
          next if key == "Resources" || key == "AWSTemplateFormatVersion" || key == "Description" || key == "Transform" || SECTIONS.include?(key)
          next if Compare.equal?(old_value, new_value)

          @unknown[key] = Difference.new(old_value, new_value)
        end
      end

      def compute_resources(old_template, new_template)
        Compare.keyed(old_template["Resources"], new_template["Resources"]) do |logical_id, old_value, new_value|
          @resources[logical_id] = build_resource(logical_id, old_value, new_value)
        end
      end

      def build_resource(logical_id, old_value, new_value)
        old_type = old_value.is_a?(Hash) ? old_value["Type"] : nil
        new_type = new_value.is_a?(Hash) ? new_value["Type"] : nil
        same_type = !old_type.nil? && old_type == new_type

        properties = same_type ? property_changes(old_type, old_value, new_value) : []
        others = {}
        if same_type
          Compare.keyed(old_value, new_value) do |key, old_side, new_side|
            next if key == "Properties"

            others[key] = Difference.new(old_side, new_side)
          end
        end

        ResourceChange.new(logical_id:, old_value:, new_value:, old_type:, new_type:, properties:, others:)
      end

      # The changed property paths of one resource, each with the impact the
      # schema model gives the path. A property of an unknown type, or one the
      # model does not describe, costs an update: this tool claims a
      # replacement only where AWS's published model says one.
      def property_changes(resource_type, old_value, new_value)
        old_properties = old_value.is_a?(Hash) ? old_value["Properties"] : nil
        new_properties = new_value.is_a?(Hash) ? new_value["Properties"] : nil
        changes = []
        Compare.keyed(old_properties, new_properties) do |name, old_property, new_property|
          walk_property(resource_type, name, [ name ], old_property, new_property, changes)
        end
        changes
      end

      # The changed leaves under one property: objects are walked by key, lists
      # by index, so the path names the exact place the template changes at.
      # Values of two different kinds, and a property set against one taken
      # away, are one change for the whole value.
      def walk_property(resource_type, name, path, old_value, new_value, out)
        return if Compare.equal?(old_value, new_value)

        if old_value.is_a?(Hash) && new_value.is_a?(Hash)
          keys = old_value.keys + (new_value.keys - old_value.keys)
          keys.each { |key| walk_property(resource_type, name, path + [ key ], old_value[key], new_value[key], out) }
          return
        end

        if old_value.is_a?(Array) && new_value.is_a?(Array)
          length = [ old_value.length, new_value.length ].max
          length.times do |index|
            walk_property(resource_type, name, path + [ index ], old_value[index], new_value[index], out)
          end
          return
        end

        out << PropertyChange.new(name:, path:, old_value:, new_value:, impact: impact_of(resource_type, path))
      end

      # The cost of changing one path, straight from the model
      # (Schema.update_type): a create-only path is a replacement, a
      # conditional one may be.
      def impact_of(resource_type, path)
        case RubyCdk::Schema.update_type(resource_type, path)
        when :immutable then :replace
        when :conditional then :may_replace
        else :update
        end
      end

      # The CDK's reference propagation (diff-template.ts, diffTemplate): while
      # some resource is replaced, rewrite what the new template resolves each
      # reference into, and re-diff, until the rewrite settles. Then a resource
      # that references a replaced target through a property whose change
      # replaces it takes that replacement on.
      def propagate_replacements(old_template, new_template)
        copy = Normalizer.normalize(new_template)
        recompute = recompute_resources(old_template, copy)
        loop do
          propagated = !!(recompute.each_value
            .select { |change| change.different? && change.impact == :replace }
            .any? { |change| replace_references(copy, change.logical_id) })
          recompute = recompute_resources(old_template, copy) if propagated
          break unless propagated
        end

        recompute.each_value
          .select { |change| change.different? && %i[replace may_replace].include?(change.impact) }
          .each do |downstream|
          resource = @resources[downstream.logical_id]
          next if resource.impact == downstream.impact

          replacements = downstream.properties.select { |property| property.impact == :replace }
          @resources[downstream.logical_id] = resource.with_properties(merge_properties(resource.properties, replacements))
        end
      end

      # The resources as they differ between the old template and the copy.
      def recompute_resources(old_template, copy)
        recompute = {}
        Compare.keyed(old_template["Resources"], copy["Resources"]) do |logical_id, old_value, new_value|
          recompute[logical_id] = build_resource(logical_id, old_value, new_value)
        end
        recompute
      end

      # Replaces every reference to the logical ID in the template with the
      # marked form the CDK writes ("LogicalId (replaced)"), so that the next
      # comparison sees what the reference resolves to now. A reference is a
      # one-key object: {"Ref": id}, or an Fn:: intrinsic whose first argument
      # is the ID, as Fn::GetAtt is.
      def replace_references(value, logical_id)
        case value
        when Array
          value.any? { |entry| replace_references(entry, logical_id) }
        when Hash
          replace_in_object(value, logical_id) ||
            value.any? { |entry| replace_references(entry, logical_id) }
        else
          false
        end
      end

      def replace_in_object(object, logical_id)
        keys = object.keys
        return false unless keys.length == 1

        key = keys.first
        if key == "Ref" && object[key] == logical_id
          object[key] = "#{logical_id} (replaced)"
          return true
        end
        return false unless key.start_with?("Fn::")

        arguments = object[key]
        return false unless arguments.is_a?(Array) && arguments.first == logical_id

        arguments[0] = "#{logical_id} (replaced)"
        true
      end

      # The downstream replacement's property changes, over what the resource
      # already carries, by property name: an entry the propagation replaces
      # takes the propagated values, as the CDK's setPropertyChange does.
      def merge_properties(existing, replacements)
        names = replacements.map(&:name)
        existing.reject { |property| names.include?(property.name) } + replacements
      end
    end
  end
end
