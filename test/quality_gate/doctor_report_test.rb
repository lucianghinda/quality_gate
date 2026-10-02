# frozen_string_literal: true

require_relative "../test_helper"
require "json"
require "stringio"
require "quality_gate/doctor_report"
require "quality_gate/reporters/doctor"

class DoctorReportTest < Minitest::Test
  def test_check_is_a_frozen_normalized_string_hash
    check = QualityGate::DoctorReport.check(id: :configuration, status: :ready, message: "Loaded")

    assert_equal({ "id" => "configuration", "status" => "ready", "message" => "Loaded" }, check)
    assert check.frozen?
    assert check.values.all?(&:frozen?)
  end

  def test_summary_and_exit_code_reduce_statuses_with_blocked_precedence
    report = blocked_summary_report

    assert_equal(
      { "ready" => 1, "warning" => 0, "blocked" => 1, "unchecked" => 1, "not_applicable" => 1 },
      report.summary
    )
    assert_equal 2, report.exit_code
    assert_raises(FrozenError) { report.checks << check("new", "ready") }
    assert_raises(FrozenError) { report.summary["ready"] = 3 }
  end

  def test_warning_or_unchecked_exits_one_and_ready_or_not_applicable_exits_zero
    assert_equal 1, QualityGate::DoctorReport.new(checks: [check("warn", "warning")]).exit_code
    assert_equal 1, QualityGate::DoctorReport.new(checks: [check("skip", "unchecked")]).exit_code
    assert_equal 0, QualityGate::DoctorReport.new(checks: [check("ready", "ready")]).exit_code
    assert_equal 0, QualityGate::DoctorReport.new(checks: [check("skip", "not_applicable")]).exit_code
  end

  def test_unknown_status_is_rejected
    error = assert_raises(ArgumentError) do
      QualityGate::DoctorReport.check(id: "runtime", status: "unknown", message: "Observed")
    end

    assert_equal "unknown Doctor status", error.message
  end

  def test_json_report_has_preflight_envelope_and_sanitized_utf8
    output = StringIO.new
    message = "unsafe\e[31m\xFF"
    report = QualityGate::DoctorReport.new(checks: [check("runtime", "warning", message)])

    QualityGate::Reporters::Doctor.new(io: output).call(report, format: "json")

    assert_equal({
                   "scope" => "preflight",
                   "checks" => [{ "id" => "runtime", "status" => "warning", "message" => "unsafe\e[31m�" }],
                   "summary" => { "ready" => 0, "warning" => 1, "blocked" => 0, "unchecked" => 0,
                                  "not_applicable" => 0 }
                 }, JSON.parse(output.string))
  end

  def test_text_report_sanitizes_controls_and_prints_counted_summary
    output = StringIO.new
    report = QualityGate::DoctorReport.new(checks: [check("runtime\e", "warning", "needs\eaction")])

    QualityGate::Reporters::Doctor.new(io: output).call(report, format: "text")

    assert_equal text_output, output.string
  end

  def test_unknown_report_format_is_rejected_without_writing_output
    output = StringIO.new

    error = assert_raises(ArgumentError) do
      QualityGate::Reporters::Doctor.new(io: output).call(blocked_summary_report, format: "markdown")
    end

    assert_equal "Doctor format must be text or json", error.message
    assert_empty output.string
  end

  private

  def blocked_summary_report
    checks = [check("ok", "ready"), check("optional", "not_applicable"),
              check("later", "unchecked"), check("bad", "blocked")]
    QualityGate::DoctorReport.new(checks:)
  end

  def text_output
    "runtime warning needs action\n" \
      "Preflight: 0 ready, 1 warning, 0 blocked, 0 unchecked, 0 not applicable\n"
  end

  def check(id, status, message = "Observed")
    QualityGate::DoctorReport.check(id:, status:, message:)
  end
end
