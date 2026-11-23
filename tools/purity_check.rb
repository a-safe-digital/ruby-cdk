# frozen_string_literal: true

# purity: allow-node-words

require "pathname"
require "prism"

# Fails when the shipped code could reach a shell or the JavaScript toolchain.
# Run with `rake purity`.
#
# Ruby is parsed with Prism, so a backtick inside a string literal is not a
# false positive and a call that starts a process is found wherever it hides.
# What is not Ruby (workflow files, the Gemfile) is a text scan.
module Tools
  module PurityCheck
    # Method names that start a process or open a pipe. None is used in shipped code.
    PROCESS_CALLS = %i[
      system exec spawn popen popen3 popen2e pipeline pipeline_r pipeline_rw pipeline_start
      capture2 capture2e capture3 capture3e capture capturee
    ].freeze

    NODE_WORDS = %w[node nodejs npm npx jsii yarn pnpm].freeze

    # Runner actions written in JavaScript, which run on the runner's own runtime.
    ALLOWED_ACTIONS = %w[actions/checkout ruby/setup-ruby actions/cache].freeze

    # A file with this marker may name the toolchain in a string: this file does.
    ALLOW_NODE_WORDS = "purity: allow-node-words"

    TOOLCHAIN_FILE = "package.json"
    TOOLCHAIN_EXTENSIONS = %w[.js .cjs .mjs .ts .cts .mts .jsx .tsx].freeze

    class << self
      # One line per violation in a piece of Ruby; empty when it is clean.
      def violations_in_source(source, path)
        result = Prism.parse(source)
        violations = []
        if result.errors.any?
          violations << "#{path}: does not parse: #{result.errors.first.message} (#{result.errors.length} parse error#{"s" if result.errors.length > 1})"
        end
        node_words_allowed = source.include?(ALLOW_NODE_WORDS)
        stack = [ result.value ]

        until stack.empty?
          node = stack.pop
          case node
          when Prism::XStringNode
            violations << "#{path}:#{node.location.start_line}: backticks run a shell command"
          when Prism::CallNode
            if PROCESS_CALLS.include?(node.name)
              violations << "#{path}:#{node.location.start_line}: `#{node.name}` starts a process or a pipe"
            end
          when Prism::StringNode, Prism::SymbolNode
            # A literal can be binary, as a gzip magic number: it names nothing in words.
            word = node.unescaped.to_s
            if word.valid_encoding? && !node_words_allowed && NODE_WORDS.include?(word.downcase)
              violations << "#{path}:#{node.location.start_line}: names the JavaScript toolchain: #{word.inspect}"
            end
          end
          stack.concat(node.compact_child_nodes)
        end

        violations
      end

      # One line per line of a non-Ruby file that names the toolchain outside a comment.
      def violations_in_text(lines, path)
        lines.each_with_index.filter_map do |line, index|
          text = line.split(/\s+#/, 2).first.to_s.strip
          next if text.empty? || text.start_with?("#")
          next if ALLOWED_ACTIONS.any? { |action| text.include?(action) }
          next unless text.match?(/\b(?:#{NODE_WORDS.join('|')})\b/i)

          "#{path}:#{index + 1}: names the JavaScript toolchain: #{line.strip}"
        end
      end

      # Every violation in the repository rooted at root.
      def violations_in_repo(root)
        violations = ruby_files(root).flat_map do |path|
          violations_in_source(File.read(path), relative(path, root))
        end

        text_files(root).each do |path|
          violations.concat(violations_in_text(File.readlines(path, chomp: true), relative(path, root)))
        end

        toolchain_files(root).each do |path|
          violations << "#{relative(path, root)}: a file of the JavaScript toolchain"
        end

        violations
      end

      private

      def relative(path, root)
        Pathname.new(path).relative_path_from(Pathname.new(root)).to_s
      end

      def under_skipped_root?(relative_path)
        relative_path.start_with?(".git/", ".zcode/", ".bundle/", "vendor/", "coverage/", "pkg/", "cdk.out/")
      end

      def ruby_files(root)
        Dir[
          File.join(root, "lib", "**", "*.rb"),
          File.join(root, "exe", "*"),
          File.join(root, "tools", "**", "*.rb"),
          File.join(root, "rakelib", "**", "*.rake"),
          File.join(root, "Rakefile"),
        ].select { |path| File.file?(path) }
      end

      def text_files(root)
        files = Dir[File.join(root, ".github", "**", "*")].select { |path| File.file?(path) }
        files + [ File.join(root, "Gemfile"), File.join(root, "ruby-cdk.gemspec") ].select { |path| File.file?(path) }
      end

      def toolchain_files(root)
        Dir[File.join(root, "**", "*{#{TOOLCHAIN_EXTENSIONS.join(',')}}"), File.join(root, "**", TOOLCHAIN_FILE)]
          .select { |path| File.file?(path) && !under_skipped_root?(relative(path, root)) }
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  require "pathname"

  found = Tools::PurityCheck.violations_in_repo(ARGV[0] || Dir.pwd)
  puts found
  if found.empty?
    puts "purity: no shell, no JavaScript toolchain"
  else
    puts "purity: #{found.length} violation(s)"
    exit 1
  end
end
