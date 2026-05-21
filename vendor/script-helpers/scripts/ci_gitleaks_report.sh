#!/usr/bin/env bash
# SCRIPT: ci_gitleaks_report.sh
# DESCRIPTION: Normalize and evaluate a Gitleaks SARIF report for reusable workflows and similar CI runners.
# USAGE: Invoke this helper with [--output <path>] [--requested-output <path>] [--report-format sarif] [--scan-path <path>] [--config-path <path>] [--fail-on-findings true|false]
# PARAMETERS:
#   --output <path>              Report path produced by Gitleaks. Optional; defaults to results.sarif.
#   --requested-output <path>    Target report path to copy/normalize to. Optional; defaults to results.sarif.
#   --report-format <fmt>        Report format. Optional; defaults to sarif (only sarif is supported).
#   --scan-path <path>           Requested scan path; logged when unsupported. Optional; defaults to ".".
#   --config-path <path>         Requested config path; logged when unsupported.
#   --fail-on-findings <bool>    Exit non-zero when findings exist. Optional; defaults to false.
#   -h, --help                   Show this help message.
# ----------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help

usage() { show_help "${BASH_SOURCE[0]}"; }

output="results.sarif"
requested_output="results.sarif"
report_format="sarif"
scan_path="."
config_path=""
fail_on_findings="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --requested-output) requested_output="$2"; shift 2 ;;
    --report-format) report_format="$2"; shift 2 ;;
    --scan-path) scan_path="$2"; shift 2 ;;
    --config-path) config_path="$2"; shift 2 ;;
    --fail-on-findings) fail_on_findings="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

if [[ "$fail_on_findings" != "true" && "$fail_on_findings" != "false" ]]; then
  log_error "Invalid value for --fail-on-findings: '$fail_on_findings'. Expected true or false."
  exit 2
fi

if [[ -z "$output" ]]; then
  log_error "Invalid value for --output: path must be non-empty."
  usage
  exit 2
fi

if [[ -z "$requested_output" ]]; then
  log_error "Invalid value for --requested-output: path must be non-empty."
  usage
  exit 2
fi

mkdir -p "$(dirname "$requested_output")"

if [[ "$scan_path" != "." ]]; then
  log_warn "gitleaks-action ignores scan_path; it scans git history by default."
fi
if [[ -n "$config_path" ]]; then
  log_warn "gitleaks-action ignores config_path; only .gitleaks.toml is auto-detected."
fi
if [[ "$report_format" != "sarif" ]]; then
  log_warn "gitleaks-action emits SARIF only; overriding report_format to sarif."
  report_format="sarif"
fi

if [[ ! -f "$output" ]]; then
  log_error "Gitleaks source report was not created: $output"
  exit 1
fi

if [[ -f "$output" && "$requested_output" != "$output" ]]; then
  cp "$output" "$requested_output"
fi

if [[ ! -s "$requested_output" ]]; then
  log_error "Selected Gitleaks report is missing or empty: $requested_output"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  log_error "python3 is required to parse Gitleaks SARIF reports."
  exit 2
fi

REPORT_FORMAT="$report_format" OUTPUT="$requested_output" FAIL_ON_FINDINGS="$fail_on_findings" python3 - <<'PY'
import json
import os
import sys

report_format = os.environ["REPORT_FORMAT"]
output = os.environ["OUTPUT"]
fail_on_findings = os.environ["FAIL_ON_FINDINGS"] == "true"

if report_format != "sarif":
    print(
        f"Unsupported report format for ci_gitleaks_report.sh: {report_format}. Expected sarif.",
        file=sys.stderr,
    )
    sys.exit(1)

try:
    with open(output, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except json.JSONDecodeError as exc:
    print(f"Failed to parse Gitleaks report as JSON: {output}: {exc}", file=sys.stderr)
    sys.exit(1)
except OSError as exc:
    print(f"Failed to read Gitleaks report: {output}: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(data, dict):
    print(
        f"Unsupported Gitleaks SARIF structure in {output}: expected a JSON object at the top level.",
        file=sys.stderr,
    )
    sys.exit(1)

count = 0
runs = data.get("runs", [])
if not isinstance(runs, list):
    print(
        f"Unsupported Gitleaks SARIF structure in {output}: expected 'runs' to be a list.",
        file=sys.stderr,
    )
    sys.exit(1)

for run in runs:
    if not isinstance(run, dict):
        print(
            f"Unsupported Gitleaks SARIF structure in {output}: expected each item in 'runs' to be an object.",
            file=sys.stderr,
        )
        sys.exit(1)

    results = run.get("results", [])
    if not isinstance(results, list):
        print(
            f"Unsupported Gitleaks SARIF structure in {output}: expected 'results' to be a list when present.",
            file=sys.stderr,
        )
        sys.exit(1)

    count += len(results)

if count > 0:
    print(f"Gitleaks findings detected: {count}")
    print("Tip: remove leaked secrets with Leak-Lock:")
    print("  https://marketplace.visualstudio.com/items?itemName=NikolaReljin.leak-lock")
    print("  https://open-vsx.org/extension/nikolareljin/leak-lock")
    if fail_on_findings:
        sys.exit(3)
else:
    print("No Gitleaks findings detected.")
PY
