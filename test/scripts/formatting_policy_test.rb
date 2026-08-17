# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rubocop"
require "tmpdir"

class FormattingPolicyTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  STYLE_SAFETY_COPS = %w[
    Style/FrozenStringLiteralComment
    Style/MissingRespondToMissing
    Style/MutableConstant
  ].freeze

  def test_rubocop_preserves_safety_checks_without_enforcing_layout
    config = RuboCop::ConfigStore.new.for_dir(ROOT)
    enabled = RuboCop::Cop::Registry.global.enabled(config).map(&:cop_name)

    formatting = enabled.grep(/\A(?:Layout|Metrics|Naming|Style)\//)
    assert_equal(STYLE_SAFETY_COPS, formatting.sort)
    %w[
      Bundler/DuplicatedGem
      Bundler/InsecureProtocolSource
      Gemspec/DuplicatedAssignment
      Gemspec/RequiredRubyVersion
      Gemspec/RequireMFA
      Lint/Syntax
      Security/Eval
      Security/IoMethods
    ]
      .each { assert_includes(enabled, _1) }
    refute_includes(enabled, "Bundler/OrderedGems")
    refute_includes(enabled, "Gemspec/OrderedDependencies")
    assert_equal("disable", config["AllCops"]["NewCops"])

    # A RuboCop upgrade must make an explicit decision about new safety cops.
    RuboCop::ConfigLoader.default_configuration.each do |name, options|
      next unless name.match?(/\A(?:Lint|Security)\//) && options["Enabled"] == "pending"

      assert_includes(enabled, name)
    end
  end

  def test_rubyfmt_is_enforced_and_idempotent
    Dir.mktmpdir do |directory|
      path = File.join(directory, "example with spaces.rb")
      source = "value={hello: 'world'}\n"
      File.write(path, source)
      paths = File.join(directory, "paths")
      File.write(paths, "#{path}\n")

      _stdout, _stderr, before = Open3.capture3(
        "bundle",
        "exec",
        "rake",
        "lint:rubyfmt",
        "FORMAT_FILE=#{paths}",
        chdir: ROOT
      )
      refute(before.success?, "unformatted source should fail the CI formatting check")

      stdout, stderr, status = Open3.capture3(
        "bundle",
        "exec",
        "rake",
        "format:rb",
        "FORMAT_FILE=#{paths}",
        chdir: ROOT
      )

      assert(status.success?, "#{stdout}\n#{stderr}")
      formatted = File.read(path)
      refute_equal(source, formatted)
      stdout, stderr, status = Open3.capture3(
        "bundle",
        "exec",
        "rake",
        "lint:rubyfmt",
        "FORMAT_FILE=#{paths}",
        chdir: ROOT
      )
      assert(status.success?, "#{stdout}\n#{stderr}")
      stdout, stderr, status = Open3.capture3(
        "bundle",
        "exec",
        "rake",
        "format:rb",
        "FORMAT_FILE=#{paths}",
        chdir: ROOT
      )
      assert(status.success?, "#{stdout}\n#{stderr}")
      assert_equal(formatted, File.read(path))
    end
  end

  def test_native_exemption_preserves_patterns_affected_by_upstream_bugs
    Dir.mktmpdir do |directory|
      path = File.join(directory, "example.rb")
      source = "# rubyfmt: false\npredicate = -> { _1 in {a: [String]} }\n"
      File.write(path, source)
      stdout, stderr, status = Open3.capture3(
        "./scripts/rubyfmt",
        "--in-place",
        path,
        chdir: ROOT
      )
      assert(status.success?, "#{stdout}\n#{stderr}")
      assert_equal(source, File.read(path))
    end
  end
end
