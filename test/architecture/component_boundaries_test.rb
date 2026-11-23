# frozen_string_literal: true

require "test_helper"
require "prism"
require_relative "components"

# The component map is binding. Four static tests keep it so: what each component
# loads, what it names, everything it reaches through the files it requires, and
# what `require "ruby-cdk"` brings in.
#
# The third is complete because the first allows a single load that is not a
# literal `require`: the user's app file. With every edge between the gem's files
# known, the closure is the truth, and nothing needs to start a process to see it.
#
# The second does not work from a list of namespaces. It indexes every constant
# the gem defines, with the component whose file defines it, and checks each
# constant a file reads against that. Two components may then share a name, as
# the ports and the deploy engine share RubyCdk::Deploy, without being open to
# each other.
class ComponentBoundariesTest < Minitest::Test
  LIB = Architecture::LIB

  # The components `require "ruby-cdk"` must reach: the synthesis path. Never the
  # deploy engine, the SDK adapters, the diff, the security rules, the test kit,
  # the bootstrap or the command line: each of those is loaded by a command. The
  # validator joins the list with its row, when it is built.
  UMBRELLA_REACHES = %i[errors values version core cfn synth schema assets ports].freeze

  # The one file in the gem that evaluates a path given to it at run time: the
  # app file the user named. That file is not part of the gem, so it is no edge
  # between components. A load anywhere else would hide a dependency.
  RUNTIME_LOAD_IN = %w[ruby_cdk/core/app.rb].freeze

  STATIC_LOADS = %i[require require_relative].freeze
  LOAD_METHODS = %i[require require_relative load autoload require_or_load].freeze
  # They take one argument only when it is a string of code; with a block, none.
  CODE_AS_TEXT = %i[eval instance_eval class_eval module_eval].freeze

  # --- every load stays inside the map, and is a literal require

  def test_every_component_loads_only_what_the_map_allows
    violations = []
    each_component_file do |component, file, relative|
      loads_in(File.read(file)).each do |line, target, kind|
        next if kind == :load && RUNTIME_LOAD_IN.include?(relative)

        if !STATIC_LOADS.include?(kind) || target.nil?
          violations << "#{relative}:#{line}: #{load_violation(kind, target)}"
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
        elsif !loads_allowed?(component, target)
          violations << "#{relative}:#{line}: #{component.name} loads #{target}; the map allows it #{component.gems.inspect} and Ruby's standard library"
        end
      end
    end

    assert_empty violations, violations.join("\n")
  end

  # --- a component reads only the constants that it or its dependencies define

  def test_no_component_names_one_it_does_not_depend_on
    violations = []
    each_component_file do |component, file, relative|
      allowed = Architecture.closure(component.name)
      reads_in(File.read(file)).each do |line, name|
        owners = definitions[name].uniq
        if owners.empty?
          violations << "#{relative}:#{line}: names #{name.join("::")}, which no component defines"
        elsif (owners & allowed).empty?
          violations << "#{relative}:#{line}: names #{name.join("::")}, defined in #{owners.join(", ")}; " \
            "#{component.name} depends on #{component.depends_on.join(", ")}"
        end
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
      reached = reached_from(Architecture.files_of(component))
      reached.each do |file|
        relative = file.delete_prefix("#{LIB}/")
        owner = Architecture.owner_of(relative)
        failures << "#{component.name} reaches #{relative}, which no component owns" if owner.nil?
        failures << "#{component.name} reaches #{relative}, owned by #{owner.name}, which is not among its dependencies" if owner && !allowed.include?(owner.name)
      end
    end

    assert_empty failures, failures.join("\n")
  end

  def test_nothing_below_the_adapters_reaches_the_aws_sdk
    offenders = []
    each_component_file do |component, file, relative|
      next if component.layer >= Architecture::AWS_SDK_FROM_LAYER

      loads_in(File.read(file)).each do |line, target, _kind|
        offenders << "#{relative}:#{line}: #{component.name} is in layer #{component.layer} and loads #{target}" if target&.start_with?("aws-sdk-")
      end
    end

    assert_empty offenders, offenders.join("\n")
  end

  def test_the_umbrella_is_the_synthesis_path_and_reaches_no_sdk
    files = Architecture::UMBRELLA.map { |relative| File.join(LIB, relative) }.select { |file| File.file?(file) }
    refute_empty files, "the umbrella files are missing"

    reached = reached_from(files)
    reached_owners = reached.map { |file| Architecture.owner_of(file.delete_prefix("#{LIB}/"))&.name }.compact.uniq.sort
    sdk = reached.any? do |file|
      loads_in(File.read(file)).any? { |_line, target, _kind| target&.start_with?("aws-sdk-") }
    end

    refute sdk, "requiring the umbrella reaches the AWS SDK"
    assert_equal [], reached_owners - UMBRELLA_REACHES, "the umbrella reaches components it must not"
    assert_equal [], UMBRELLA_REACHES - reached_owners, "the umbrella does not reach every component of the synthesis path"
  end

  # --- the reader the names test rests on

  def test_names_are_read_as_ruby_reads_them
    source = <<~RUBY
      module RubyCdk
        module Deploy
          ChangeSet = Struct.new(:id)
          module StackStatus
            IN_PROGRESS = "_IN_PROGRESS"
            def self.state(status)
              ::Digest::SHA256 == StackStatus ? REVIEW : Deploy::StackStatus
            end
          end
        end
      end
      class RubyCdk::App
        A::B = 2
        def run
          RubyCdk::Deploy::StackStatus.state(RubyCdk::VERSION)
        end
      end
    RUBY
    found = []
    each_constant(source) { |kind, name, more, _line| found << [kind, name, more] }

    assert_equal [
      [:definition, %i[RubyCdk]],
      [:definition, %i[RubyCdk Deploy]],
      [:definition, %i[RubyCdk Deploy ChangeSet]],
      [:read, %i[Struct]],
      [:definition, %i[RubyCdk Deploy StackStatus]],
      [:definition, %i[RubyCdk Deploy StackStatus IN_PROGRESS]],
      [:read, %i[Digest SHA256]],
      [:read, %i[StackStatus]],
      [:read, %i[REVIEW]],
      [:read, %i[Deploy StackStatus]],
      [:definition, %i[RubyCdk App]],
      [:definition, %i[RubyCdk App A B]],
      [:read, %i[RubyCdk Deploy StackStatus]],
      [:read, %i[RubyCdk VERSION]]
    ], found.map { |kind, name, _more| [kind, name] }

    in_stack_status = [%i[RubyCdk], %i[RubyCdk Deploy], %i[RubyCdk Deploy StackStatus]]
    read = ->(written) { found.find { |_kind, name, _more| name == written }[2] }
    assert_equal [%i[Digest SHA256]], read.call(%i[Digest SHA256]), "a name written from the root is only itself"
    assert_equal [%i[RubyCdk Deploy StackStatus StackStatus], %i[RubyCdk Deploy StackStatus], %i[RubyCdk StackStatus], %i[StackStatus]],
      read.call(%i[StackStatus]), "innermost scope first"
    assert_equal [%i[RubyCdk Deploy StackStatus Deploy StackStatus], %i[RubyCdk Deploy Deploy StackStatus], %i[RubyCdk Deploy StackStatus], %i[Deploy StackStatus]],
      read.call(%i[Deploy StackStatus])

    table = {
      %i[RubyCdk] => %i[errors],
      %i[RubyCdk VERSION] => %i[version],
      %i[RubyCdk Deploy REVIEW] => %i[deploy],
      %i[RubyCdk Deploy StackStatus] => %i[ports]
    }
    assert_equal %i[RubyCdk Deploy StackStatus], resolved(table, %i[StackStatus], read.call(%i[StackStatus])), "the module it sits in"
    assert_equal %i[RubyCdk Deploy REVIEW], resolved(table, %i[REVIEW], read.call(%i[REVIEW])), "the module around that"
    assert_equal %i[RubyCdk Deploy StackStatus], resolved(table, %i[Deploy StackStatus], read.call(%i[Deploy StackStatus])), "a path written from the middle"
    assert_nil resolved(table, %i[Digest SHA256], read.call(%i[Digest SHA256])), "not the gem's: left alone"
    assert_equal %i[RubyCdk Nowhere], resolved(table, %i[RubyCdk Nowhere], [%i[RubyCdk Nowhere]]), "written under RubyCdk and defined nowhere: reported"
    assert_nil resolved(table, %i[Nowhere], [%i[Nowhere]])
  end

  private

  def each_component_file
    Architecture::COMPONENTS.each do |component|
      Architecture.files_of(component).each do |file|
        yield component, file, file.delete_prefix("#{LIB}/")
      end
    end
  end

  # A component may load what ships with Ruby and what its row names. A row may
  # name one file of a gem, as net/http, and then that file is what it gets.
  def loads_allowed?(component, target)
    named = Architecture::STDLIB + component.gems
    named.any? { |library| target == library || target.start_with?("#{library}/") }
  end

  def load_violation(kind, target)
    return "#{kind}: runs code given as text; a component's code is in its files" if CODE_AS_TEXT.include?(kind)

    "#{kind} #{target ? target.inspect : "without a literal argument"}: a component loads its files with a literal require"
  end

  # Every gem file reached from the given files through literal requires, the given ones included.
  def reached_from(files)
    seen = {}
    frontier = files.dup
    until frontier.empty?
      file = frontier.pop
      next if seen[file]

      seen[file] = true
      loads_in(File.read(file)).each do |_line, target, kind|
        next unless target && STATIC_LOADS.include?(kind)

        resolved = resolve(target, kind, file)
        frontier << File.join(LIB, "#{resolved}.rb") if resolved.is_a?(String) && resolved.start_with?("ruby_cdk/")
      end
    end
    seen.keys
  end

  # [[line, target, kind], ...] for every call that can load code. kind is the
  # method (require, require_relative, load, autoload) or one of CODE_AS_TEXT.
  # target is the first argument when it is a literal string, and nil otherwise,
  # which for a require means the dependency is hidden.
  def loads_in(source)
    found = []
    stack = [Prism.parse(source).value]
    until stack.empty?
      node = stack.pop
      if (kind = load_kind(node))
        argument = node.arguments&.arguments&.first
        found << [node.location.start_line, argument.is_a?(Prism::StringNode) ? argument.unescaped : nil, kind]
        next
      end
      stack.concat(node.compact_child_nodes)
    end
    found
  end

  def load_kind(node)
    return unless node.is_a?(Prism::CallNode)

    # load is Ruby's only when nothing but self receives it; Model.load(path) is a method of its own.
    return if node.name == :load && node.receiver && !kernel_receiver?(node.receiver)

    return node.name if LOAD_METHODS.include?(node.name)
    return :eval if CODE_AS_TEXT.include?(node.name) && (node.name == :eval || node.arguments&.arguments&.first)
  end

  def kernel_receiver?(node)
    node.is_a?(Prism::SelfNode) || (node.is_a?(Prism::ConstantReadNode) && node.name == :Kernel)
  end

  # "ruby_cdk/x" without the .rb, a library name, :umbrella or :missing.
  def resolve(target, kind, file)
    if kind == :require_relative
      path = target.end_with?(".rb") ? target : "#{target}.rb"
      full = File.expand_path(path, File.dirname(file))
      return File.file?(full) ? full.delete_prefix("#{LIB}/").delete_suffix(".rb") : :missing
    end

    return :umbrella if Architecture::UMBRELLA.any? { |name| name == target || name.delete_suffix(".rb") == target }
    return File.file?(File.join(LIB, "#{target}.rb")) ? target : :missing if target.start_with?("ruby_cdk/")

    target
  end

  # --- names

  # {["RubyCdk", "Deploy", "StackStatus"] => [:ports], ...}: every constant the
  # gem defines, with the components whose files define it.
  def definitions
    @definitions ||= Hash.new { |hash, path| hash[path] = [] }.tap do |table|
      each_component_file do |component, file, _relative|
        each_constant(File.read(file)) do |kind, name, _candidates, _line|
          table[name] << component.name if kind == :definition
        end
      end
    end
  end

  # [[line, name], ...]: every constant the file reads that the gem defines. A
  # name written under RubyCdk that no component defines is returned as written,
  # so that it is reported; a name that is not the gem's is left out.
  def reads_in(source)
    table = definitions
    reads = []
    each_constant(source) do |kind, written, candidates, line|
      next unless kind == :read

      name = resolved(table, written, candidates)
      reads << [line, name] if name
    end
    reads
  end

  # The name as the gem defines it, chosen among the names the written one can
  # mean; the written one when it starts at RubyCdk and none of them is defined.
  def resolved(table, written, candidates)
    candidates.find { |candidate| table.key?(candidate) } || (written.first == :RubyCdk ? written : nil)
  end

  # Yields [kind, name, candidates, line] for every constant the file defines
  # (:definition) or reads (:read). A definition's name is its full path. A read's
  # name is as written, ["Deploy", "StackStatus"], and its candidates are the full
  # paths it can mean there, innermost scope first, as Ruby looks them up.
  # Nothing is yielded for a name that is not written in constants, as self::CONST.
  def each_constant(source)
    walk(Prism.parse(source).value, []) { |found| yield found }
  end

  def walk(node, scopes)
    skip = nil
    inner = scopes
    case node
    when Prism::ClassNode, Prism::ModuleNode
      full = defined_as(scopes, written(node.constant_path), root?(node.constant_path))
      yield [:definition, full, nil, node.location.start_line] if full
      inner = full ? scopes + [full] : scopes
      skip = node.constant_path
    when Prism::ConstantWriteNode, Prism::ConstantOrWriteNode, Prism::ConstantAndWriteNode, Prism::ConstantOperatorWriteNode
      yield [:definition, scopes.last.to_a + [node.name], nil, node.location.start_line]
    when Prism::ConstantPathWriteNode, Prism::ConstantPathOrWriteNode, Prism::ConstantPathAndWriteNode, Prism::ConstantPathOperatorWriteNode
      path = written(node.target)
      if path
        full = defined_as(scopes, path, root?(node.target))
        yield [:definition, full, nil, node.location.start_line] if full
        skip = node.target
      end
    when Prism::ConstantReadNode, Prism::ConstantPathNode
      path = written(node)
      # A path is read whole: its first parts are not read on their own.
      yield [:read, path, candidates_for(scopes, path, root?(node)), node.location.start_line] if path
      return
    end
    node.compact_child_nodes.each do |child|
      walk(child, inner) { |found| yield found } unless child.equal?(skip)
    end
  end

  def defined_as(scopes, path, absolute)
    absolute ? path : scopes.last.to_a + path
  end

  # What a written path can mean where it is: the scopes it sits in, innermost first.
  def candidates_for(scopes, path, absolute)
    return [path] if absolute

    scopes.reverse.map { |scope| scope + path } + [path]
  end

  # The name as written, ["RubyCdk", "Deploy", "StackStatus"]; nil when part of
  # it is not a name.
  def written(node)
    case node
    when Prism::ConstantReadNode
      [node.name]
    when Prism::ConstantPathNode
      node.parent ? written(node.parent)&.push(node.name) : [node.name]
    end
  end

  # True for a name written from the root, as ::Digest.
  def root?(node)
    node = node.parent while node.is_a?(Prism::ConstantPathNode) && node.parent
    node.is_a?(Prism::ConstantPathNode)
  end
end
