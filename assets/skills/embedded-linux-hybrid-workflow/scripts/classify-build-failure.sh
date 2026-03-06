#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  classify-build-failure.sh <log_file> [output_dir] [stage]

Arguments:
  log_file     Build/test log file to classify
  output_dir   Optional output directory for markdown/json artifacts
  stage        Optional stage hint: build|test (default: build)

Outputs:
  Prints key=value lines to stdout:
    category=...
    retryable=true|false
    confidence=high|medium|low
    matched_pattern=...
    classification_md=...
    classification_json=...
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 1 || $# -gt 3 ]]; then
  usage
  exit 2
fi

log_file="$1"
out_dir="${2:-}"
stage="${3:-build}"

if [[ ! -f "$log_file" ]]; then
  echo "error: log file not found: $log_file" >&2
  exit 1
fi

lower_log="$(mktemp)"
trap 'rm -f "$lower_log"' EXIT
tr '[:upper:]' '[:lower:]' < "$log_file" > "$lower_log"

category="unknown"
retryable="false"
confidence="low"
matched_pattern="no-pattern-matched"
next_steps=()

set_classification() {
  category="$1"
  retryable="$2"
  confidence="$3"
  matched_pattern="$4"
  shift 4
  next_steps=("$@")
}

match_any() {
  local pattern="$1"
  grep -Eq "$pattern" "$lower_log"
}

if match_any 'temporary failure|could not resolve|name resolution|connection timed out|tls handshake timeout|network is unreachable|connection reset by peer|503 service unavailable|failed to fetch'; then
  set_classification \
    "infra-transient-network" "true" "high" \
    "network/transient fetch failure" \
    "Retry once with stable network/proxy settings." \
    "Check mirror availability and DNS/proxy configuration." \
    "Preserve failing fetch URL in task report for reproducibility."
elif match_any 'resource temporarily unavailable|device or resource busy|text file busy|database is locked|lock file|another process'; then
  set_classification \
    "infra-transient-lock" "true" "high" \
    "resource lock / busy state" \
    "Retry after short delay." \
    "Ensure no concurrent build process uses the same workspace/cache." \
    "If persistent, clean lock file with ownership verification."
elif match_any 'timed out|timeout|deadline exceeded|no output has been received'; then
  set_classification \
    "infra-timeout" "true" "medium" \
    "timeout/deadline exceeded" \
    "Retry with increased timeout budget if environment is healthy." \
    "Capture exact command duration and previous successful baseline."
elif match_any 'permission denied|operation not permitted|read-only file system|eacces|eperm'; then
  set_classification \
    "permission-error" "false" "high" \
    "permission/read-only filesystem failure" \
    "Fix workspace permissions or mount mode." \
    "Avoid retry until filesystem and user permission issues are resolved."
elif match_any 'out of memory|cannot allocate memory|killed process|oom-killer|std::bad_alloc'; then
  set_classification \
    "resource-exhaustion" "false" "high" \
    "memory exhaustion" \
    "Reduce parallelism and memory footprint." \
    "Inspect linker/compiler peak memory and adjust job count." \
    "Retry only after resource tuning."
elif match_any 'undefined reference|ld returned [0-9]+ exit status|collect2: error|linker command failed|cannot find -l'; then
  set_classification \
    "linker-error" "false" "high" \
    "linker unresolved symbols/libraries" \
    "Verify link order and missing objects/libraries." \
    "Check feature flags and ABI compatibility across modules." \
    "Add or correct dependency declarations in build system."
elif match_any 'fatal error: .*no such file or directory|no rule to make target|command not found|missing separator'; then
  set_classification \
    "missing-dependency-or-target" "false" "high" \
    "missing header/tool/target rule" \
    "Install missing dependency or fix include/build target mapping." \
    "Verify toolchain path and build environment bootstrap." \
    "Avoid retry before dependency repair."
elif match_any 'dtc|device tree|fdt_err|dts|dtsi|phandle'; then
  set_classification \
    "device-tree-error" "false" "medium" \
    "device tree compilation/validation issue" \
    "Validate node path, phandle references, and compatible strings." \
    "Run dtc validation with warnings enabled." \
    "Confirm SoC board variant overlays and include order."
elif match_any 'kconfig|menuconfig|unknown symbol|invalid for .*config|recursive dependency'; then
  set_classification \
    "kconfig-error" "false" "medium" \
    "kconfig dependency/invalid symbol issue" \
    "Check Kconfig dependencies and symbol visibility." \
    "Regenerate defconfig and compare with known-good baseline." \
    "Avoid retry before config consistency is restored."
elif [[ "$stage" == "test" ]] || match_any 'assertionerror|failures:|failed [0-9]+ tests|test failed|expected:|actual:'; then
  set_classification \
    "test-failure" "false" "medium" \
    "test assertions or scenario failure" \
    "Map failing tests to requirement scenarios (happy/edge/error/state)." \
    "Fix behavior or test expectation drift with explicit rationale." \
    "Re-run affected test subset before full suite."
elif match_any 'error:|fatal:'; then
  set_classification \
    "compiler-or-build-error" "false" "medium" \
    "generic compiler/build fatal error" \
    "Locate first fatal error in log and fix root cause, not cascaded errors." \
    "Check recent diff for incompatible API/type/signature changes."
else
  set_classification \
    "unknown" "false" "low" \
    "no known pattern" \
    "Inspect the first fatal block in log manually." \
    "Create a minimal reproduction command and rerun with verbose flags."
fi

classification_md=""
classification_json=""

if [[ -n "$out_dir" ]]; then
  mkdir -p "$out_dir"
  ts="$(date +%Y%m%d-%H%M%S)"
  classification_md="$out_dir/failure-classification-${stage}-${ts}.md"
  classification_json="$out_dir/failure-classification-${stage}-${ts}.json"

  {
    echo "# Failure Classification"
    echo
    echo "- log_file: $log_file"
    echo "- stage: $stage"
    echo "- category: $category"
    echo "- retryable: $retryable"
    echo "- confidence: $confidence"
    echo "- matched_pattern: $matched_pattern"
    echo
    echo "## Recommended Next Steps"
    for step in "${next_steps[@]}"; do
      echo "- $step"
    done
  } > "$classification_md"

  {
    echo "{"
    echo "  \"log_file\": \"${log_file}\","
    echo "  \"stage\": \"${stage}\","
    echo "  \"category\": \"${category}\","
    echo "  \"retryable\": ${retryable},"
    echo "  \"confidence\": \"${confidence}\","
    echo "  \"matched_pattern\": \"${matched_pattern}\","
    echo "  \"next_steps\": ["
    for i in "${!next_steps[@]}"; do
      step="${next_steps[$i]}"
      esc_step="$(echo "$step" | sed 's/\\/\\\\/g; s/"/\\"/g')"
      comma=","
      if [[ "$i" -eq $((${#next_steps[@]} - 1)) ]]; then
        comma=""
      fi
      echo "    \"${esc_step}\"${comma}"
    done
    echo "  ]"
    echo "}"
  } > "$classification_json"
fi

echo "category=$category"
echo "retryable=$retryable"
echo "confidence=$confidence"
echo "matched_pattern=$matched_pattern"
echo "classification_md=$classification_md"
echo "classification_json=$classification_json"
