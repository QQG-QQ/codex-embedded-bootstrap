#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  hybrid-run.sh --build "<build_cmd>" --test "<test_cmd>" [options]

Required:
  --build CMD         Build command
  --test CMD          Test command

Options:
  --out-dir DIR       Output directory (default: artifacts/<YYYY-MM-DD>/hybrid-run-<task-id>)
  --base-ref REF      Base ref for bundle diff (default: working tree)
  --tier LEVEL        Task tier: tier0 or tier1 (default: tier1)
  --focus TEXT        Claude review focus
  --with-claude       Allow Claude review for tier0 (tier0 skips Claude by default)
  --skip-claude       Skip Claude architecture review
  --strict-claude     Return non-zero if Claude review fails
  --context-max-minutes N   Context collection budget in minutes
  --context-max-commands N  Context collection command budget
  --max-change-lines N      Change-size split threshold by total changed lines (default: 300)
  --max-change-files N      Change-size split threshold by changed files (default: 8)
  --enforce-change-size     Return non-zero when change-size threshold is exceeded
  --no-wip-lock       Disable WIP lock (default: lock enabled, WIP=1)
  --max-retries N     Forwarded to run-codex-ci-loop.sh
  --retry-delay SEC   Forwarded to run-codex-ci-loop.sh
  --no-fast-fail      Forwarded to run-codex-ci-loop.sh
  -h, --help          Show help

Examples:
  hybrid-run.sh --build "ninja -C build" --test "ctest --test-dir build --output-on-failure"

  hybrid-run.sh --tier tier0 --build "ninja -C build" --test "ctest --test-dir build --output-on-failure"

  hybrid-run.sh --build "bitbake core-image-minimal -c compile -f" \
    --test "ctest --output-on-failure" \
    --base-ref main \
    --focus "ABI impact and cross-layer regression risk"
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ci_script="$script_dir/run-codex-ci-loop.sh"
bundle_script="$script_dir/prepare-review-bundle.sh"
claude_script="$script_dir/request-claude-architecture-review.sh"

build_cmd=""
test_cmd=""
base_ref=""
focus="architecture explanation, cross-layer risk, and phased refactor roadmap"
skip_claude=0
strict_claude=0
no_fast_fail=0
with_claude=0
no_wip_lock=0
max_retries=""
retry_delay=""
task_tier="tier1"
context_max_minutes=""
context_max_commands=""
max_change_lines=300
max_change_files=8
enforce_change_size=0

context_elapsed_sec=0
context_cmd_count=0
context_budget_status="not-run"
context_budget_reason="not-run"
change_scope="not-run"
change_size_status="not-run"
change_size_reason="not-run"
change_files_count=0
change_added_lines=0
change_deleted_lines=0
change_total_lines=0
change_split_recommended=0
wip_lock_dir="${CODEX_HYBRID_WIP_LOCK_DIR:-/tmp/codex-hybrid-wip.lock}"
wip_lock_acquired=0
tier_default_skip_claude=0
task_id="hybrid-run-$(date +%H%M%S)"
today_dir="$(date +%F)"

default_out="artifacts/${today_dir}/${task_id}"
out_dir="$default_out"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build)
      [[ $# -ge 2 ]] || { echo "error: --build needs a value" >&2; exit 2; }
      build_cmd="$2"
      shift 2
      ;;
    --test)
      [[ $# -ge 2 ]] || { echo "error: --test needs a value" >&2; exit 2; }
      test_cmd="$2"
      shift 2
      ;;
    --out-dir)
      [[ $# -ge 2 ]] || { echo "error: --out-dir needs a value" >&2; exit 2; }
      out_dir="$2"
      shift 2
      ;;
    --base-ref)
      [[ $# -ge 2 ]] || { echo "error: --base-ref needs a value" >&2; exit 2; }
      base_ref="$2"
      shift 2
      ;;
    --tier)
      [[ $# -ge 2 ]] || { echo "error: --tier needs a value" >&2; exit 2; }
      task_tier="$2"
      shift 2
      ;;
    --focus)
      [[ $# -ge 2 ]] || { echo "error: --focus needs a value" >&2; exit 2; }
      focus="$2"
      shift 2
      ;;
    --with-claude)
      with_claude=1
      shift
      ;;
    --skip-claude)
      skip_claude=1
      shift
      ;;
    --strict-claude)
      strict_claude=1
      shift
      ;;
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
    --no-fast-fail)
      no_fast_fail=1
      shift
      ;;
    --context-max-minutes)
      [[ $# -ge 2 ]] || { echo "error: --context-max-minutes needs a value" >&2; exit 2; }
      context_max_minutes="$2"
      shift 2
      ;;
    --context-max-commands)
      [[ $# -ge 2 ]] || { echo "error: --context-max-commands needs a value" >&2; exit 2; }
      context_max_commands="$2"
      shift 2
      ;;
    --max-change-lines)
      [[ $# -ge 2 ]] || { echo "error: --max-change-lines needs a value" >&2; exit 2; }
      max_change_lines="$2"
      shift 2
      ;;
    --max-change-files)
      [[ $# -ge 2 ]] || { echo "error: --max-change-files needs a value" >&2; exit 2; }
      max_change_files="$2"
      shift 2
      ;;
    --enforce-change-size)
      enforce_change_size=1
      shift
      ;;
    --no-wip-lock)
      no_wip_lock=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

[[ -n "$build_cmd" ]] || { echo "error: --build is required" >&2; usage; exit 2; }
[[ -n "$test_cmd" ]] || { echo "error: --test is required" >&2; usage; exit 2; }

if [[ "$task_tier" != "tier0" && "$task_tier" != "tier1" ]]; then
  echo "error: --tier must be one of: tier0, tier1" >&2
  exit 2
fi

if [[ -z "$context_max_minutes" ]]; then
  if [[ "$task_tier" == "tier0" ]]; then
    context_max_minutes=10
  else
    context_max_minutes=20
  fi
fi

if [[ -z "$context_max_commands" ]]; then
  if [[ "$task_tier" == "tier0" ]]; then
    context_max_commands=8
  else
    context_max_commands=15
  fi
fi

if [[ ! "$context_max_minutes" =~ ^[0-9]+$ || "$context_max_minutes" == "0" ]]; then
  echo "error: --context-max-minutes must be a positive integer" >&2
  exit 2
fi

if [[ ! "$context_max_commands" =~ ^[0-9]+$ || "$context_max_commands" == "0" ]]; then
  echo "error: --context-max-commands must be a positive integer" >&2
  exit 2
fi

if [[ ! "$max_change_lines" =~ ^[0-9]+$ || "$max_change_lines" == "0" ]]; then
  echo "error: --max-change-lines must be a positive integer" >&2
  exit 2
fi

if [[ ! "$max_change_files" =~ ^[0-9]+$ || "$max_change_files" == "0" ]]; then
  echo "error: --max-change-files must be a positive integer" >&2
  exit 2
fi

if [[ "$with_claude" == "1" && "$skip_claude" == "1" ]]; then
  echo "error: --with-claude and --skip-claude are mutually exclusive" >&2
  exit 2
fi

if [[ "$task_tier" == "tier0" && "$with_claude" == "0" && "$skip_claude" == "0" ]]; then
  skip_claude=1
  tier_default_skip_claude=1
fi

if [[ "$strict_claude" == "1" && "$task_tier" == "tier0" && "$with_claude" == "0" ]]; then
  echo "error: --strict-claude requires --with-claude when --tier tier0 is used" >&2
  exit 2
fi

if [[ -n "$base_ref" ]] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    echo "error: base_ref '$base_ref' does not exist in this repository" >&2
    exit 2
  fi
fi

acquire_wip_lock() {
  if [[ "$no_wip_lock" == "1" ]]; then
    return 0
  fi

  local pid_file="$wip_lock_dir/pid"
  local meta_file="$wip_lock_dir/meta"

  if mkdir "$wip_lock_dir" 2>/dev/null; then
    printf '%s\n' "$$" > "$pid_file"
    {
      echo "pid=$$"
      echo "started_at=$(date -Iseconds)"
      echo "tier=$task_tier"
      echo "out_dir=$out_dir"
    } > "$meta_file"
    wip_lock_acquired=1
    return 0
  fi

  if [[ -f "$pid_file" ]]; then
    local existing_pid
    existing_pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "$existing_pid" && ! -d "/proc/$existing_pid" ]]; then
      rm -rf "$wip_lock_dir"
      if mkdir "$wip_lock_dir" 2>/dev/null; then
        printf '%s\n' "$$" > "$pid_file"
        {
          echo "pid=$$"
          echo "started_at=$(date -Iseconds)"
          echo "tier=$task_tier"
          echo "out_dir=$out_dir"
          echo "recovered_stale_lock=true"
        } > "$meta_file"
        wip_lock_acquired=1
        return 0
      fi
    fi
  fi

  echo "error: another hybrid-run workflow appears active (WIP=1 lock: $wip_lock_dir)" >&2
  if [[ -f "$pid_file" ]]; then
    echo "hint: active pid: $(cat "$pid_file" 2>/dev/null || true)" >&2
  fi
  echo "hint: wait for completion or use --no-wip-lock for deliberate override" >&2
  exit 3
}

release_wip_lock() {
  if [[ "$wip_lock_acquired" == "1" && -d "$wip_lock_dir" ]]; then
    rm -rf "$wip_lock_dir"
  fi
}

trap release_wip_lock EXIT
acquire_wip_lock

mkdir -p "$out_dir"
report_md="$out_dir/report.md"
report_json="$out_dir/report.json"
context_md="$out_dir/context-snapshot.md"

collect_context() {
  local started ended
  started="$(date +%s)"
  {
    echo "# Context Snapshot"
    echo
    echo "- generated_at: $(date -Iseconds)"
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      context_cmd_count=$((context_cmd_count + 1))
      echo "- git_repo: true"
      echo "- git_head: $(git rev-parse --short HEAD)"
      context_cmd_count=$((context_cmd_count + 1))
      echo "- git_branch: $(git rev-parse --abbrev-ref HEAD)"
      context_cmd_count=$((context_cmd_count + 1))
      echo
      echo "## Key Files"
      git ls-files | grep -E '(^|/)(README[^/]*|CMakeLists.txt|Makefile|meson.build|Kconfig|package.json|pyproject.toml|.*\.bb|.*\.bbappend|.*\.dts|.*\.dtsi)$' | head -n 80 || true
      context_cmd_count=$((context_cmd_count + 1))
      echo
      echo "## Git Status (short)"
      git status --short | head -n 120 || true
      context_cmd_count=$((context_cmd_count + 1))
    else
      context_cmd_count=$((context_cmd_count + 1))
      echo "- git_repo: false"
      echo
      echo "## Key Files (filesystem scan)"
      find . -maxdepth 3 -type f \
        \( -name 'README*' -o -name 'CMakeLists.txt' -o -name 'Makefile' -o -name 'meson.build' -o -name 'Kconfig' -o -name 'package.json' -o -name 'pyproject.toml' -o -name '*.bb' -o -name '*.bbappend' -o -name '*.dts' -o -name '*.dtsi' \) \
        | head -n 80
      context_cmd_count=$((context_cmd_count + 1))
    fi
  } > "$context_md"
  ended="$(date +%s)"
  context_elapsed_sec=$((ended - started))
}

collect_context

collect_change_size() {
  local range=""
  local numstat

  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    change_scope="not-a-git-repo"
    change_size_status="skipped"
    change_size_reason="not a git repository"
    return 0
  fi

  if [[ -n "$base_ref" ]]; then
    range="${base_ref}...HEAD"
    change_scope="$range"
    change_files_count="$(git diff --name-only "$range" | wc -l | tr -d ' ')"
    numstat="$(git diff --numstat "$range" || true)"
  else
    change_scope="working-tree"
    change_files_count="$(git diff --name-only | wc -l | tr -d ' ')"
    numstat="$(git diff --numstat || true)"
  fi

  read -r change_added_lines change_deleted_lines < <(
    echo "$numstat" | awk '
      BEGIN { a = 0; d = 0 }
      $1 ~ /^[0-9]+$/ { a += $1 }
      $2 ~ /^[0-9]+$/ { d += $2 }
      END { printf "%d %d\n", a, d }
    '
  )
  change_total_lines=$((change_added_lines + change_deleted_lines))

  if (( change_files_count > max_change_files || change_total_lines > max_change_lines )); then
    change_size_status="warn"
    change_size_reason="exceeds split thresholds"
    change_split_recommended=1
  else
    change_size_status="pass"
    change_size_reason="within split thresholds"
  fi
}

collect_change_size

context_budget_status="pass"
context_budget_reason="within budget"
if (( context_cmd_count > context_max_commands )); then
  context_budget_status="fail"
  context_budget_reason="command budget exceeded (${context_cmd_count}>${context_max_commands})"
fi

if (( context_elapsed_sec > context_max_minutes * 60 )); then
  context_budget_status="fail"
  if [[ "$context_budget_reason" == "within budget" ]]; then
    context_budget_reason="time budget exceeded (${context_elapsed_sec}s>$((context_max_minutes * 60))s)"
  else
    context_budget_reason="${context_budget_reason}; time budget exceeded (${context_elapsed_sec}s>$((context_max_minutes * 60))s)"
  fi
fi

if [[ "$context_budget_status" != "pass" ]]; then
  echo "error: context budget exceeded for $task_tier: $context_budget_reason" >&2
  exit 4
fi

ci_status="not-run"
bundle_status="not-run"
claude_status="not-run"
claude_reason="not-run"
ci_rc=0
bundle_rc=0
claude_rc=0
bundle_dir="$out_dir/review-bundle"
ci_output="$out_dir/ci-loop-output.txt"
bundle_output="$out_dir/bundle-output.txt"
claude_output="$out_dir/claude-output.txt"
claude_review_file=""

ci_args=()
[[ -n "$max_retries" ]] && ci_args+=(--max-retries "$max_retries")
[[ -n "$retry_delay" ]] && ci_args+=(--retry-delay "$retry_delay")
[[ "$no_fast_fail" == "1" ]] && ci_args+=(--no-fast-fail)
ci_args+=(--tier "$task_tier")

set +e
"$ci_script" "${ci_args[@]}" "$build_cmd" "$test_cmd" "$out_dir/ci" >"$ci_output" 2>&1
ci_rc=$?
set -e

if [[ $ci_rc -eq 0 ]]; then
  ci_status="pass"
else
  ci_status="fail"
fi

if [[ "$ci_status" == "pass" ]] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  set +e
  if [[ -n "$base_ref" ]]; then
    "$bundle_script" "$bundle_dir" "$base_ref" >"$bundle_output" 2>&1
  else
    "$bundle_script" "$bundle_dir" >"$bundle_output" 2>&1
  fi
  bundle_rc=$?
  set -e

  if [[ $bundle_rc -eq 0 ]]; then
    bundle_status="pass"
  else
    bundle_status="fail"
  fi
else
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    bundle_status="skipped (ci failed)"
  else
    bundle_status="skipped (not a git repo)"
  fi
fi

if [[ "$skip_claude" == "1" ]]; then
  if [[ "$tier_default_skip_claude" == "1" ]]; then
    claude_status="skipped (tier0 default)"
    claude_reason="tier0 fast path"
  else
    claude_status="skipped (user requested)"
    claude_reason="user requested skip"
  fi
elif [[ "$bundle_status" == "pass" ]]; then
  set +e
  "$claude_script" "$bundle_dir" "$focus" >"$claude_output" 2>&1
  claude_rc=$?
  set -e

  if [[ $claude_rc -eq 0 ]]; then
    claude_status="pass"
    claude_reason="completed"
    claude_review_file="$(awk -F': ' '/^review_output: /{print $2; exit}' "$claude_output")"
  else
    if grep -Eqi 'codeagent-wrapper not found|backend command not found|claude: command not found|unknown backend|unsupported backend|no such file or directory' "$claude_output"; then
      claude_status="unavailable (runtime)"
      claude_reason="backend or runner unavailable"
    elif grep -Eqi 'api key|authentication|unauthorized|forbidden|invalid api key|token' "$claude_output"; then
      claude_status="unavailable (auth)"
      claude_reason="authentication unavailable"
    elif grep -Eqi 'name resolution|could not resolve|connection timed out|network is unreachable|tls handshake timeout|503|service unavailable|connection reset by peer' "$claude_output"; then
      claude_status="unavailable (network)"
      claude_reason="network or remote service unavailable"
    else
      claude_status="fail"
      claude_reason="review execution failed"
    fi
  fi
else
  claude_status="skipped (bundle unavailable)"
  claude_reason="bundle unavailable"
fi

{
  echo "# Hybrid Run Report"
  echo
  echo "- generated_at: $(date -Iseconds)"
  echo "- output_dir: $out_dir"
  echo
  echo "## Status"
  echo "- tier: $task_tier"
  echo "- context_budget: $context_budget_status ($context_budget_reason; elapsed=${context_elapsed_sec}s; commands=${context_cmd_count}; limits=${context_max_minutes}m/${context_max_commands}cmds)"
  echo "- change_size: $change_size_status ($change_size_reason)"
  echo "- change_scope: $change_scope"
  echo "- change_files: ${change_files_count}/${max_change_files}"
  echo "- change_lines_total: ${change_total_lines}/${max_change_lines} (added=${change_added_lines}, deleted=${change_deleted_lines})"
  if [[ "$change_split_recommended" == "1" ]]; then
    echo "- split_recommendation: recommended"
  else
    echo "- split_recommendation: not needed"
  fi
  if [[ "$no_wip_lock" == "1" ]]; then
    echo "- wip_lock: disabled"
  else
    echo "- wip_lock: enabled ($wip_lock_dir)"
  fi
  echo "- ci: $ci_status (rc=$ci_rc)"
  echo "- bundle: $bundle_status (rc=$bundle_rc)"
  echo "- claude_review: $claude_status (rc=$claude_rc)"
  echo "- claude_reason: $claude_reason"
  echo
  echo "## Inputs"
  echo "- build_cmd: \`$build_cmd\`"
  echo "- test_cmd: \`$test_cmd\`"
  echo "- tier: \`$task_tier\`"
  [[ -n "$base_ref" ]] && echo "- base_ref: \`$base_ref\`"
  echo "- focus: $focus"
  echo
  echo "## Artifacts"
  echo "- context snapshot: $context_md"
  echo "- ci output: $ci_output"
  [[ -f "$bundle_output" ]] && echo "- bundle output: $bundle_output"
  [[ -f "$claude_output" ]] && echo "- claude output: $claude_output"
  [[ -n "$claude_review_file" ]] && echo "- claude review markdown: $claude_review_file"
  if [[ -d "$bundle_dir" ]]; then
    echo "- review bundle dir: $bundle_dir"
  fi
} > "$report_md"

{
  echo "{"
  echo "  \"generated_at\": \"$(date -Iseconds)\","
  echo "  \"output_dir\": \"$out_dir\","
  echo "  \"tier\": \"$task_tier\","
  echo "  \"context_budget_status\": \"$context_budget_status\","
  echo "  \"context_budget_reason\": \"$context_budget_reason\","
  echo "  \"context_elapsed_sec\": $context_elapsed_sec,"
  echo "  \"context_command_count\": $context_cmd_count,"
  echo "  \"context_max_minutes\": $context_max_minutes,"
  echo "  \"context_max_commands\": $context_max_commands,"
  echo "  \"change_scope\": \"$change_scope\","
  echo "  \"change_size_status\": \"$change_size_status\","
  echo "  \"change_size_reason\": \"$change_size_reason\","
  echo "  \"change_split_recommended\": $change_split_recommended,"
  echo "  \"change_files_count\": $change_files_count,"
  echo "  \"change_added_lines\": $change_added_lines,"
  echo "  \"change_deleted_lines\": $change_deleted_lines,"
  echo "  \"change_total_lines\": $change_total_lines,"
  echo "  \"max_change_files\": $max_change_files,"
  echo "  \"max_change_lines\": $max_change_lines,"
  echo "  \"ci_status\": \"$ci_status\","
  echo "  \"ci_rc\": $ci_rc,"
  echo "  \"bundle_status\": \"$bundle_status\","
  echo "  \"bundle_rc\": $bundle_rc,"
  echo "  \"claude_status\": \"$claude_status\","
  echo "  \"claude_reason\": \"$claude_reason\","
  echo "  \"claude_rc\": $claude_rc,"
  echo "  \"report_md\": \"$report_md\""
  echo "}"
} > "$report_json"

cat "$report_md"

if [[ "$ci_status" != "pass" ]]; then
  exit "$ci_rc"
fi

if [[ "$bundle_status" == "fail" ]]; then
  exit "$bundle_rc"
fi

if [[ "$strict_claude" == "1" && "$claude_status" != "pass" && "$claude_status" != "skipped (user requested)" ]]; then
  if [[ "$claude_rc" -ne 0 ]]; then
    exit "$claude_rc"
  fi
  exit 1
fi

if [[ "$enforce_change_size" == "1" && "$change_split_recommended" == "1" ]]; then
  echo "error: change-size thresholds exceeded (files=${change_files_count}/${max_change_files}, lines=${change_total_lines}/${max_change_lines})" >&2
  exit 5
fi

exit 0
