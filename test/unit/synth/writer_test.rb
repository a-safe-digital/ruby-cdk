# frozen_string_literal: true

require "test_helper"
require "support/core_helpers"

# The write phase: a file is written only when its bytes changed.
class SynthWriterTest < CoreHelpers::TestCase
  Writer = RubyCdk::Synth::Writer

  def test_a_file_is_written_when_it_is_not_there
    path = File.join(dir, "new.json")

    assert_equal true, Writer.write_if_changed(path, "{\n}\n")
    assert_equal "{\n}\n", File.binread(path)
  end

  def test_a_file_is_not_written_again_when_it_already_holds_those_bytes
    path = File.join(dir, "same.json")
    File.binwrite(path, "é\n")
    before = File.mtime(path)

    assert_equal false, Writer.write_if_changed(path, "é\n".b)
    assert_equal false, Writer.write_if_changed(path, "é\n")
    assert_equal before, File.mtime(path)
  end

  def test_a_file_is_written_when_its_bytes_differ
    path = File.join(dir, "changed.json")
    File.binwrite(path, "é\n")

    assert_equal true, Writer.write_if_changed(path, "{\n}\n")
    assert_equal "{\n}\n", File.binread(path)
  end

  def test_the_directory_and_every_one_above_it_that_is_missing_are_made
    deep = File.join(dir, "a", "b", "c")

    Writer.mkdir(deep)
    assert File.directory?(deep)

    Writer.mkdir(deep)
    assert_equal [], Dir.children(deep)
  end

  def test_a_directory_cannot_be_made_where_a_file_is
    file = File.join(dir, "file")
    File.write(file, "")

    error = assert_raises(RubyCdk::UsageError) { Writer.mkdir(File.join(file, "out")) }

    assert_match(/\ACannot create the directory #{Regexp.escape(File.join(file, "out"))}: File exists/, error.message)
  end

  def test_a_file_that_cannot_be_written_is_a_usage_error
    directory = File.join(dir, "a-directory")
    Dir.mkdir(directory)

    error = assert_raises(RubyCdk::UsageError) { Writer.write_if_changed(directory, "x") }

    assert_match(/\ACannot write #{Regexp.escape(directory)}: /, error.message)
  end
end
