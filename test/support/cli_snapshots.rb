# frozen_string_literal: true

require "fileutils"

module RubyCdk
  module Cli
    # The snapshot harness (architecture §15): an example's synthesis compared
    # with the templates committed under test/fixtures/templates/<example>/,
    # byte for byte, every file the synthesis writes, the manifest included.
    #
    # A difference fails the test with a diff. Updating a fixture is a
    # deliberate run with UPDATE_SNAPSHOTS=1, reviewed in the pull request.
    #
    # Nothing here starts a process: the diff is computed in this process.
    module Snapshots
      module_function

      # The examples with committed fixtures, each with the app file that
      # builds it.
      def examples
        {
          "hello" => "examples/hello/cdk.rb",
          "lambda" => "examples/lambda/cdk.rb",
          "app" => "examples/app/cdk.rb"
        }
      end

      def fixtures_root
        File.expand_path("../fixtures/templates", __dir__)
      end

      # The example's synthesis in a new temporary directory. Answers the
      # manifest, whose entries name the files written under it. The caller
      # removes the directory.
      def synthesize(app_file)
        out_dir = Dir.mktmpdir("ruby-cdk-snapshot")
        App.reset!
        manifest = App.build!(app_file: File.expand_path(app_file), out_dir:).synth
        [ manifest, out_dir ]
      ensure
        App.reset!
      end

      # The names of the files of one synthesis, sorted, relative to the directory.
      def files_of(root)
        Dir.glob(File.join(root, "**", "*")).select { |path| File.file?(path) }
          .map { |path| path.delete_prefix("#{root}/") }.sort
      end

      # Compares every file the example's synthesis wrote, and the set of file
      # names, with the fixture. Answers [] when they are equal byte for byte,
      # and one problem per difference, with a diff of the content, when they
      # are not.
      def compare(example, app_file)
        fixture = File.join(fixtures_root, example)
        unless File.directory?(fixture)
          return [ "no committed fixture at #{fixture}: run once with UPDATE_SNAPSHOTS=1 to write it" ]
        end

        _manifest, out_dir = synthesize(app_file)
        written = files_of(out_dir)
        committed = files_of(fixture)

        problems = []
        (written - committed).each { |name| problems << "#{name}: written by the synthesis, not in the fixture" }
        (committed - written).each { |name| problems << "#{name}: in the fixture, not written by the synthesis" }
        (written & committed).each do |name|
          current = File.binread(File.join(out_dir, name))
          expected = File.binread(File.join(fixture, name))
          next if current == expected

          problems << diff(name, expected, current)
        end
        problems
      ensure
        FileUtils.remove_entry(out_dir) if out_dir && File.directory?(out_dir)
      end

      # Writes the example's synthesis into the fixture, replacing what was
      # there. Answers the files and the fixture, for the message.
      def update(example, app_file)
        fixture = File.join(fixtures_root, example)
        manifest, out_dir = synthesize(app_file)
        FileUtils.remove_entry(fixture) if File.directory?(fixture)
        FileUtils.mkdir_p(fixture)
        files_of(out_dir).each { |name| FileUtils.cp(File.join(out_dir, name), File.join(fixture, name)) }
        [ manifest.entries.map(&:template), fixture ]
      ensure
        FileUtils.remove_entry(out_dir) if out_dir && File.directory?(out_dir)
      end

      # True only when the run was asked to rewrite the fixtures. It is a
      # deliberate act: the change lands in the pull request and is reviewed.
      def updating?
        ENV["UPDATE_SNAPSHOTS"] == "1"
      end

      # A unified diff, computed here and not by a process. A template is small,
      # so the whole longest-common-subsequence table is fine.
      def diff(name, expected, current)
        lines = [ "#{name}: differs from the fixture" ]
        table = lcs_table(expected.each_line.map(&:chomp), current.each_line.map(&:chomp))
        walk(table, expected.each_line.map(&:chomp), current.each_line.map(&:chomp)).each do |kind, text|
          case kind
          when :same then lines << "  #{text}"
          when :old then lines << "- #{text}"
          when :new then lines << "+ #{text}"
          end
        end
        lines.join("\n")
      end

      # table[y][x]: the length of the common subsequence of a[0...y] and b[0...x].
      def lcs_table(a, b)
        table = Array.new(a.length + 1) { Array.new(b.length + 1, 0) }
        a.each_with_index do |line, y|
          b.each_with_index do |other, x|
            table[y + 1][x + 1] = line == other ? table[y][x] + 1 : [ table[y][x + 1], table[y + 1][x] ].max
          end
        end
        table
      end

      # Every line of both, marked same, old or new, in order.
      def walk(table, a, b)
        found = []
        y = a.length
        x = b.length
        while y > 0 || x > 0
          kind, text =
            if y > 0 && x > 0 && a[y - 1] == b[x - 1]
              [ :same, a[y - 1] ]
            elsif x > 0 && (y == 0 || table[y][x] == table[y][x - 1])
              [ :new, b[x - 1] ]
            else
              [ :old, a[y - 1] ]
            end
          found << [ kind, text ]
          case kind
          when :same then y -= 1; x -= 1
          when :new then x -= 1
          else y -= 1
          end
        end
        found.reverse
      end
    end
  end
end
