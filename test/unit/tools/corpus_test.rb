# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require_relative "../../../tools/corpus"

# Tools::Corpus: what a template uses, where it comes from, how the sample is chosen and written.
# No test here reaches a network or starts a process.
class CorpusTest < Minitest::Test
  INTEG = "packages/@aws-cdk-testing/framework-integ/test"
  COMMIT = "78649cb7cf7399204ed63f629964779eeaa8b37a"

  # What the CDK's own tests leave in the repository: the snapshot of an integration test.
  def integ(module_name, name)
    "#{INTEG}/#{module_name}/test/integ.#{name}.js.snapshot/integ.#{name}.template.json"
  end

  # The paths of a corpus of integration snapshots: { module => how many }.
  def corpus(sizes)
    sizes.flat_map { |module_name, count| (1..count).map { |index| integ(module_name, "test-#{index}") } }
  end

  # Five services of different sizes: 160, 40, 5, 4 and 1 templates.
  def measured_corpus
    corpus("aws-ec2" => 160, "aws-s3" => 40, "aws-signer" => 5, "aws-chatbot" => 4, "aws-dsql" => 1)
  end

  # Writes a template for each path under root, and answers what write_sample takes.
  def write_templates(root, paths, body: '{"Resources":{"R":{"Type":"AWS::S3::Bucket"}}}')
    paths.to_h do |path|
      file = File.join(root, path)
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, body)
      [ path, file ]
    end
  end

  # How many templates the sample takes from each service.
  def seats(sample)
    sample.map(&:last).tally
  end

  # The paths the sample takes from a service.
  def chosen(sample, service)
    sample.select { |_, theirs| theirs == service }.map(&:first)
  end

  # What a file holds, and when it was last written.
  def state(file)
    [ File.binread(file), File.mtime(file) ]
  end

  ## resource_types

  def test_resource_types_are_the_types_of_the_resources
    template = {
      "Resources" => {
        "Bucket" => { "Type" => "AWS::S3::Bucket", "Properties" => { "BucketName" => "data" } },
        "Policy" => { "Type" => "AWS::S3::BucketPolicy" },
        "OtherBucket" => { "Type" => "AWS::S3::Bucket" },
        "Cleaner" => { "Type" => "Custom::S3AutoDeleteObjects" }
      }
    }

    assert_equal [ "AWS::S3::Bucket", "AWS::S3::BucketPolicy", "Custom::S3AutoDeleteObjects" ], Tools::Corpus.resource_types(template)
  end

  def test_resource_types_are_found_wherever_they_are_nested
    template = {
      "Resources" => {
        "Queue" => { "Type" => "AWS::SQS::Queue" },
        "Nested" => {
          "Type" => "AWS::CloudFormation::Stack",
          "Properties" => {
            "TemplateBody" => {
              "Resources" => {
                "Role" => { "Type" => "AWS::IAM::Role" },
                "Deeper" => {
                  "Type" => "AWS::CloudFormation::Stack",
                  "Properties" => { "TemplateBody" => { "Resources" => { "Table" => { "Type" => "AWS::DynamoDB::Table" } } } }
                }
              }
            }
          }
        }
      }
    }

    assert_equal [ "AWS::CloudFormation::Stack", "AWS::DynamoDB::Table", "AWS::IAM::Role", "AWS::SQS::Queue" ],
      Tools::Corpus.resource_types(template)
  end

  def test_a_property_called_type_is_not_a_resource_type
    template = {
      "Parameters" => { "BootstrapVersion" => { "Type" => "AWS::SSM::Parameter::Value<String>" } },
      "Resources" => {
        "Project" => {
          "Type" => "AWS::CodeBuild::Project",
          "Properties" => { "Source" => { "Type" => "CODEPIPELINE" }, "Environment" => { "Type" => "LINUX_CONTAINER" } }
        },
        "Source" => { "Type" => "AWS::AppSync::DataSource", "Properties" => { "Type" => "AWS_LAMBDA" } }
      }
    }

    assert_equal [ "AWS::AppSync::DataSource", "AWS::CodeBuild::Project" ], Tools::Corpus.resource_types(template)
  end

  def test_a_stack_without_resources_has_no_resource_types
    assertion_stack = { "Parameters" => { "BootstrapVersion" => { "Type" => "String" } }, "Rules" => {} }

    assert_empty Tools::Corpus.resource_types(assertion_stack)
  end

  def test_something_that_is_not_a_template_uses_nothing
    values = [ nil, "text", 42, [], [ { "Resources" => {} } ], { "Resources" => [] }, { "Resources" => { "R" => "no hash" } } ]

    values.each do |value|
      assert_empty Tools::Corpus.resource_types(value), value.inspect
      assert_empty Tools::Corpus.functions(value), value.inspect
    end
  end

  ## functions

  def test_functions_are_the_intrinsics_a_template_uses
    template = {
      "Resources" => {
        "Role" => {
          "Type" => "AWS::IAM::Role",
          "Properties" => {
            "AssumeRolePolicyDocument" => {
              "Statement" => [ {
                "Effect" => "Allow",
                "Principal" => { "Service" => { "Fn::Join" => [ "", [ "lambda.", { "Ref" => "AWS::URLSuffix" } ] ] } }
              } ]
            }
          }
        },
        "Queue" => { "Type" => "AWS::SQS::Queue" }
      },
      "Outputs" => { "RoleArn" => { "Value" => { "Fn::GetAtt" => [ "Role", "Arn" ] } } }
    }

    assert_equal [ "Fn::GetAtt", "Fn::Join", "Ref" ], Tools::Corpus.functions(template)
  end

  def test_functions_are_found_at_every_depth
    template = {
      "Parameters" => { "BootstrapVersion" => { "Type" => "AWS::SSM::Parameter::Value<String>" } },
      "Conditions" => { "IsUsEast1" => { "Fn::Equals" => [ { "Ref" => "AWS::Region" }, "us-east-1" ] } },
      "Rules" => {
        "CheckBootstrapVersion" => {
          "Assertions" => [ {
            "Assert" => { "Fn::Contains" => [ [ "6", "7", "8" ], { "Ref" => "BootstrapVersion" } ] },
            "AssertDescription" => "CDK bootstrap stack version 6 required."
          } ]
        }
      },
      "Resources" => {
        "Instance" => {
          "Type" => "AWS::EC2::Instance",
          "Metadata" => {
            "AWS::CloudFormation::Init" => {
              "config" => {
                # Twelve hashes down, at the bottom of the cfn-init metadata.
                "commands" => {
                  "write" => {
                    "command" => { "Fn::Select" => [ "0", [ { "Fn::GetAtt" => [ "Table", "TableName" ] } ] ] },
                    "env" => { "vars" => { "LIST" => { "Fn::Split" => [ ",", "a,b" ] }, "TABLE" => { "Fn::If" => [ "IsUsEast1", "a", "b" ] } } }
                  }
                }
              }
            }
          },
          "Properties" => {
            "UserData" => {
              "Fn::Base64" => {
                "Fn::Join" => [ "\n", [ "#!/bin/bash", { "Fn::If" => [ "IsUsEast1", { "Ref" => "AWS::NoValue" }, "x" ] } ] ]
              }
            }
          }
        },
        "Policy" => {
          "Type" => "AWS::IAM::Policy",
          "Properties" => {
            "PolicyDocument" => {
              "Statement" => [ { "Action" => "dynamodb:*", "Resource" => { "Fn::Sub" => "${Table.Arn}" } } ]
            }
          }
        },
        "Alias" => { "Type" => "AWS::KMS::Alias", "Properties" => {} },
        "Address" => { "Type" => "AWS::EC2::EIP", "DependsOn" => "Instance" }
      }
    }

    assert_equal [ "Fn::Base64", "Fn::Contains", "Fn::Equals", "Fn::GetAtt", "Fn::If", "Fn::Join", "Fn::Select", "Fn::Split", "Fn::Sub", "Ref" ],
      Tools::Corpus.functions(template)
  end

  def test_a_function_that_is_not_cloudformations_own_is_reported_like_the_others
    # The CDK's integration test runner adds Fn::GetStackOutput to the templates it deploys.
    assert_equal [ "Fn::GetStackOutput", "Ref" ], Tools::Corpus.functions({ "a" => { "Fn::GetStackOutput" => "x" }, "b" => { "Ref" => "y" } })
  end

  def test_a_short_form_is_named_by_its_long_one
    template = { "a" => { "!Sub" => "x" }, "b" => { "!GetAtt" => [ "A", "B" ] }, "c" => { "!Ref" => "X" }, "d" => { "!Base64" => "x" } }

    assert_equal [ "Fn::Base64", "Fn::GetAtt", "Fn::Sub", "Ref" ], Tools::Corpus.functions(template)
  end

  def test_a_hash_that_holds_more_than_a_function_is_no_function
    template = {
      "Resources" => { "R" => { "Type" => "AWS::S3::Bucket", "Properties" => { "Ref" => "a property", "Fn::Join" => "another" } } }
    }

    assert_empty Tools::Corpus.functions(template)
    assert_empty Tools::Corpus.functions({ "Fn" => { "Join" => [] }, "Refs" => [ 1 ], "Fn:" => "x" })
  end

  ## service_of and module_of

  def test_service_and_module_of_cdk_paths
    cases = {
      integ("aws-s3", "bucket") => [ "s3", "aws-s3" ],
      integ("aws-s3-deployment", "big-response") => [ "s3", "aws-s3-deployment" ],
      integ("aws-lambda-nodejs", "function") => [ "lambda", "aws-lambda-nodejs" ],
      integ("aws-elasticloadbalancingv2-targets", "targets") => [ "elasticloadbalancingv2", "aws-elasticloadbalancingv2-targets" ],
      "#{INTEG}/aws-ecs-patterns/test/fargate/x.js.snapshot/a.template.json" => [ "ecs", "aws-ecs-patterns" ],
      "#{INTEG}/custom-resources/test/aws-custom-resource/x.js.snapshot/a.template.json" => [ "custom-resources", "custom-resources" ],
      integ("core", "stack") => [ "core", "core" ],
      "packages/@aws-cdk/aws-imagebuilder-alpha/test/x.js.snapshot/a.template.json" => [ "imagebuilder", "aws-imagebuilder-alpha" ],
      "packages/@aws-cdk/aws-eks-v2-alpha/test/x.js.snapshot/a.template.json" => [ "eks", "aws-eks-v2-alpha" ],
      "packages/@aws-cdk/mixins-preview/test/x.js.snapshot/a.template.json" => [ "mixins-preview", "mixins-preview" ],
      # The CDK keeps one scoped package outside packages/.
      "tools/@aws-cdk/security-guardian/test/templates/a.template.json" => [ "security-guardian", "security-guardian" ],
      "/tmp/a-checkout/aws-cdk/tools/@aws-cdk/security-guardian/test/templates/a.template.json" => [ "security-guardian", "security-guardian" ],
      "packages/aws-cdk-lib/aws-servicecatalog/test/a.template.json" => [ "servicecatalog", "aws-servicecatalog" ],
      "packages/@aws-cdk-testing/framework-integ/product-stack-snapshots/x.v1.product.template.json" => [ "product-stack-snapshots", "product-stack-snapshots" ],
      "/tmp/a-checkout/aws-cdk/#{integ("aws-iam", "role")}" => [ "iam", "aws-iam" ]
    }

    cases.each do |path, (service, module_name)|
      assert_equal [ service, module_name ], [ Tools::Corpus.service_of(path), Tools::Corpus.module_of(path) ], path
    end
  end

  def test_a_template_outside_every_module
    loose = "#{INTEG}/product.v1.product.template.json"

    assert_nil Tools::Corpus.module_of(loose)
    assert_equal Tools::Corpus::UNCLASSIFIED, Tools::Corpus.service_of(loose)
    assert_nil Tools::Corpus.module_of("test/fixtures/a.template.json")
    assert_nil Tools::Corpus.module_of("my_packages/aws-s3/test/a.template.json")
    assert_equal Tools::Corpus::UNCLASSIFIED, Tools::Corpus.service_of("a.template.json")
  end

  ## select_sample

  def test_the_sample_is_a_function_of_the_paths_alone
    paths = measured_corpus
    sample = Tools::Corpus.select_sample(paths, count: 40)

    assert_equal sample, Tools::Corpus.select_sample(paths, count: 40)
    assert_equal sample, Tools::Corpus.select_sample(paths.reverse, count: 40)
    assert_equal sample, Tools::Corpus.select_sample(paths + paths.first(7), count: 40)
    assert_equal sample.map(&:first).sort, sample.map(&:first)
    assert_equal sample.map { |path, _| Tools::Corpus.service_of(path) }, sample.map(&:last)
  end

  def test_every_service_with_five_templates_is_represented
    taken = seats(Tools::Corpus.select_sample(measured_corpus, count: 10))

    assert_operator taken.fetch("signer"), :>=, 1
    assert_operator taken.fetch("ec2"), :>=, taken.fetch("s3")
    assert_equal 10, taken.values.sum
  end

  def test_the_sample_stays_within_the_count
    paths = corpus("aws-ec2" => 50)

    assert_equal 7, Tools::Corpus.select_sample(paths, count: 7).size
    assert_empty Tools::Corpus.select_sample(paths, count: 0)
    assert_empty Tools::Corpus.select_sample([], count: 40)
    assert_equal paths.first(3).sort, Tools::Corpus.select_sample(paths.first(3), count: 40).map(&:first)

    # More services to represent than there are seats: the count holds, and the largest go first.
    sizes = { "aws-ec2" => 50, "aws-s3" => 30 }.merge((1..10).to_h { |index| [ "aws-small#{index}", 5 ] })
    taken = seats(Tools::Corpus.select_sample(corpus(sizes), count: 4))

    assert_equal %w[ec2 s3 small1 small10], taken.keys.sort
    assert_equal [ 1, 1, 1, 1 ], taken.values
  end

  def test_the_rest_of_the_count_goes_proportionally
    taken = seats(Tools::Corpus.select_sample(measured_corpus, count: 40))

    # One seat to each of ec2, s3 and signer leaves 37 for 210 templates. In proportion that is
    # 28.19, 7.05, 0.88, 0.70 and 0.18: 35 whole seats, and the two left go to the largest remainders.
    assert_equal({ "ec2" => 29, "s3" => 8, "signer" => 2, "chatbot" => 1 }, taken)
    assert_equal 40, taken.values.sum
  end

  def test_a_service_gives_the_templates_with_the_smallest_keys
    paths = corpus("aws-ec2" => 50)
    sample = Tools::Corpus.select_sample(paths, count: 9)
    expected = paths.min_by(9) { |path| [ Tools::Corpus.sample_key(path), path ] }

    assert_equal expected.sort, sample.map(&:first)
    assert_equal [ "ec2" ], sample.map(&:last).uniq
  end

  def test_the_sample_key_depends_on_the_path_and_the_seed_alone
    path = integ("aws-s3", "bucket")

    assert_equal Tools::Corpus.sample_key(path), Tools::Corpus.sample_key(path.dup)
    assert_equal 64, Tools::Corpus.sample_key(path).size
    refute_equal Tools::Corpus.sample_key(path), Tools::Corpus.sample_key(path.sub("aws-s3", "aws-sqs"))
  end

  def test_templates_the_sample_does_not_choose_can_be_added_without_a_reshuffle
    paths = measured_corpus
    before = Tools::Corpus.select_sample(paths, count: 40)

    # New templates that rank below every template their service already has: none of them can
    # push a chosen template out of its service's order.
    added = %w[aws-ec2 aws-s3 aws-signer aws-chatbot aws-dsql].flat_map do |module_name|
      keys = paths.select { |path| Tools::Corpus.module_of(path) == module_name }.map { |path| Tools::Corpus.sample_key(path) }
      (1..40).map { |index| integ(module_name, "added-#{index}") }.select { |path| Tools::Corpus.sample_key(path) > keys.max }
    end
    assert_operator added.size, :>=, 10

    after = Tools::Corpus.select_sample(paths + added, count: 40)
    before_seats = seats(before)
    after_seats = seats(after)
    assert_equal 40, after.size

    # A service that kept its seats gives exactly the templates it gave before. One that lost a
    # seat gives the same templates minus one, and one that gained a seat gives them plus one.
    (before_seats.keys | after_seats.keys).each do |service|
      was = chosen(before, service)
      is = chosen(after, service)
      difference = before_seats.fetch(service, 0) - after_seats.fetch(service, 0)

      if difference.positive?
        assert_equal difference, (was - is).size, "#{service} lost #{difference} seat(s)"
        assert_empty is - was
      elsif difference.negative?
        assert_equal -difference, (is - was).size, "#{service} gained #{-difference} seat(s)"
        assert_empty was - is
      else
        assert_equal was, is, "#{service} kept its seats"
      end
    end
  end

  ## The cap on templates without Resources

  # A corpus where a third of the templates deploy nothing: for every two stacks, an assertion stack.
  def corpus_with_assertion_stacks
    stacks = corpus("aws-ec2" => 120, "aws-s3" => 60, "aws-signer" => 6)
    [ stacks, stacks.each_slice(3).map(&:last) ]
  end

  def test_the_sample_holds_at_most_a_few_templates_without_resources
    stacks, bare = corpus_with_assertion_stacks
    uncapped = Tools::Corpus.select_sample(stacks, count: 40)
    sample = Tools::Corpus.select_sample(stacks, count: 40, without_resources: bare, at_most: 5)

    assert_operator uncapped.count { |path, _| bare.include?(path) }, :>, 5
    assert_equal 40, sample.size
    assert_equal 5, sample.count { |path, _| bare.include?(path) }
    assert_equal sample, Tools::Corpus.select_sample(stacks.reverse, count: 40, without_resources: bare, at_most: 5)
    assert_equal sample.map(&:first).sort, sample.map(&:first)
    assert_equal seats(uncapped), seats(sample)

    # What gives way is replaced from its own service: by the templates with Resources that come
    # next in the service's order.
    %w[aws-ec2 aws-s3 aws-signer].each do |module_name|
      service = module_name.delete_prefix("aws-")
      with_resources = stacks.reject { |path| bare.include?(path) || Tools::Corpus.module_of(path) != module_name }
      kept_bare = chosen(sample, service).count { |path| bare.include?(path) }
      expected = with_resources.min_by(seats(sample).fetch(service) - kept_bare) { |path| [ Tools::Corpus.sample_key(path), path ] }

      assert_equal expected.sort, chosen(sample, service).reject { |path| bare.include?(path) }, service
    end
  end

  def test_no_template_without_resources_is_taken_when_none_may_be
    stacks, bare = corpus_with_assertion_stacks

    assert Tools::Corpus.select_sample(stacks, count: 40, without_resources: bare, at_most: 0).none? { |path, _| bare.include?(path) }
    # A corpus that fits in the count is all taken, whatever it holds.
    assert_equal stacks.first(9).sort,
      Tools::Corpus.select_sample(stacks.first(9), count: 40, without_resources: bare, at_most: 0).map(&:first)
  end

  def test_a_template_without_resources_is_left_out_when_its_service_has_none_to_give
    paths = corpus("aws-ec2" => 20, "aws-s3" => 20)
    bare = paths.first(20)

    sample = Tools::Corpus.select_sample(paths, count: 8, without_resources: bare, at_most: 2)

    assert_equal 6, sample.size
    assert_equal 2, sample.count { |path, _| bare.include?(path) }
    assert_equal({ "ec2" => 2, "s3" => 4 }, seats(sample))
  end

  ## sample_name

  def test_sample_names_are_the_path_and_never_too_long
    short = integ("aws-s3", "bucket")

    assert_equal "packages__@aws-cdk-testing__framework-integ__test__aws-s3__test__integ.bucket.js.snapshot__integ.bucket.template.json",
      Tools::Corpus.sample_name(short)

    long = "#{INTEG}/aws-ecs-patterns/test/fargate/#{"a-very-long-snapshot-name." * 4}js.snapshot/" \
      "integ.name.DefaultTestDeployAssert01234567.template.json"
    name = Tools::Corpus.sample_name(long)

    assert_operator name.bytesize, :<=, Tools::Corpus::NAME_LIMIT
    assert name.end_with?("DefaultTestDeployAssert01234567.template.json")
    assert_equal name, Tools::Corpus.sample_name(long)
    refute_equal name, Tools::Corpus.sample_name(long.sub("01234567", "89abcdef"))
    refute_equal Tools::Corpus.sample_name(integ("aws-s3", "a")), Tools::Corpus.sample_name(integ("aws-sqs", "a"))
  end

  ## templates_in, load and each_sample_template

  def test_templates_in_lists_the_templates_below_a_directory
    Dir.mktmpdir do |root|
      paths = [ integ("aws-s3", "a"), "packages/aws-cdk-lib/aws-s3/test/b.template.json" ]
      write_templates(root, paths)
      write_templates(root, [ "packages/aws-s3/test/asset.json" ])
      FileUtils.mkdir_p(File.join(root, "a-directory.template.json"))

      listed = Tools::Corpus.templates_in(root)

      assert_equal paths.sort, listed.keys
      assert_equal File.join(root, paths.first), listed[paths.first]
      assert listed.values.all? { |file| File.file?(file) }
    end
  end

  def test_templates_in_does_not_read_through_a_link
    Dir.mktmpdir do |root|
      outside = File.join(root, "outside.json")
      File.write(outside, "{}")
      begin
        File.symlink(outside, File.join(root, "link.template.json"))
      rescue SystemCallError, NotImplementedError
        skip "this system does not let the test make a symbolic link"
      end

      assert_empty Tools::Corpus.templates_in(root)
    end
  end

  def test_load_parses_a_template
    Dir.mktmpdir do |root|
      file = File.join(root, "a.template.json")
      File.write(file, '{"Description": "caf\u00e9"}')

      assert_equal({ "Description" => "café" }, Tools::Corpus.load(file))

      File.write(file, "{ not json")
      assert_raises(JSON::ParserError) { Tools::Corpus.load(file) }
    end
  end

  def test_each_sample_template_is_an_enumerator_without_a_block
    enumerator = Tools::Corpus.each_sample_template
    files = enumerator.to_a

    assert_kind_of Enumerator, enumerator
    assert_equal files.sort, files
    assert files.any?
    assert files.all? { |file| file.start_with?("#{Tools::Corpus::TEMPLATES}/") && file.end_with?(Tools::Corpus::SUFFIX) }
  end

  ## write_sample

  def test_write_sample_writes_the_sample_and_its_meta
    Dir.mktmpdir do |dir|
      paths = corpus("aws-ec2" => 12, "aws-s3" => 6, "aws-signer" => 5, "aws-chatbot" => 2)
      templates = write_templates(File.join(dir, "cdk"), paths)
      destination = File.join(dir, "fixtures")

      report = Tools::Corpus.write_sample(destination:, templates:, commit: COMMIT, date: "2026-11-20", count: 10)

      sample = Tools::Corpus.select_sample(paths, count: 10)
      expected = sample.map { |path, service| "#{service}/#{Tools::Corpus.sample_name(path)}" }
      written = Dir.glob("**/*#{Tools::Corpus::SUFFIX}", base: File.join(destination, "templates")).sort
      assert_equal expected.sort, written
      sample.each do |path, service|
        file = File.join(destination, "templates", service, Tools::Corpus.sample_name(path))
        assert_equal File.binread(templates.fetch(path)), File.binread(file), path
      end

      meta = JSON.parse(File.read(File.join(destination, "META.json")))
      assert_equal meta, report[:meta]
      assert_equal [ COMMIT, "2026-11-20" ], meta.values_at("commit", "date")
      assert_equal [ 25, 25, 1, 0, 0 ], meta["corpus"].values_at("templates", "framework_integ", "resource_types", "without_resources", "unparseable")
      assert_equal paths.sum { |path| File.size(templates.fetch(path)) }, meta["corpus"]["bytes"]
      assert_equal({ "chatbot" => 2, "ec2" => 12, "s3" => 6, "signer" => 5 }, meta["corpus"]["services"])
      assert_equal [ 10, 1, 0, 1 ], meta["sample"].values_at("templates", "resource_types", "without_resources", "without_resources_cap")
      assert_equal seats(sample).sort, meta["sample"]["services"].sort
      assert_equal({ written: 10, rewritten: 0, unchanged: 0 }, report[:files])
      assert report[:meta_written]
      assert_empty report[:stale]
    end
  end

  def test_write_sample_caps_the_templates_without_resources_and_says_so
    Dir.mktmpdir do |dir|
      source = File.join(dir, "cdk")
      stacks = corpus("aws-ec2" => 60, "aws-s3" => 30)
      bare = stacks.each_slice(3).map(&:last)
      templates = write_templates(source, stacks - bare).merge(
        write_templates(source, bare, body: '{"Parameters":{"BootstrapVersion":{"Type":"String"}},"Rules":{}}'))
      destination = File.join(dir, "fixtures")

      report = Tools::Corpus.write_sample(destination:, templates:, commit: COMMIT, date: "2026-11-20", count: 40)

      sample = report[:meta]["sample"]
      assert_equal [ 40, 5, 5, 1 ], sample.values_at("templates", "without_resources", "without_resources_cap", "resource_types")
      # One seat to each service, then 38 in proportion to 60 and 30: 25 and 12, and the one left
      # to the larger remainder. The cap moves nothing between services.
      assert_equal({ "ec2" => 26, "s3" => 14 }, sample["services"])
      assert_equal 30, report[:meta]["corpus"]["without_resources"]
      assert_equal 5, sample["without_resources_cap"] # 50 of every 400
      assert_equal Tools::Corpus::WITHOUT_RESOURCES_CAP_REASON, sample["without_resources_cap_reason"]
      files = Tools::Corpus.each_sample_template(File.join(destination, "templates")).to_a
      assert_equal 5, files.count { |file| Tools::Corpus.load(file).keys.sort == %w[Parameters Rules] }
    end
  end

  def test_a_second_run_writes_nothing
    Dir.mktmpdir do |dir|
      templates = write_templates(File.join(dir, "cdk"), measured_corpus)
      destination = File.join(dir, "fixtures")
      arguments = { destination:, templates:, commit: COMMIT, date: "2026-11-20", count: 12 }
      Tools::Corpus.write_sample(**arguments)
      watched = lambda do
        (Tools::Corpus.each_sample_template(File.join(destination, "templates")).to_a + [ File.join(destination, "META.json") ])
          .to_h { |file| [ file, state(file) ] }
      end
      before = watched.call

      report = Tools::Corpus.write_sample(**arguments)

      assert_equal({ written: 0, rewritten: 0, unchanged: 12 }, report[:files])
      refute report[:meta_written]
      assert_equal before, watched.call
    end
  end

  def test_only_the_template_that_changed_upstream_is_rewritten
    Dir.mktmpdir do |dir|
      templates = write_templates(File.join(dir, "cdk"), measured_corpus)
      destination = File.join(dir, "fixtures")
      arguments = { destination:, templates:, commit: COMMIT, date: "2026-11-20", count: 12 }
      Tools::Corpus.write_sample(**arguments)
      files = Tools::Corpus.each_sample_template(File.join(destination, "templates")).to_a
      mtimes = files.to_h { |file| [ file, File.mtime(file) ] }
      path, service = Tools::Corpus.select_sample(templates.keys, count: 12).first
      # Another logical ID for the same resource type, in the same number of bytes: META.json,
      # which counts bytes and resource types, has no reason to move.
      File.write(templates.fetch(path), '{"Resources":{"Q":{"Type":"AWS::S3::Bucket"}}}')
      changed = File.join(destination, "templates", service, Tools::Corpus.sample_name(path))

      report = Tools::Corpus.write_sample(**arguments)

      assert_equal({ written: 0, rewritten: 1, unchanged: 11 }, report[:files])
      refute report[:meta_written]
      assert_equal '{"Resources":{"Q":{"Type":"AWS::S3::Bucket"}}}', File.binread(changed)
      mtimes.reject { |file, _| file == changed }.each { |file, mtime| assert_equal mtime, File.mtime(file), file }
    end
  end

  def test_meta_json_follows_the_commit_and_not_the_clock
    Dir.mktmpdir do |dir|
      templates = write_templates(File.join(dir, "cdk"), measured_corpus)
      destination = File.join(dir, "fixtures")
      Tools::Corpus.write_sample(destination:, templates:, commit: COMMIT, date: "2026-11-20", count: 12)
      meta_file = File.join(destination, "META.json")
      mtimes = Tools::Corpus.each_sample_template(File.join(destination, "templates")).to_h { |file| [ file, File.mtime(file) ] }
      first = File.binread(meta_file)

      # The date is the commit's: the same commit written again gives the same bytes.
      again = Tools::Corpus.write_sample(destination:, templates:, commit: COMMIT, date: "2026-11-20", count: 12)
      refute again[:meta_written]
      assert_equal first, File.binread(meta_file)

      moved = Tools::Corpus.write_sample(destination:, templates:, commit: "f" * 40, date: "2026-11-21", count: 12)
      assert moved[:meta_written]
      assert_equal({ written: 0, rewritten: 0, unchanged: 12 }, moved[:files])
      assert_equal [ "f" * 40, "2026-11-21" ], JSON.parse(File.binread(meta_file)).values_at("commit", "date")
      mtimes.each { |file, mtime| assert_equal mtime, File.mtime(file), file }
    end
  end

  def test_what_is_not_in_the_sample_is_left_alone
    Dir.mktmpdir do |dir|
      templates = write_templates(File.join(dir, "cdk"), measured_corpus)
      destination = File.join(dir, "fixtures")
      stale = File.join(destination, "templates", "ec2", "packages__old.template.json")
      readme = File.join(destination, "README.md")
      FileUtils.mkdir_p(File.dirname(stale))
      File.write(stale, "left by an earlier sample")
      File.write(readme, "not a template")
      before = [ stale, readme ].to_h { |file| [ file, state(file) ] }

      report = Tools::Corpus.write_sample(destination:, templates:, commit: COMMIT, date: "2026-11-20", count: 5)

      assert_equal before, [ stale, readme ].to_h { |file| [ file, state(file) ] }
      assert_equal [ "ec2/packages__old.template.json" ], report[:stale]
      assert_equal 5, report[:files].values.sum
    end
  end

  def test_a_file_that_does_not_parse_is_left_out_and_counted
    Dir.mktmpdir do |dir|
      source = File.join(dir, "cdk")
      templates = write_templates(source, corpus("aws-ec2" => 10, "aws-signer" => 6))
      broken = templates.keys.first(2)
      File.write(templates.fetch(broken.first), "{ not json")
      File.write(templates.fetch(broken.last), "[1, 2, 3]")
      File.binwrite(templates.fetch(templates.keys.last), "\xFF\xFE{".b)
      # A stack with Parameters and Rules and no Resources is a template. It stays in.
      templates.merge!(write_templates(source, (1..5).map { |index| integ("aws-signer", "assert-#{index}") },
        body: '{"Parameters":{"BootstrapVersion":{"Type":"String"}},"Rules":{}}'))
      destination = File.join(dir, "fixtures")

      report = Tools::Corpus.write_sample(destination:, templates:, commit: COMMIT, date: "2026-11-20", count: 21)

      assert_equal({ written: 18, rewritten: 0, unchanged: 0 }, report[:files])
      assert_equal({ "ec2" => 8, "signer" => 10 }, report[:meta]["sample"]["services"])
      # The whole corpus fits, so there was no cap to apply and none to record.
      refute report[:meta]["sample"].key?("without_resources_cap")
      assert_equal 3, report[:meta]["corpus"]["unparseable"]
      assert_equal 5, report[:meta]["sample"]["without_resources"]
      assert_equal 1, report[:meta]["sample"]["resource_types"]
      files = Dir.glob("**/*", base: File.join(destination, "templates")).select { |file| File.file?(File.join(destination, "templates", file)) }
      assert_equal 18, files.size
      assert files.none? { |file| [ "{ not json", "[1, 2, 3]" ].include?(File.read(File.join(destination, "templates", file))) }
    end
  end

  ## The committed sample

  def test_the_committed_sample_is_what_meta_json_describes
    meta = JSON.parse(File.read(Tools::Corpus::META))
    sample = meta.fetch("sample")
    files = Tools::Corpus.each_sample_template.to_a

    assert_equal [ "META.json", "templates" ], Dir.children(Tools::Corpus::FIXTURES).sort
    assert_equal Tools::Corpus::DEFAULT_COUNT, sample["templates"]
    assert_equal sample["templates"], files.size
    assert_equal sample["bytes"], files.sum { |file| File.size(file) }
    assert_equal sample["services"], files.map { |file| File.basename(File.dirname(file)) }.tally.sort.to_h
    assert files.all? { |file| File.basename(file).bytesize <= Tools::Corpus::NAME_LIMIT }
    assert_match(/\A[0-9a-f]{40}\z/, meta["commit"])
    assert_match(/\A\d{4}-\d{2}-\d{2}\z/, meta["date"])

    # Every file is a template that parses. Most of the CDK's integration tests deploy a second
    # stack, the assertion stack, that holds Parameters and Rules and no Resources; a few of
    # their stacks under test deploy nothing either. META.json counts them: without_resources.
    templates = files.to_h { |file| [ file, Tools::Corpus.load(file) ] }
    assert templates.values.all?(Hash)
    without = templates.reject { |_, template| template.key?("Resources") }
    assert_equal sample["without_resources"], without.size,
      "templates without a Resources key on disk, and in META.json: #{without.keys.first(3).map { |file| File.basename(file) }.inspect}"
    assert without.values.all? { |template| (template.keys - %w[Outputs Parameters Rules]).empty? && template.keys.any? },
      "a template without a Resources key that holds more than Parameters, Rules and Outputs: #{without.reject { |_, template| (template.keys - %w[Outputs Parameters Rules]).empty? }.keys.first(3).inspect}"

    # The sample does not let them take a third of its seats, and it still represents every
    # service that has MIN_STRATUM templates in the corpus.
    assert_operator sample["without_resources"], :<=, sample["without_resources_cap"]
    assert_equal Tools::Corpus::WITHOUT_RESOURCES_CAP, sample["without_resources_cap"]
    assert_equal Tools::Corpus::WITHOUT_RESOURCES_CAP_REASON, sample["without_resources_cap_reason"]
    assert_equal sample["services"].values.sum, sample["templates"]
    assert_empty meta["corpus"]["services"].select { |_, count| count >= Tools::Corpus::MIN_STRATUM }.keys - sample["services"].keys
    # The names are paths with every "/" doubled, and the long ones carry a digest of their path.
    names = files.map { |file| File.basename(file) }
    assert names.all? { |name| name.end_with?(Tools::Corpus::SUFFIX) && name.include?("__") }
    assert names.any? { |name| name.start_with?("packages__") }
    assert names.any? { |name| name.match?(/\A[0-9a-f]{8}__/) }
    assert_equal names.size, names.map(&:downcase).uniq.size

    types = templates.values.flat_map { |template| Tools::Corpus.resource_types(template) }.uniq
    assert_equal sample["resource_types"], types.size

    megabytes = ->(bytes) { format("%.2f MB", bytes / 1e6) }
    puts
    puts "corpus sample: #{sample["templates"]} templates, #{sample["bytes"]} bytes (#{megabytes.call(sample["bytes"])}), " \
      "#{sample["resource_types"]} distinct resource types, #{sample["services"].size} services, " \
      "#{without.size} without a Resources key (at most #{sample["without_resources_cap"]})"
    puts "corpus sample, most templates per service: " \
      "#{sample["services"].sort_by { |service, count| [ -count, service ] }.first(5).map { |service, count| "#{service} #{count}" }.join(", ")}"
    puts "corpus: #{meta["corpus"]["templates"]} templates, #{meta["corpus"]["bytes"]} bytes (#{megabytes.call(meta["corpus"]["bytes"])}), " \
      "#{meta["corpus"]["resource_types"]} distinct resource types, #{meta["corpus"]["services"].size} services, " \
      "aws/aws-cdk@#{meta["commit"][0, 12]} of #{meta["date"]}"
  end
end
