# frozen_string_literal: true

require_relative "lib/quality_gate/version"

Gem::Specification.new do |spec|
  spec.name = "quality_gate"
  spec.version = QualityGate::VERSION
  spec.authors = ["Lucian Ghinda"]
  spec.email = ["lucianghinda@users.noreply.github.com"]

  spec.summary = "A layered quality gate for Ruby projects"
  spec.description = "One CLI and configuration contract for staged Ruby code-quality checks."
  spec.homepage = "https://github.com/lucianghinda/quality_gate"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Keep local state and internal development records out of public archives.
  spec.files = Dir.glob(
    %w[README.md LICENSE.txt CHANGELOG.md llm.txt
       docs/codex.md docs/incidents.md docs/dogfood-log.md docs/releasing.md
       lib/**/*.rb lib/**/*.tt config/*.yml exe/quality_gate sig/*.rbs],
    base: __dir__
  ).sort
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "brakeman", "~> 8.0"
  spec.add_dependency "bullet", "~> 8.2.0"
  spec.add_dependency "bundler-audit", "~> 0.9.3"
  spec.add_dependency "reek", "~> 6.5"
  spec.add_dependency "rubocop", "~> 1.90"
  spec.add_dependency "rubocop-minitest", "~> 0.40"
  spec.add_dependency "rubocop-performance", "~> 1.27"
  spec.add_dependency "rubocop-rails", "~> 2.37"
  spec.add_dependency "simplecov", "~> 1.1.1"
  spec.add_dependency "strong_migrations", "~> 2.5.2"
  spec.add_dependency "undercover", "~> 0.8.5"

  # For more information and examples about making a new gem, check out our
  # guide at: https://guides.rubygems.org/make-your-own-gem/
end
