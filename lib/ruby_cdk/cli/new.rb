# frozen_string_literal: true

require "fileutils"
require_relative "../version"
require_relative "failure"

module RubyCdk
  module Cli
    # `new`: the scaffold. `ruby-cdk new PROJECT` creates the directory PROJECT
    # with the smallest app that deploys: the app file (one App, one stack), the
    # stack (one parameter, one S3 bucket that stays private), a Gemfile, and
    # the two git files whose rules this tool depends on — `.gitattributes`
    # pins LF line endings, because they change an asset's hash (architecture
    # section 8), and `.gitignore` keeps the build output out.
    #
    # The CDK's init is the reference (aws/aws-cdk-cli at main,
    # packages/aws-cdk/lib/commands/init/init.ts and
    # packages/aws-cdk/lib/init-templates/app): one template, named `app` there
    # ("Template for a CDK Application", info.json), which writes the app file,
    # one stack class, an example test, .gitignore and a README of useful
    # commands; prints the project template's name and then the generated
    # README; refuses a directory that holds visible files
    # (assertIsEmptyDirectory, init.ts:747) ignoring dot-files as it ignores
    # them; and asks for a language when a template supports several
    # (resolveLanguage, init.ts:205), defaulting silently when it supports one.
    # This tool has one template and one language, and both answers are Ruby:
    # there is no --language and no --from to ask about. What the CDK runs
    # after the template (git init and the package manager's install) this
    # tool never runs — `lib/` starts no process — so the generated README
    # carries the two commands instead.
    module New
      # What PROJECT may be called: the raw material of a directory name, a
      # Ruby module and a stack name. Hyphens and underscores separate words;
      # letters and digits build them.
      NAME_PATTERN = /\A[A-Za-z][A-Za-z0-9_-]*\z/

      # The one template, as the CDK names its (init-templates/app/info.json).
      TEMPLATE = "app"

      # The one language, as the CDK's resolveLanguage defaults to a template's
      # only language (init.ts:218-223).
      LANGUAGE = "ruby"

      # project is the PROJECT word. Answers the exit code.
      def self.run(session, project)
        parts = parts_of(project, session.io)
        target = File.expand_path(parts.name, Dir.pwd)
        writable!(target, !!session.options.force, session.io)

        session.io.say("Applying project template #{TEMPLATE} for #{LANGUAGE} into #{parts.name}/")
        files_of(parts).each do |path, content|
          full = File.join(target, path)
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, content)
        end

        # The CDK prints the generated README after the template
        # (initializeProject, init.ts:729-733), and what it cannot run itself
        # as a "Please run" line (postInstallTypescript's no-network path).
        session.io.say(File.read(File.join(target, "README.md")))
        session.io.say("Please run `bundle install --local` in #{parts.name}: ruby-cdk is not on rubygems.org yet, " \
          "so the Gemfile resolves from the gem installed on this machine.")
        session.io.say("All done! #{parts.name}/README.md has the three commands: synth, deploy, destroy.")
        Cli::SUCCESS
      end

      # The name's three shapes, as the CDK's placeholders are three
      # (%name%, %name.PascalCased%, %name.StackName%): the directory is the
      # name as typed, because that is the directory the user asked for; the
      # Ruby files under it take the snake_case form, which a require_relative
      # reads; and the module is PascalCase. The stack name takes the typed
      # name with underscores as hyphens, because a stack name holds no
      # underscore (rule V13).
      Parts = Data.define(:name, :ns, :namespace, :stack_id)

      # Raises Cli::Usage when the name cannot become a project.
      def self.parts_of(project, io)
        name = project.to_s.strip
        if name.empty?
          raise Usage.new("Name the project directory: `ruby-cdk new NAME` creates it with the app scaffold.",
            next_step: "Run `ruby-cdk new NAME` again, for example `ruby-cdk new my-app`.")
        end
        unless NAME_PATTERN.match?(name)
          raise Usage.new("#{name.inspect} is not a project name: a name holds letters, digits, \"_\" and \"-\", " \
            "and starts with a letter.",
            next_step: "Run `ruby-cdk new NAME` again, for example `ruby-cdk new my-app`.")
        end

        words = name.gsub(/([A-Z\d]+)([A-Z][a-z])/, '\1_\2')
          .gsub(/([a-z\d])([A-Z])/, '\1_\2')
          .tr("-", "_")
          .downcase
          .split("_")
        mod = words.map(&:capitalize).join
        if mod == "Stack" || Object.const_defined?(mod)
          raise Usage.new("#{name.inspect} would define the module #{mod}, and that name is taken or would collide " \
            "with the stack class the scaffold puts inside it.",
            next_step: "Run `ruby-cdk new NAME` again with a different name.")
        end

        parts = Parts.new(name: name, ns: words.join("_"), namespace: mod, stack_id: name.tr("_", "-"))
        io.debug("project #{parts.name}: module #{parts.namespace}, stack #{parts.stack_id}")
        parts
      end

      # The CDK refuses a directory that exists and holds visible files, and
      # ignores dot-files when it counts (init.ts:752-755). It also refuses one
      # that does not exist and asks to `mkdir -p` it first (init.ts:756-762);
      # this command is named by the directory, so it creates it, and `--force`
      # is the answer for a directory someone made already: an empty one may be
      # written into, one holding visible files is never overwritten.
      def self.writable!(target, force, io)
        unless File.exist?(target)
          io.debug("#{target} does not exist and will be created")
          return
        end
        raise Usage.new("#{target} exists and is not a directory.",
          next_step: "Run `ruby-cdk new NAME` again with a name that is free.") unless File.directory?(target)

        visible = Dir.children(target).reject { |entry| entry.start_with?(".") }
        if visible.empty?
          return true if force

          raise Usage.new("#{target} exists already. #{Dir.children(target).empty? ? "It is empty" : "It holds only dot-files"}, " \
            "and writing into an existing directory is refused unless --force says it was made for this.",
            next_step: "Run `ruby-cdk new NAME --force`, or choose a name that is free.")
        end

        raise Usage.new("`ruby-cdk new` cannot write into a non-empty directory! " \
          "Found #{visible.length} visible file(s) in #{target}:\n" +
          visible.map { |entry| "  - #{entry}" }.join("\n"),
          next_step: "Choose a name that is free: --force never overwrites files.")
      end

      # The generated files, each the whole of its content. Deterministic: the
      # same name and the same gem version write the same bytes, which the
      # tests hold to.
      def self.files_of(parts)
        {
          "cdk.rb" => app_file(parts),
          "#{parts.ns}/#{parts.ns}_stack.rb" => stack_file(parts),
          ".gitattributes" => <<~GIT_ATTRIBUTES,
            # One byte of one file changes an asset's hash, because the asset's
            # identity is the hash of its manifest, and a checkout that rewrites
            # line endings changes bytes. Every text file is stored with LF,
            # wherever the checkout happens.
            * text=auto eol=lf
          GIT_ATTRIBUTES
          ".gitignore" => <<~GIT_IGNORE,
            cdk.out/
            .bundle/
            vendor/
          GIT_IGNORE
          "Gemfile" => gemfile,
          "README.md" => readme(parts)
        }
      end

      def self.app_file(parts)
        <<~RUBY
          # frozen_string_literal: true

          # The app file. It requires the gem and creates exactly one RubyCdk::App;
          # the stack is a class of its own, so that it can be built here and
          # somewhere else, under another name.
          #
          # Run it with the command line, from this directory (see README.md):
          #
          #   bundle exec ruby-cdk synth
          #   bundle exec ruby-cdk deploy
          #   bundle exec ruby-cdk destroy
          require "ruby-cdk"
          require_relative "#{parts.ns}/#{parts.ns}_stack"

          # A stack without an env deploys wherever your credentials point, after
          # the command prints the target. To pin this app to one account and one
          # region, create the App with an env:
          #
          #   RubyCdk::App.new(env: RubyCdk::Env.new(account: "123456789012", region: "eu-central-1")) do |app|
          #     #{parts.namespace}::Stack.new(app, "#{parts.stack_id}")
          #   end
          RubyCdk::App.new do |app|
            #{parts.namespace}::Stack.new(app, "#{parts.stack_id}")
          end
        RUBY
      end

      def self.stack_file(parts)
        <<~RUBY
          # frozen_string_literal: true

          require "ruby-cdk"

          module #{parts.namespace}
            # One S3 bucket that stays private: public access blocked on all four
            # settings, and encrypted at rest.
            #
            # The bucket is an L1 resource, written with CloudFormation's own
            # property names. A parameter decides whether it keeps every version
            # of an object.
            class Stack < RubyCdk::Stack
              def build
                versioning = parameter("Versioning", type: "String", default: "Suspended",
                  allowed_values: [ "Suspended", "Enabled" ],
                  description: "Whether the bucket keeps every version of an object")

                resource("Bucket", "AWS::S3::Bucket", properties: {
                  "BucketEncryption" => {
                    "ServerSideEncryptionConfiguration" => [
                      { "ServerSideEncryptionByDefault" => { "SSEAlgorithm" => "AES256" } }
                    ]
                  },
                  "PublicAccessBlockConfiguration" => {
                    "BlockPublicAcls" => true,
                    "BlockPublicPolicy" => true,
                    "IgnorePublicAcls" => true,
                    "RestrictPublicBuckets" => true
                  },
                  "VersioningConfiguration" => { "Status" => Fn.ref(versioning) }
                })
              end
            end
          end
        RUBY
      end

      # The version, not a path: the README's install story is "build and
      # install the gem from source", so the gem is on this machine like any
      # installed gem, and a path would hard-wire a checkout that does not
      # exist anywhere else. `bundle install --local` resolves it today;
      # `bundle install` resolves the same line once a release is published.
      def self.gemfile
        <<~RUBY
          # frozen_string_literal: true

          source "https://rubygems.org"

          # ruby-cdk is not on rubygems.org yet: install it from source (the
          # ruby-cdk README's Install) and run `bundle install --local` in this
          # directory to resolve the line below from the installed gem. Once a
          # release is published, plain `bundle install` resolves it too.
          gem "ruby-cdk", "~> #{RubyCdk::VERSION}"
        RUBY
      end

      def self.readme(parts)
        <<~MARKDOWN
          # #{parts.stack_id}

          A ruby-cdk app: one stack with one S3 bucket that stays private —
          public access blocked on all four settings, encrypted at rest — and a
          parameter that decides whether the bucket keeps every version of an
          object.

          ## The three commands

          ```sh
          bundle install --local         # once, in this directory: see "The Gemfile"
          bundle exec ruby-cdk synth     # writes cdk.out/#{parts.stack_id}.template.json and prints the template
          bundle exec ruby-cdk deploy    # shows the change set, asks, then deploys it
          bundle exec ruby-cdk destroy   # prints what is kept, asks for the stack name, then deletes
          ```

          ## Deploy asks first

          `deploy` creates a change set, prints every change in it and the IAM
          capabilities it would add, and then asks:

          ```
          Deploy these changes to stack #{parts.stack_id} in account 123456789012 (eu-central-1)?
          ```

          Yes executes it; anything else deletes the change set, and a stack that
          was not created yet is deleted with it, so a refused deploy leaves
          nothing behind. In a script, `--yes` skips the question. `destroy`
          prints what the stack would keep and asks for the stack's name to be
          typed — a yes is not enough for an irreversible act.

          ## Where this stack deploys

          A stack without an `env` deploys wherever your credentials point, after
          the command prints the target. To pin the app, create the App with an
          env in `cdk.rb`:

          ```ruby
          RubyCdk::App.new(env: RubyCdk::Env.new(account: "123456789012", region: "eu-central-1")) do |app|
            #{parts.namespace}::Stack.new(app, "#{parts.stack_id}")
          end
          ```

          A stack with an `env` deploys only into that account and region. And
          when the stack grows an asset — `asset.zip`, the shape a Lambda's code
          takes — it needs a concrete env: the asset bucket's name is made of the
          account and the region, and synthesis never calls AWS to discover them.

          ## The Gemfile

          ruby-cdk is not on rubygems.org yet: install it from source (the
          ruby-cdk README's Install), then run `bundle install --local` here, which
          resolves `gem "ruby-cdk"` from the gem installed on this machine. Once a
          release is published, plain `bundle install` resolves the same line.

          ## Files

          - `cdk.rb` — the app file: one RubyCdk::App, one stack
          - `#{parts.ns}/#{parts.ns}_stack.rb` — the stack: one parameter, one S3 bucket
          - `.gitattributes` — line endings pinned to LF: they change an asset's hash
          - `.gitignore` — `cdk.out/`, `.bundle/`, `vendor/`
        MARKDOWN
      end
    end
  end
end
