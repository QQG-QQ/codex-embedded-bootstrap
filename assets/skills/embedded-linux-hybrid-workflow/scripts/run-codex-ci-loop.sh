#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  run-codex-ci-loop.sh [options] "<build_cmd>" "<test_cmd>" [output_dir]

Options:
  --max-retries N    Retry count after the first failure (default: $CODEX_CI_MAX_RETRIES or 1)
  --retry-delay SEC  Delay between retries in seconds (default: $CODEX_CI_RETRY_DELAY_SEC or 5)
  --tier LEVEL       Task tier metadata: tier0 or tier1 (default: tier1)
  --no-fast-fail     Retry even non-retryable failures until retry budget is exhausted
  -h, --help         Show help

Environment:
  CODEX_CI_MAX_RETRIES
  CODEX_CI_RETRY_DELAY_SEC
  CODEX_CI_FAST_FAIL   (1=true default, 0=false)

Example:
  run-codex-ci-loop.sh --max-retries 1 \
    "ninja -C build" \
    "ctest --test-dir build --output-on-failure" \
    artifacts/codex-ci
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
classifier_script="$script_dir/classify-build-failure.sh"

max_retries="${CODEX_CI_MAX_RETRIES:-1}"
retry_delay="${CODEX_CI_RETRY_DELAY_SEC:-5}"
fast_fail="${CODEX_CI_FAST_FAIL:-1}"
task_tier="tier1"

positionals=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-retries)
      [[ $# -ge 2 ]] || { echo "error: --max-retries needs a value" >&2; exit 2; }
      max_retries="$2"
      shift 2
      ;;
    --retry-delay)
      [[ $# -ge 2 ]] || { echo "error: --retry-delay needs a value" >&2; exit 2; }
      retry_delay="$2"
      shift 2
      ;;
    --tier)
      [[ $# -ge 2 ]] || { echo "error: --tier needs a value" >&2; exit 2; }
      task_tier="$2"
      shift 2
      ;;
    --no-fast-fail)
      fast_fail=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        positionals+=("$1")
        shift
      done
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage
      exit 2
      ;;
    *)
      positionals+=("$1")
      shift
      ;;
  esac
done

if [[ ! "$max_retries" =~ ^[0-9]+$ ]]; then
  echo "error: max retries must be a non-negative integer" >&2
  exit 2
fi

if [[ ! "$retry_delay" =~ ^[0-9]+$ ]]; then
  echo "error: retry delay must be a non-negative integer" >&2
  exit 2
fi

if [[ "$task_tier" != "tier0" && "$task_tier" != "tier1" ]]; then
  echo "error: --tier must be one of: tier0, tier1" >&2
  exit 2
fi

if [[ "${#positionals[@]}" -lt 2 || "${#positionals[@]}" -gt 3 ]]; then
  usage
  exit 2
fi

build_cmd="${positionals[0]}"
test_cmd="${positionals[1]}"
out_dir="${positionals[2]:-artifacts/$(date +%F)/codex-ci}"

mkdir -p "$out_dir"
ts="$(date +%Y%m%d-%H%M%S)"
summary="$out_dir/summary-${ts}.txt"

{
  echo "timestamp: $(date -Iseconds)"
  echo "build_cmd: $build_cmd"
  echo "test_cmd: $test_cmd"
  echo "tier: $task_tier"
  echo "max_retries: $max_retries"
  echo "retry_delay_sec: $retry_delay"
  echo "fast_fail: $fast_fail"
} > "$summary"

stage_last_log=""
stage_last_rc=0

run_stage() {
  local stage="$1"
  local cmd="$2"
  local attempts=$((max_retries + 1))
  local attempt=1
  local rc=0

  while (( attempt <= attempts )); do
    local log_file="$out_dir/${stage}-${ts}-attempt${attempt}.log"
    stage_last_log="$log_file"

    {
      echo "${stage}_attempt_${attempt}_cmd: $cmd"
      echo "${stage}_attempt_${attempt}_log: $log_file"
    } >> "$summary"

    set +e
    bash -lc "$cmd" >"$log_file" 2>&1
    rc=$?
    set -e

    if [[ $rc -eq 0 ]]; then
      echo "${stage}_attempts: $attempt" >> "$summary"
      return 0
    fi

    local class_output=""
    local retryable=""
    local category=""
    local confidence=""
    local class_md=""
    local class_json=""

    if [[ -x "$classifier_script" ]]; then
      class_output="$("$classifier_script" "$log_file" "$out_dir" "$stage" || true)"
      retryable="$(echo "$class_output" | awk -F= '/^retryable=/{print $2; exit}')"
      category="$(echo "$class_output" | awk -F= '/^category=/{print $2; exit}')"
      confidence="$(echo "$class_output" | awk -F= '/^confidence=/{print $2; exit}')"
      class_md="$(echo "$class_output" | awk -F= '/^classification_md=/{print $2; exit}')"
      class_json="$(echo "$class_output" | awk -F= '/^classification_json=/{print $2; exit}')"
    fi

    {
      echo "${stage}_attempt_${attempt}_rc: $rc"
      [[ -n "$category" ]] && echo "${stage}_attempt_${attempt}_category: $category"
      [[ -n "$confidence" ]] && echo "${stage}_attempt_${attempt}_confidence: $confidence"
      [[ -n "$class_md" ]] && echo "${stage}_attempt_${attempt}_classification_md: $class_md"
      [[ -n "$class_json" ]] && echo "${stage}_attempt_${attempt}_classification_json: $class_json"
    } >> "$summary"

    if (( attempt >= attempts )); then
      break
    fi

    if [[ "$fast_fail" == "1" && "$retryable" != "true" ]]; then
      echo "${stage}_fast_fail: true" >> "$summary"
      break
    fi

    echo "${stage}_retry_after_sec: $retry_delay" >> "$summary"
    sleep "$retry_delay"
    ((attempt++))
  done

  echo "${stage}_attempts: $attempt" >> "$summary"
  stage_last_rc="$rc"
  return "$rc"
}

if ! run_stage "build" "$build_cmd"; then
  {
    echo "build_status: fail (${stage_last_rc})"
    echo "build_log: $stage_last_log"
  } >> "$summary"
  cat "$summary"
  exit "$stage_last_rc"
fi

build_log="$stage_last_log"

if ! run_stage "test" "$test_cmd"; then
  {
    echo "build_status: pass"
    echo "test_status: fail (${stage_last_rc})"
    echo "build_log: $build_log"
    echo "test_log: $stage_last_log"
  } >> "$summary"
  cat "$summary"
  exit "$stage_last_rc"
fi

test_log="$stage_last_log"

{
  echo "build_status: pass"
  echo "test_status: pass"
  echo "build_log: $build_log"
  echo "test_log: $test_log"
} >> "$summary"

cat "$summary"
