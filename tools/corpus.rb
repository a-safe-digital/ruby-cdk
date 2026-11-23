# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"

# The corpus: the templates the CDK has synthesized and checked into aws/aws-cdk.
#
# Everything here is logic without a network and without a process, so that it can be tested
# without either. The fetch is in rakelib/corpus.rake; `rake corpus:update` runs the fetch and then
# this, and refreshes the sample that is committed under test/fixtures/corpus/.
#
# The templates are third-party data. They are read, parsed and copied; nothing in them is run.
module Tools
  module Corpus
    # The committed sample.
    ROOT = File.expand_path("..", __dir__)
    FIXTURES = File.join(ROOT, "test", "fixtures", "corpus")
    TEMPLATES = File.join(FIXTURES, "templates")
    META = File.join(FIXTURES, "META.json")

    # What the corpus is: every file of aws/aws-cdk whose name ends like this.
    PATTERN = "*.template.json"
    SUFFIX = ".template.json"
    # How many templates the committed sample holds.
    DEFAULT_COUNT = 400
    # A service with this many templates in the corpus is always in the sample.
    MIN_STRATUM = 5
    # The sample is a function of the paths and of this, and of nothing else. Changing it chooses
    # a different sample from the same corpus.
    SEED = "ruby-cdk-corpus-v1"
    # The longest file name in the sample. A longer one would put a checkout of this repository
    # past the 260 characters Windows allows for a path.
    NAME_LIMIT = 140
    # Where a template outside every CDK module is counted.
    UNCLASSIFIED = "unclassified"

    # The integration tests that were really deployed; the rest of the corpus is their
    # counterparts in the alpha packages.
    FRAMEWORK_INTEG = "packages/@aws-cdk-testing/framework-integ/"

    # What `packages/` holds: the segment that starts a repository path, wherever it sits.
    PACKAGES = %r{\Apackages/|/packages/}
    # The packages that hold one directory per module rather than being one. A scope (@aws-cdk,
    # @aws-cdk-testing) is not part of a module's name.
    COLLECTIONS = %w[aws-cdk-lib framework-integ].freeze
    # "aws-lambda-nodejs" is a module of the service "lambda".
    SERVICE = /\Aaws-([^-\/]+)/
    ALPHA = "-alpha"

    class << self
      ## What a template uses

      # The CloudFormation resource types a template declares, sorted and without repeats. The
      # resources of a template nested in another one (a stack's TemplateBody) count with it. A
      # property that happens to be called Type does not.
      def resource_types(template)
        found = []
        each_node(template) do |node|
          next unless node.is_a?(Hash) && node["Resources"].is_a?(Hash)

          node["Resources"].each_value do |resource|
            type = resource["Type"] if resource.is_a?(Hash)
            found << type if type.is_a?(String)
          end
        end
        found.uniq.sort
      end

      # The intrinsic functions a template uses, by name ("Ref", "Fn::GetAtt"), sorted and without
      # repeats, at every depth. A short form such as "!GetAtt" is named by its long one.
      def functions(template)
        found = []
        each_node(template) do |node|
          next unless node.is_a?(Hash) && node.size == 1

          name = intrinsic_name(node.keys.first)
          found << name if name
        end
        found.uniq.sort
      end

      ## Where a template comes from

      # The CDK module a template is in: the integration module under framework-integ, the module
      # under aws-cdk-lib, or else the package itself. nil for anything outside packages/, and for
      # a file that sits in no module directory of a collection.
      def module_of(path)
        parts = parts_after_packages(path)
        return nil unless parts

        parts.shift if parts.first.start_with?("@")
        unless COLLECTIONS.include?(parts.first)
          return parts.one? ? nil : parts.first
        end

        parts.shift
        parts.shift if parts.first == "test"
        parts.one? ? nil : parts.first
      end

      # The service a template belongs to: its module without "aws-" and without what follows the
      # service's own name (aws-s3-deployment is s3, aws-lambda-nodejs is lambda). A module that is
      # no service (core, pipelines) is a group of its own.
      def service_of(path)
        name = module_of(path)
        return UNCLASSIFIED unless name

        name = name.delete_suffix(ALPHA)
        name[SERVICE, 1] || name
      end

      ## The sample

      # Where a template stands among those of its service: the digest of the seed and its path.
      def sample_key(path)
        Digest::SHA256.hexdigest("#{SEED}:#{path}")
      end

      # The sample of a corpus, as [path, service] pairs in path order: deterministic, and
      # stratified by service. Every service that has MIN_STRATUM templates is represented, and
      # the rest of the count goes proportionally. Within a service the templates with the
      # smallest sample_key are taken, so nothing is reshuffled when the corpus grows.
      def select_sample(templates, count: DEFAULT_COUNT)
        paths = templates.map(&:to_s).uniq.sort
        return paths.map { |path| [path, service_of(path)] } if paths.size <= count
        return [] unless count.positive?

        services = paths.group_by { |path| service_of(path) }
        seats = seats_for(services, count)
        services.flat_map do |service, members|
          ordered = members.sort_by { |path| [sample_key(path), path] }
          ordered.first(seats.fetch(service)).map { |path| [path, service] }
        end.sort_by(&:first)
      end

      # The file name a template takes in the sample: its whole path with every "/" doubled, so
      # that two templates never share a name. One that would be longer than NAME_LIMIT keeps a
      # digest of its path and the end of it.
      def sample_name(path)
        name = path.gsub("/", "__")
        return name if name.bytesize <= NAME_LIMIT

        digest = Digest::SHA256.hexdigest(path)[0, 8]
        tail = name[-(NAME_LIMIT - digest.bytesize - 2)..]
        separator = tail.index("__")
        tail = tail[(separator + 2)..] if separator
        "#{digest}__#{tail}"
      end

      ## Files

      # Every template below root, as { path under root => file on disk }, in path order. The
      # shape write_sample takes.
      def templates_in(root)
        template_files_in(root).to_h { |path| [path, File.join(root, path)] }
      end

      # Each template of the committed sample, in path order, as the file that load parses.
      # Without a block it answers an Enumerator.
      def each_sample_template(directory = TEMPLATES)
        return to_enum(__method__, directory) unless block_given?

        template_files_in(directory).each { |path| yield File.join(directory, path) }
      end

      # A template file, parsed. Its bytes are read as they are, on every system.
      def load(path)
        JSON.parse(File.binread(path))
      end

      # Writes the sample of the corpus under destination/templates/<service>/, and what is known
      # of the corpus in destination/META.json. A file is written only when its bytes differ from
      # what is there; nothing else under destination is touched.
      #
      # templates is what templates_in answers. Answers the META.json content as :meta, how many
      # template files were :written, :rewritten and :unchanged, whether META.json itself was
      # written (:meta_written), and the files of an earlier sample that are no longer selected
      # (:stale).
      def write_sample(destination:, templates:, commit:, date:, count: DEFAULT_COUNT)
        # A file that does not parse is no template: it is counted, and left out of the sample.
        parsed = templates.to_h { |path, file| [path, parse(file)] }
        loadable = parsed.compact
        files = templates.slice(*loadable.keys)
        sample = select_sample(files.keys, count:)

        names = sample.map { |path, service| "#{service}/#{sample_name(path)}" }
        unless names.map(&:downcase).uniq.size == names.size
          raise ArgumentError, "corpus: two templates of the sample would share a file name"
        end

        directory = File.join(destination, "templates")
        outcomes = Hash.new(0)
        sample.each do |path, service|
          target = File.join(directory, service, sample_name(path))
          outcomes[write_if_changed(target, File.binread(files.fetch(path)))] += 1
        end

        selected = sample.map(&:first)
        meta = {
          "commit" => commit,
          "date" => date,
          "corpus" => describe(templates.keys, templates, parsed, resource_types_in(files.keys, parsed)).merge(
            "framework_integ" => templates.keys.count { |path| path.start_with?(FRAMEWORK_INTEG) },
            "unparseable" => templates.size - files.size
          ),
          "sample" => describe(selected, files, parsed, resource_types_in(selected, parsed))
        }
        meta_file = File.join(destination, "META.json")
        meta_written = write_if_changed(meta_file, JSON.pretty_generate(meta) << "\n") != :unchanged

        {
          meta:,
          files: { written: outcomes[:written], rewritten: outcomes[:rewritten], unchanged: outcomes[:unchanged] },
          meta_written:,
          stale: template_files_in(directory) - names
        }
      end

      private

      ## What a template uses

      # Yields every Hash and Array in a parsed template, at every depth.
      def each_node(value, &block)
        case value
        when Hash
          block.call(value)
          value.each_value { |child| each_node(child, &block) }
        when Array
          block.call(value)
          value.each { |child| each_node(child, &block) }
        end
      end

      # "Ref", "Fn::Join", or the long name of a short form ("!GetAtt" is "Fn::GetAtt"). nil when
      # the name is none of these.
      def intrinsic_name(name)
        return nil unless name.is_a?(String)
        return "Ref" if name == "Ref" || name == "!Ref"
        return name if name.match?(/\AFn::[A-Za-z0-9]+\z/)
        return "Fn::#{name.delete_prefix("!")}" if name.match?(/\A![A-Za-z0-9]+\z/)

        nil
      end

      ## Where a template comes from

      # The path's segments after packages/; nil when it has none.
      def parts_after_packages(path)
        text = path.to_s
        match = PACKAGES.match(text)
        return nil unless match

        text[match.end(0)..].split("/")
      end

      ## The sample

      # How many templates each service contributes, one entry per service: one to every service
      # that has MIN_STRATUM templates (the largest first when the count cannot hold them all),
      # and the rest in proportion to size. The proportional seats are shared by the largest
      # remainder method, in integers, so that no rounding can move one.
      def seats_for(services, count)
        represented = services.sort_by { |service, members| [-members.size, service] }
          .select { |_, members| members.size >= MIN_STRATUM }.map(&:first).first(count)
        seats = services.to_h { |service, _| [service, 0] }
        represented.each { |service| seats[service] = 1 }
        spare = count - represented.size
        return seats if spare.zero?

        total = services.values.sum(&:size)
        shares = services.to_h do |service, members|
          whole, remainder = (spare * members.size).divmod(total)
          [service, [whole, remainder]]
        end
        owed = services.keys.sort_by { |service| [-shares.fetch(service).last, -services.fetch(service).size, service] }
        left = spare - shares.values.sum(&:first)
        owed.first(left).each { |service| shares.fetch(service)[0] += 1 }

        seats.merge(shares.transform_values(&:first)) { |_, at_least_one, share| at_least_one + share }
      end

      ## Files

      # The templates below root, by path under root, in path order. Only regular files: a link
      # that ends like a template is not read through.
      def template_files_in(root)
        Dir.glob("**/#{PATTERN}", base: root).sort.select { |path| File.lstat(File.join(root, path)).file? }
      end

      # The parsed template, or nil when the file is not a JSON object.
      def parse(file)
        template = load(file)
        template.is_a?(Hash) ? template : nil
      rescue JSON::ParserError, EncodingError
        nil
      end

      # The distinct resource types of the templates at paths.
      def resource_types_in(paths, parsed)
        paths.flat_map { |path| resource_types(parsed.fetch(path)) }.uniq
      end

      # What META.json says of a set of templates.
      def describe(paths, files, parsed, resource_types)
        {
          "templates" => paths.size,
          "bytes" => paths.sum { |path| File.size(files.fetch(path)) },
          "resource_types" => resource_types.size,
          "without_resources" => paths.count { |path| parsed[path] && !parsed[path].key?("Resources") },
          "services" => paths.map { |path| service_of(path) }.tally.sort.to_h
        }
      end

      # :written, :rewritten or :unchanged.
      def write_if_changed(file, bytes)
        return :unchanged if File.file?(file) && File.binread(file) == bytes

        outcome = File.file?(file) ? :rewritten : :written
        FileUtils.mkdir_p(File.dirname(file))
        File.binwrite(file, bytes)
        outcome
      end
    end
  end
end
