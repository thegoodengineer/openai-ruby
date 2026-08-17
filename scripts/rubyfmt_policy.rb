# frozen_string_literal: true

require_relative "rubocop_directive_guard"

module RubyfmtPolicy
  ROOT = File.expand_path("..", __dir__)

  # rubyfmt 0.14.1 produces invalid Ruby for the guarded `in` clause in
  # responses.rb and the nested hash-pattern predicate in base_model_test.rb.
  # Each file explains the exact bug and when its temporary exemption can go.
  EXEMPTIONS = %w[
    lib/openai/resources/responses.rb
    test/openai/internal/type/base_model_test.rb
  ]
    .map { File.join(ROOT, _1) }
    .freeze

  module_function

  def paths(inputs = ["."])
    return [] if inputs.empty?

    RuboCopDirectiveGuard.rubocop_target_paths(inputs).reject { _1.end_with?(".rbi") }
  end

  def violations(paths)
    paths.filter_map do |path|
      # Match rubyfmt's first magic header in the first 500 bytes.
      header = File.binread(path, 500).force_encoding(Encoding::UTF_8).scrub
      enabled = header[/^#\s*rubyfmt:\s*(true|false)\s*$/, 1]
      next unless enabled == "false"
      next if EXEMPTIONS.include?(File.expand_path(path))

      "#{path}: rubyfmt opt-out is not an approved formatter-bug exemption"
    end
  end
end
