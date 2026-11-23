# frozen_string_literal: true

require "test_helper"
require "prism"
require_relative "components"

# The component map is binding. Three static tests keep it so: what each component
# requires, what it names, and everything it reaches through the files it requires.
#
# The third is complete because the first forbids any load that is not a literal
# `require`: with every edge known, the closure is the truth, and nothing needs to
# start a process to look at it.
class ComponentBoundariesTest < Minitest::Test
  LIB = Architecture::LIB

  # The components `require "ruby-cdk"` must reach: the synthesis path. Never the
  # deploy engine, the SDK adapters, the diff, the security rules, the test kit,
  # the bootstrap or the command line: each of those is loaded by a command.
  UMBRELLA_REACHES = %i[errors values version core cfn synth schema validation assets ports].freeze

  # --- every require stays inside the map, and is a literal

  def test_every_component_requires_only_what_the_map_allows
    violations = []
    each_component_file do |component, file, relative|
      requires_in(File.read(file)).each do |line, target, kind|
        if target.nil?
          violations << "#{relative}:#{line}: #{kind} without a literal argument; a component loads statically"
          next
        end

        resolved = resolve(target, kind, file)
        if resolved == :umbrella
          violations << "#{relative}:#{line}: requires the umbrella (#{target}); depend on components"
        elsif resolved == :missing
          violations << "#{relative}:#{line}: requires #{target}, which does not exist"
        elsif resolved.start_with?("ruby_cdk/")
          owner = Architecture.owner_of(resolved)
          if owner.nil?
            violations << "#{relative}:#{line}: requires #{resolved}, which no component owns"
          elsif !Architecture.closure(component.name).include?(owner.name)
            violations << "#{relative}:#{line}: #{component.name} requires #{resolved}, owned by #{owner.name}, " \
              "which is not among its dependencies #{component.depends_on.inspect}"
          end
        elsif !component.gems.include?(resolved)
          violations << "#{relative}:#{line}: #{component.name} loads #{resolved}; the map allows it #{component.gems.inspect}"
        end
      end
    end

    assert_empty violations, violations.join("\n")
  end

  # --- a component names only the components it depends on

  def test_no_component_names_one_it_does_not_depend_on
    violations = []
    each_component_file do |component, file, relative|
      allowed = Architecture.closure(component.name)
      namespace_reads_in(File.read(file)).each do |line, name|
        owner_name = Architecture::NAMESPACES[name]
        next if owner_name.nil? || allowed.include?(owner_name)

        violations << "#{relative}:#{line}: names #{name} (component #{owner_name}) without depending on it"
      end
    end

    assert_empty violations, violations.join("\n")
  end

  # --- everything a component reaches belongs to it or to its dependencies, and nothing below the adapters reaches the SDK

  def test_every_component_reaches_only_what_its_dependencies_own
    failures = []
    Architecture::COMPONENTS.each do |component|
      unless File.file?(Architecture.entry_path(component))
        failures << "#{component.name}: no entry file at #{component.entry}.rb"
        next
      end

      allowed = Architecture.closure(component.name)
      reaches_aws_sdk = false
      reached_from(Architecture.files_of(component)).each do |file|
        relative = file.delete_prefix("#{LIB}/")
        owner = Architecture.owner_of(relative)
        failures << "#{component.name} reaches #{relative}, which no component owns" if owner.nil?
        failures << "#{component.name} reaches #{relative}, owned by #{owner.name}, which is not among its dependencies" if owner && !allowed.include?(owner.name)

        source = File.read(file)
        reaches_aws_sdk ||= requires_in(source).any? { |_line, target, _kind| target&.start_with?("aws-sdk-") }
      end
      failures << "#{component.name} is in layer #{component.layer} and reaches the AWS SDK" if reaches_aws_sdk && component.layer < Architecture::AWS_SDK_FROM_LAYER
    end

    assert_empty failures, failures.join("\n")
  end

  def test_the_umbrella_is_the_synthesis_path_and_reaches_no_sdk
    files = Architecture::UMBRELLA.map { |relative| File.join(LIB, relative) }.select { |file| File.file?(file) }
    refute_empty files, "the umbrella files are missing"

    reached = reached_from(files)
    reached_owners = reached.map { |file| Architecture.owner_of(file.delete_prefix("#{LIB}/"))&.name }.compact.uniq.sort
    sdk = reached.any? do |file|
      requires_in(File.read(file)).any? { |_line, target, _kind| target&.start_with?("aws-sdk-") }
    end

    refute sdk, "requiring the umbrella reaches the AWS SDK"
    assert_equal [], reached_owners - UMBRELLA_REACHES, "the umbrella reaches components it must not"
    assert_equal [], UMBRELLA_REACHES - reached_owners, "the umbrella does not reach every component of the synthesis path"
  end

  private

  def each_component_file
    Architecture::COMPONENTS.each do |component|
      Architecture.files_of(component).each do |file|
        yield component, file, file.delete_prefix("#{LIB}/")
      end
    end
  end

  # Every gem file reached from the given files through literal requires, the given ones included.
  def reached_from(files)
    seen = {}
    frontier = files.dup
    until frontier.empty?
      file = frontier.pop
      next if seen[file]

      seen[file] = true
      requires_in(File.read(file)).each do |_line, target, kind|
        next unless target && kind != :other

        resolved = resolve(target, kind, file)
        frontier << File.join(LIB, "#{resolved}.rb") if resolved.is_a?(String) && resolved.start_with?("ruby_cdk/")
      end
    end
    seen.keys
  end

  # [[line, target, kind], ...]. kind is :require, :require_relative, or :other for
  # load, autoload and the like, which a component never uses; target is nil when
  # the argument is not a literal.
  def requires_in(source)
    found = []
    stack = [Prism.parse(source).value]
    until stack.empty?
      node = stack.pop
      if node.is_a?(Prism::CallNode) && LOADERS.include?(node.name) && node.arguments
        argument = node.arguments.arguments.first
        found << [node.location.start_line, argument.is_a?(Prism::StringNode) ? argument.unescaped : nil, LOADERS.fetch(node.name)]
      end
      stack.concat(node.compact_child_nodes)
    end
    found
  end

  LOADERS = { require: :require, require_relative: :require_relative, load: :other, autoload: :other, require_or_load: :other }.freeze

  # "ruby_cdk/x" without the .rb, a gem name, :umbrella or :missing.
  def resolve(target, kind, file)
    if kind == :require_relative
      path = target.end_with?(".rb") ? target : "#{target}.rb"
      full = File.expand_path(path, File.dirname(file))
      return File.file?(full) ? full.delete_prefix("#{LIB}/").delete_suffix(".rb") : :missing
    end

    return :umbrella if Architecture::UMBRELLA.any? { |name| name == target || name.delete_suffix(".rb") == target }
    return File.file?(File.join(LIB, "#{target}.rb")) ? target : :missing if target.start_with?("ruby_cdk/")

    target.split("/").first
  end

  # [[line, top-level name], ...] for every read of a name from NAMESPACES that is not a definition.
  def namespace_reads_in(source)
    definitions = {}
    reads = []
    stack = [Prism.parse(source).value]
    until stack.empty?
      node = stack.pop
      if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
        path = node.constant_path
        while path.is_a?(Prism::ConstantPathNode)
          definitions[path.object_id] = true
          path = path.parent
        end
        definitions[path.object_id] = true
      elsif (node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)) && !definitions[node.object_id]
        reads << [node.location.start_line, node.name]
      end
      stack.concat(node.compact_child_nodes)
    end
    reads
  end
end
