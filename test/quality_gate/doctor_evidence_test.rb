# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "timeout"
require "tmpdir"
require "quality_gate/doctor_report"
require "quality_gate/doctor_git"
require "quality_gate/doctor_coverage"
require "quality_gate/doctor_hooks"

module QualityGate
  class DoctorEvidenceTest < Minitest::Test
    class BudgetDoctorGit < DoctorGit
      attr_accessor :clock
      attr_reader :capture_timeouts

      def initialize(**keywords)
        super
        @clock = 0
        @capture_timeouts = []
      end

      private

      def capture(argv, timeout_seconds, **options)
        @capture_timeouts << timeout_seconds
        @clock += 1.5
        super
      end
    end

    def test_doctor_report_check_api_is_available
      assert defined?(DoctorReport), "DoctorReport is provided by the core implementation"
      assert_respond_to DoctorReport, :check
    end

    def test_disabled_undercover_comparison_is_not_applicable
      with_host do |dir|
        report = DoctorGit.new(dir:, config: config_with(adapters: { verify: ["rubocop"] })).call

        assert_check report, "comparison", "not_applicable", /disabled/i
      end
    end

    def test_explicit_comparison_must_resolve_to_a_commit
      with_repository do |dir|
        report = DoctorGit.new(dir:, config: config_with(compare_point: "missing-ref")).call

        assert_check report, "comparison", "blocked", /commit|comparison/i
      end
    end

    def test_option_like_explicit_ref_is_rejected_before_git_runs
      with_repository do |dir|
        git_path = File.join(dir, "git")
        marker_path = File.join(dir, "git-was-called")
        write_git_sentinel(git_path, marker_path)

        with_path(dir) do
          report = DoctorGit.new(dir:, config: config_with(compare_point: "--help")).call

          assert_check report, "comparison", "blocked", /ref|comparison/i
          refute File.exist?(File.join(dir, "git-was-called"))
        end
      end
    end

    def test_automatic_comparison_without_repository_is_unchecked
      with_host do |dir|
        report = DoctorGit.new(dir:, config: config_with).call

        assert_check report, "comparison", "unchecked", /history|repository|comparison/i
      end
    end

    def test_missing_git_executable_blocks_explicit_comparison
      with_repository do |dir, commit|
        old_path = ENV.fetch("PATH")
        ENV["PATH"] = File.join(dir, "empty-bin")

        report = DoctorGit.new(dir:, config: config_with(compare_point: commit)).call

        assert_check report, "comparison", "blocked", /Git.*PATH|Git is unavailable/i
      ensure
        ENV["PATH"] = old_path
      end
    end

    def test_git_path_entries_resolve_from_project_root_outside_project
      with_repository do |dir, commit|
        caller = Dir.mktmpdir("doctor-caller")
        install_git_path_fixtures(dir, caller)
        original_dir = Dir.pwd

        assert_rooted_git_path(dir, caller, commit, "bin")
        assert_rooted_git_path(dir, caller, commit, ":bin")
        assert_equal original_dir, Dir.pwd
        refute File.exist?(File.join(caller, "wrong-git-ran"))
        refute File.exist?(File.join(caller, "bin/wrong-git-ran"))
      end
    end

    def test_absent_path_leaves_git_availability_ambiguous
      with_repository do |dir, commit|
        old_path = ENV.delete("PATH")
        report = DoctorGit.new(dir:, config: config_with(compare_point: commit)).call

        assert_check report, "comparison", "unchecked", /PATH.*absent|ambiguous/i
      ensure
        ENV["PATH"] = old_path
      end
    end

    def test_explicit_comparison_is_checked_without_changing_caller_directory
      with_repository do |dir, commit|
        caller_dir = Dir.pwd
        report = DoctorGit.new(dir:, config: config_with(compare_point: commit)).call

        assert_check report, "comparison", "ready", /commit/i
        assert_equal caller_dir, Dir.pwd
      end
    end

    def test_git_budget_is_shared_by_explicit_validation_and_automatic_resolution
      with_repository do |dir, _commit|
        probe = BudgetDoctorGit.new(dir:, config: config_with)
        monotonic = ->(_clock) { probe.clock }

        Process.stub(:clock_gettime, monotonic) do
          report = probe.call
          assert_check report, "comparison", "unchecked", /budget|history|comparison/i
        end

        assert_shared_git_budget(probe.capture_timeouts)
      end
    end

    def test_undercover_coverage_artifact_is_read_only_and_requires_expected_mapping
      with_host do |dir|
        path = File.join(dir, "coverage/coverage.json")
        FileUtils.mkdir_p(File.dirname(path))
        contents = JSON.generate("meta" => {}, "coverage" => {})
        File.write(path, contents)
        before = File.binread(path)

        report = DoctorCoverage.new(dir:, config: config_with(adapters: { verify: ["undercover"] })).call

        assert_check report, "coverage.undercover", "ready", /read|structured|evidence/i
        assert_equal before, File.binread(path)
      end
    end

    def test_missing_coverage_is_unchecked_before_initial_suite
      with_host do |dir|
        report = DoctorCoverage.new(dir:, config: config_with(adapters: { verify: ["undercover"] })).call

        assert_check report, "coverage.undercover", "unchecked", /verify|suite|missing/i
      end
    end

    def test_malformed_coverage_shape_is_warning
      with_coverage("undercover", "[]") do |dir|
        report = DoctorCoverage.new(dir:, config: config_with(adapters: { verify: ["undercover"] })).call

        assert_check report, "coverage.undercover", "warning", /shape|mapping|structured/i
      end
    end

    def test_malformed_coverage_json_is_warning
      with_coverage("undercover", "{broken") do |dir|
        report = DoctorCoverage.new(dir:, config: config_with(adapters: { verify: ["undercover"] })).call

        assert_check report, "coverage.undercover", "warning", /malformed|JSON/i
      end
    end

    def test_oversized_coverage_artifact_is_unchecked
      with_host do |dir|
        path = File.join(dir, "coverage/coverage.json")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "x" * (1024 * 1024 + 1))
        oversized = DoctorCoverage.new(dir:, config: config_with(adapters: { verify: ["undercover"] })).call
        assert_check oversized, "coverage.undercover", "unchecked", /size|large|bounded/i
      end
    end

    def test_symlink_coverage_artifact_is_unchecked
      with_host do |dir|
        path = File.join(dir, "coverage/coverage.json")
        FileUtils.mkdir_p(File.dirname(path))
        target = File.join(dir, "elsewhere.json")
        File.write(target, JSON.generate("meta" => {}, "coverage" => {}))
        File.symlink(target, path)
        linked = DoctorCoverage.new(dir:, config: config_with(adapters: { verify: ["undercover"] })).call
        assert_check linked, "coverage.undercover", "unchecked", /symlink|safe|regular/i
      end
    end

    def test_fifo_coverage_artifact_is_unchecked_without_blocking
      with_host do |dir|
        path = File.join(dir, "coverage/coverage.json")
        FileUtils.mkdir_p(File.dirname(path))
        system("mkfifo", path, exception: true)

        report = Timeout.timeout(1) do
          DoctorCoverage.new(dir:, config: config_with(adapters: { verify: ["undercover"] })).call
        end

        assert_check report, "coverage.undercover", "unchecked", /regular|safe|read/i
      end
    end

    def test_simplecov_requires_finite_line_and_configured_branch_percentages
      report = simplecov_report({ "line" => 101, "branch" => 90 }, budgets: { minimum_line: 80, minimum_branch: 50 })

      assert_check report, "coverage.simplecov", "warning", /shape|structured/i
    end

    def test_simplecov_valid_line_and_invalid_branch_is_warning_when_branch_is_budgeted
      report = simplecov_report({ "line" => 90, "branch" => "90" }, budgets: { minimum_line: 80, minimum_branch: 50 })

      assert_check report, "coverage.simplecov", "warning", /shape|structured/i
    end

    def test_simplecov_valid_line_and_missing_branch_is_warning_when_branch_is_budgeted
      report = simplecov_report({ "line" => 90 }, budgets: { minimum_line: 80, minimum_branch: 50 })

      assert_check report, "coverage.simplecov", "warning", /shape|structured/i
    end

    def test_simplecov_valid_line_and_branch_are_ready_when_branch_is_budgeted
      report = simplecov_report({ "line" => 90, "branch" => 75 }, budgets: { minimum_line: 80, minimum_branch: 50 })

      assert_check report, "coverage.simplecov", "ready", /structured evidence only/i
    end

    def test_simplecov_line_only_budget_does_not_require_branch_percentage
      report = simplecov_report({ "line" => 90 }, budgets: { minimum_line: 80 })

      assert_check report, "coverage.simplecov", "ready", /structured evidence only/i
    end

    def test_unreadable_coverage_artifact_is_unchecked
      with_host do |dir|
        path = File.join(dir, "coverage/coverage.json")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.generate("meta" => {}, "coverage" => {}))
        config = config_with(adapters: { verify: ["undercover"] })

        report = File.stub(:open, ->(*) { raise Errno::EACCES }) do
          DoctorCoverage.new(dir:, config:).call
        end

        assert_check report, "coverage.undercover", "unchecked", /read safely|permissions/i
      end
    end

    def test_no_relevant_coverage_adapters_is_not_applicable
      with_host do |dir|
        report = DoctorCoverage.new(dir:, config: config_with(adapters: { verify: ["rubocop"] })).call

        assert_check report, "coverage", "not_applicable", /coverage|adapter/i
      end
    end

    def test_absent_hooks_and_history_are_not_applicable
      with_host do |dir|
        report = DoctorHooks.new(dir:).call

        assert_check report, "hooks", "not_applicable", /hook|history/i
      end
    end

    def test_installed_hook_without_history_is_unchecked
      with_host do |dir|
        hook_path = File.join(dir, ".claude/hooks/quality_gate_fast.rb")
        FileUtils.mkdir_p(File.dirname(hook_path))
        File.write(hook_path, "# installed hook\n")

        report = DoctorHooks.new(dir:).call

        assert_check report, "hooks", "unchecked", /history|log/i
      end
    end

    def test_unavailable_hook_history_is_warning
      with_host do |dir|
        log_path = File.join(dir, "log/quality_gate_hooks.jsonl")
        write_hook_log(log_path, "unavailable")
        unavailable = DoctorHooks.new(dir:).call
        assert_check unavailable, "hooks", "warning", /bundle|hook|inspect/i
      end
    end

    def test_clean_hook_history_is_scoped_ready_and_read_only
      with_host do |dir|
        log_path = File.join(dir, "log/quality_gate_hooks.jsonl")
        content = JSON.generate(hook_record("clean")) << "\n"
        FileUtils.mkdir_p(File.dirname(log_path))
        File.binwrite(log_path, content)
        clean = DoctorHooks.new(dir:).call
        assert_check clean, "hooks", "ready", /histor|recent/i
        assert_equal content, File.binread(log_path)
      end
    end

    def test_unsafe_hook_log_symlink_is_unchecked
      with_host do |dir|
        path = File.join(dir, "log/quality_gate_hooks.jsonl")
        FileUtils.mkdir_p(File.dirname(path))
        target = File.join(dir, "elsewhere.jsonl")
        File.write(target, JSON.generate(hook_record("clean")) << "\n")
        File.symlink(target, path)

        report = DoctorHooks.new(dir:).call

        assert_check report, "hooks", "unchecked", /unsafe|unreadable/i
      end
    end

    def test_empty_and_corrupt_hook_history_are_unchecked
      with_host do |dir|
        path = File.join(dir, "log/quality_gate_hooks.jsonl")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "")
        empty = DoctorHooks.new(dir:).call
        assert_check empty, "hooks", "unchecked", /valid|history|record/i

        File.write(path, "{broken\n")
        corrupt = DoctorHooks.new(dir:).call
        assert_check corrupt, "hooks", "unchecked", /valid|history|record/i
      end
    end

    private

    def config_with(**overrides)
      defaults = Config.defaults.merge(adapters: { fast: ["rubocop"], verify: ["undercover"], audit: [] })
      Config.new(defaults.merge(overrides))
    end

    def with_host
      Dir.mktmpdir("doctor-host") { yield _1 }
    end

    def with_coverage(adapter, contents)
      with_host do |dir|
        relative = adapter == "undercover" ? "coverage/coverage.json" : "coverage/.last_run.json"
        path = File.join(dir, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, contents)
        yield dir
      end
    end

    def simplecov_report(result, budgets:)
      report = nil
      with_coverage("simplecov", JSON.generate("result" => result)) do |dir|
        config = config_with(adapters: { verify: ["simplecov"] }, coverage: budgets)
        report = DoctorCoverage.new(dir:, config:).call
      end
      report
    end

    def with_repository
      with_host do |dir|
        git!("-C", dir, "init", "--quiet", "--initial-branch=main")
        git!("-C", dir, "config", "user.email", "doctor@example.test")
        git!("-C", dir, "config", "user.name", "Doctor Test")
        File.write(File.join(dir, "file.rb"), "# host\n")
        git!("-C", dir, "add", "file.rb")
        git!("-C", dir, "commit", "--quiet", "-m", "initial")
        commit = git!("-C", dir, "rev-parse", "HEAD").strip
        yield dir, commit
      end
    end

    def git!(*argv)
      stdout, stderr, status = Open3.capture3("git", *argv)
      assert status.success?, "git #{argv.join(" ")} failed: #{stderr}"
      stdout
    end

    def hook_record(outcome)
      { "ts" => "2026-10-02T00:00:00Z", "file" => "file.rb", "outcome" => outcome, "duration_ms" => 1 }
    end

    def write_hook_log(path, outcome)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate(hook_record(outcome)) << "\n")
    end

    def assert_check(checks, id, status, message_pattern)
      check = checks.find { _1.fetch("id") == id }
      refute_nil check, "missing #{id} check: #{checks.inspect}"
      assert_record(check, status, message_pattern)
    end

    def assert_record(check, status, message_pattern)
      assert_equal status, check.fetch("status")
      assert_match message_pattern, check.fetch("message")
      assert_frozen_record(check)
    end

    def assert_frozen_record(check)
      assert_equal %w[id message status], check.keys.sort
      assert check.frozen? && check.values.all?(&:frozen?)
    end

    def assert_shared_git_budget(timeouts)
      assert_equal 4, timeouts.length
      assert_equal(true, timeouts.each_cons(2).all? { _1 > _2 })
      assert_operator timeouts.last, :<, 1
    end

    def write_git_sentinel(path, marker)
      File.write(path, "#!#{RbConfig.ruby}\nFile.write(#{marker.inspect}, \"called\")\n")
      File.chmod(0o755, path)
    end

    def with_path(path)
      old_path = ENV.fetch("PATH")
      ENV["PATH"] = path
      yield
    ensure
      ENV["PATH"] = old_path
    end

    def install_git_path_fixtures(dir, caller)
      real_git = ENV.fetch("PATH").split(File::PATH_SEPARATOR).map { File.join(_1, "git") }
                    .find { File.file?(_1) && File.executable?(_1) }
      File.symlink(real_git, File.join(dir, "git"))
      FileUtils.mkdir_p(File.join(dir, "bin"))
      File.symlink(real_git, File.join(dir, "bin/git"))
      install_wrong_git(caller)
    end

    def install_wrong_git(caller)
      FileUtils.mkdir_p(File.join(caller, "bin"))
      write_git_sentinel(File.join(caller, "git"), File.join(caller, "wrong-git-ran"))
      write_git_sentinel(File.join(caller, "bin/git"), File.join(caller, "bin/wrong-git-ran"))
    end

    def assert_rooted_git_path(dir, caller, commit, path)
      with_path(path) do
        report = Dir.chdir(caller) do
          DoctorGit.new(dir:, config: config_with(compare_point: commit)).call
        end
        assert_check report, "comparison", "ready", /commit/i
      end
    end
  end

  class DoctorEvidenceRaceTest < Minitest::Test
    class ExpiringDoctorGit < DoctorGit
      attr_reader :clock, :capture_timeouts

      def initialize(**keywords)
        super
        @clock = 0
        @capture_timeouts = []
      end

      private

      def capture(argv, timeout_seconds, **options)
        @capture_timeouts << timeout_seconds
        @clock += 5.1
        super
      end
    end

    def test_growth_during_read_never_reads_past_one_mebibyte
      with_regular_coverage do |path|
        writer = File.open(path, "r+")
        requested_lengths = []
        result = with_open_interception(path) do |io, read_block|
          intercept_read_growth(io, writer, requested_lengths, read_block)
        end

        assert_equal :oversized, result.status
        assert_equal [DoctorBoundedFile::MAX_BYTES], requested_lengths
      ensure
        writer&.close
      end
    end

    def test_replacing_regular_file_before_open_is_unchecked
      with_regular_coverage do |path|
        replacement = File.join(File.dirname(path), "replacement.json")
        File.write(replacement, JSON.generate("meta" => {}, "coverage" => {}))
        result = with_open_interception(path) do |io, read_block|
          File.rename(path, "#{path}.old")
          File.rename(replacement, path)
          read_block.call(io)
        end

        assert_equal :unsafe, result.status
      end
    end

    def test_replacing_regular_file_during_read_is_unchecked
      with_regular_coverage do |path|
        replacement = File.join(File.dirname(path), "replacement.json")
        File.write(replacement, JSON.generate("meta" => {}, "coverage" => {}))
        result = with_open_interception(path) do |io, read_block|
          replace_file_after_read(io, path, replacement)
          read_block.call(io)
        end

        assert_equal :unsafe, result.status
      end
    end

    def test_missing_open_flags_fall_back_for_regular_files
      with_regular_coverage do |path|
        assert_equal :ok, read_without_open_flags(path).status
      end
    end

    def test_simplecov_nonmapping_root_is_warning
      with_host do |dir|
        path = File.join(dir, "coverage/.last_run.json")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "[]")
        config = config_for(["simplecov"], minimum_line: 80)

        report = DoctorCoverage.new(dir:, config:).call

        assert_check report, "coverage.simplecov", "warning", /shape|structured/i
      end
    end

    def test_two_commit_repository_has_automatic_comparison_evidence
      with_repository do |dir, _commit|
        commit_file(dir, "second.rb", "# second\n", "second")
        report = DoctorGit.new(dir:, config: config_for(["undercover"])).call

        assert_check report, "comparison", "ready", /Automatic comparison resolves to local commit/
      end
    end

    def test_git_removed_after_path_lookup_is_blocked
      with_repository do |dir, commit|
        executable = File.join(dir, "git")
        write_sentinel(executable)
        report = missing_after_lookup(dir, commit, executable)

        assert_check report, "comparison", "blocked", /Git.*unavailable|project-rooted PATH/i
      end
    end

    def test_deadline_expiration_is_unchecked_and_prevents_another_git_capture
      with_repository do |dir, _commit|
        probe = ExpiringDoctorGit.new(dir:, config: config_for(["undercover"]))
        monotonic = ->(_clock) { probe.clock }

        report = Process.stub(:clock_gettime, monotonic) { probe.call }

        assert_check report, "comparison", "unchecked", /five seconds/i
        assert_equal 1, probe.capture_timeouts.length
      end
    end

    private

    def with_host
      Dir.mktmpdir("doctor-evidence") { yield _1 }
    end

    def with_regular_coverage
      with_host do |dir|
        path = File.join(dir, "coverage/coverage.json")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.generate("meta" => {}, "coverage" => {}))
        yield path
      end
    end

    def read_without_open_flags(path)
      constants = %i[NONBLOCK NOFOLLOW]
      lookup = const_defined_without_open_flags(constants)
      fetch = const_get_without_open_flags(constants)
      File.stub(:const_defined?, lookup) do
        File.stub(:const_get, fetch) { DoctorBoundedFile.read(path:, max_bytes: DoctorBoundedFile::MAX_BYTES) }
      end
    end

    def const_defined_without_open_flags(constants)
      original = File.method(:const_defined?)
      ->(name, *arguments) { constants.include?(name) ? false : original.call(name, *arguments) }
    end

    def const_get_without_open_flags(constants)
      original = File.method(:const_get)
      lambda do |name, *arguments|
        raise NameError, name.to_s if constants.include?(name)

        original.call(name, *arguments)
      end
    end

    def with_open_interception(path)
      original_open = File.method(:open)
      intercept = lambda do |candidate, flags, &block|
        return original_open.call(candidate, flags, &block) unless File.expand_path(candidate) == path

        original_open.call(candidate, flags) { |io| yield io, block }
      end
      File.stub(:open, intercept) { DoctorBoundedFile.read(path:, max_bytes: DoctorBoundedFile::MAX_BYTES) }
    end

    def intercept_read_growth(io, writer, requested_lengths, read_block)
      original_read = io.method(:read)
      io.define_singleton_method(:read) do |length|
        requested_lengths << length
        writer.truncate(0)
        writer.rewind
        writer.write("x" * (DoctorBoundedFile::MAX_BYTES + 1))
        writer.flush
        original_read.call(length)
      end
      read_block.call(io)
    end

    def replace_file_after_read(io, path, replacement)
      original_read = io.method(:read)
      io.define_singleton_method(:read) do |length|
        bytes = original_read.call(length)
        File.rename(path, "#{path}.old")
        File.rename(replacement, path)
        bytes
      end
    end

    def config_for(adapters, compare_point: nil, minimum_line: nil)
      defaults = Config.defaults.merge(adapters: { fast: [], verify: adapters, audit: [] })
      coverage = minimum_line ? { minimum_line: } : nil
      Config.new(defaults.merge(compare_point:, coverage:))
    end

    def with_path(value)
      original = ENV["PATH"]
      ENV["PATH"] = value
      yield
    ensure
      ENV["PATH"] = original
    end

    def with_repository
      with_host do |dir|
        git!(dir, "init", "--quiet", "--initial-branch=main")
        git!(dir, "config", "user.email", "doctor@example.test")
        git!(dir, "config", "user.name", "Doctor Test")
        commit_file(dir, "first.rb", "# first\n", "first")
        commit = git!(dir, "rev-parse", "HEAD").strip
        yield dir, commit
      end
    end

    def commit_file(dir, path, contents, message)
      File.write(File.join(dir, path), contents)
      git!(dir, "add", path)
      git!(dir, "commit", "--quiet", "-m", message)
    end

    def git!(dir, *arguments)
      stdout, stderr, status = Open3.capture3("git", "-C", dir, *arguments)
      assert status.success?, "git #{arguments.join(" ")} failed: #{stderr}"
      stdout
    end

    def write_sentinel(path)
      File.write(path, "#!#{RbConfig.ruby}\nexit 0\n")
      File.chmod(0o755, path)
    end

    def missing_after_lookup(dir, commit, executable)
      path_probe = File.method(:executable?)
      lookup = lambda do |candidate|
        found = path_probe.call(candidate)
        File.unlink(candidate) if candidate == executable && found
        found
      end
      with_path(dir) do
        File.stub(:executable?, lookup) do
          DoctorGit.new(dir:, config: config_for(["undercover"], compare_point: commit)).call
        end
      end
    end

    def assert_check(checks, id, status, message_pattern)
      check = checks.find { _1.fetch("id") == id }
      refute_nil check
      assert_equal status, check.fetch("status")
      assert_match message_pattern, check.fetch("message")
    end
  end
end
