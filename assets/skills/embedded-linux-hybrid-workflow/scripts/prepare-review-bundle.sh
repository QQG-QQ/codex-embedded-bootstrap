#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  prepare-review-bundle.sh [output_dir] [base_ref]

Examples:
  prepare-review-bundle.sh artifacts/hybrid-review
  prepare-review-bundle.sh artifacts/hybrid-review main
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 2 ]]; then
  usage
  exit 2
fi

out_dir="${1:-artifacts/hybrid-review}"
base_ref="${2:-}"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: current directory is not a git repository" >&2
  exit 1
fi

if [[ -n "$base_ref" ]] && ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
  echo "error: base_ref '$base_ref' does not exist in this repository" >&2
  exit 1
fi

mkdir -p "$out_dir"
timestamp="$(date -Iseconds)"

diff_file="$out_dir/changes.diff"
changed_file="$out_dir/changed-files.txt"
diffstat_file="$out_dir/diffstat.txt"
module_file="$out_dir/module-roots.txt"
diff_hygiene_file="$out_dir/diff-hygiene.md"
review_md="$out_dir/review-input.md"

diff_args=()
if [[ -n "$base_ref" ]]; then
  range="${base_ref}...HEAD"
  diff_args=("$range")
  git diff --binary "${diff_args[@]}" > "$diff_file"
  git diff --name-only "${diff_args[@]}" > "$changed_file"
  git diff --stat "${diff_args[@]}" > "$diffstat_file"
  git log --oneline "${base_ref}..HEAD" > "$out_dir/commit-list.txt"
else
  git diff --binary "${diff_args[@]}" > "$diff_file"
  git diff --name-only "${diff_args[@]}" > "$changed_file"
  git diff --stat "${diff_args[@]}" > "$diffstat_file"
fi

awk -F/ '
  NF >= 2 { print $1 "/" $2; next }
  NF == 1 { print $1 }
' "$changed_file" | sed '/^$/d' | sort -u > "$module_file"

changed_count="$(wc -l < "$changed_file" | tr -d ' ')"
module_count="$(wc -l < "$module_file" | tr -d ' ')"

read -r added_lines deleted_lines < <(
  git diff --numstat "${diff_args[@]}" |
    awk '
      BEGIN { added = 0; deleted = 0 }
      $1 ~ /^[0-9]+$/ { added += $1 }
      $2 ~ /^[0-9]+$/ { deleted += $2 }
      END { print added, deleted }
    '
)
read -r whitespace_added_lines whitespace_deleted_lines < <(
  git diff -w --numstat "${diff_args[@]}" |
    awk '
      BEGIN { added = 0; deleted = 0 }
      $1 ~ /^[0-9]+$/ { added += $1 }
      $2 ~ /^[0-9]+$/ { deleted += $2 }
      END { print added, deleted }
    '
)

changed_lines=$((added_lines + deleted_lines))
whitespace_changed_lines=$((whitespace_added_lines + whitespace_deleted_lines))
whitespace_reduction=0
if [[ "$changed_lines" -gt 0 ]]; then
  reduced_lines=$((changed_lines - whitespace_changed_lines))
  if [[ "$reduced_lines" -lt 0 ]]; then
    reduced_lines=0
  fi
  whitespace_reduction=$((reduced_lines * 100 / changed_lines))
fi

emit_policy_line() {
  local label="$1"
  local status="$2"
  local detail="$3"

  echo "- ${label}: ${status} - ${detail}"
}

emit_risk_flags() {
  local emitted=0

  if grep -Eq '(^|/)(include/|api/|.*\.(h|hh|hpp|hxx)$)' "$changed_file"; then
    echo "- public header or API-like path changed; check API/ABI compatibility."
    emitted=1
  fi
  if grep -Eq '(^|/)(Kconfig|.*defconfig|.*\.config)$|(^|/).*\.dts$|(^|/).*\.dtsi$' "$changed_file"; then
    echo "- kernel, device-tree, or config metadata changed; check board and config impact."
    emitted=1
  fi
  if grep -Eq '(^|/).*\.(bb|bbappend|inc)$|(^|/)conf/|(^|/)recipes-' "$changed_file"; then
    echo "- Yocto or build recipe metadata changed; check dependency, packaging, and image impact."
    emitted=1
  fi
  if grep -Eq '(^|/)(Makefile|CMakeLists\.txt|meson\.build|configure\.ac|.*\.mk)$|(^|/)(build|ci|\.github|scripts)/' "$changed_file"; then
    echo "- build, CI, or script path changed; check host/toolchain assumptions."
    emitted=1
  fi
  if [[ "$emitted" -eq 0 ]]; then
    echo "- none detected."
  fi
}

{
  echo "# Diff Hygiene"
  echo
  echo "- generated_at: $timestamp"
  echo "- git_head: $(git rev-parse --short HEAD)"
  if [[ -n "$base_ref" ]]; then
    echo "- base_ref: $base_ref"
  else
    echo "- base_ref: working-tree"
  fi
  echo "- changed_files: $changed_count"
  echo "- module_roots: $module_count"
  echo "- added_lines: $added_lines"
  echo "- deleted_lines: $deleted_lines"
  echo "- changed_lines: $changed_lines"
  echo "- whitespace_ignored_changed_lines: $whitespace_changed_lines"
  echo "- whitespace_reduction_percent: $whitespace_reduction"
  echo
  echo "## Policy Warnings"
  if [[ "$changed_count" -gt 8 ]]; then
    emit_policy_line "file_count" "WARN" "$changed_count files exceeds the preferred 8-file review target."
  else
    emit_policy_line "file_count" "OK" "$changed_count files is within the preferred 8-file review target."
  fi
  if [[ "$changed_lines" -gt 300 ]]; then
    emit_policy_line "line_count" "WARN" "$changed_lines changed lines exceeds the preferred 300-line review target."
  else
    emit_policy_line "line_count" "OK" "$changed_lines changed lines is within the preferred 300-line review target."
  fi
  if [[ "$module_count" -gt 2 ]]; then
    emit_policy_line "module_span" "WARN" "$module_count module roots suggests cross-layer or broad-scope review."
  else
    emit_policy_line "module_span" "OK" "$module_count module roots is narrow enough for focused review."
  fi
  if [[ "$changed_lines" -ge 20 && "$whitespace_reduction" -ge 60 ]]; then
    emit_policy_line "formatting_churn" "WARN" "git diff -w reduces changed lines by ${whitespace_reduction}%; inspect for formatting-only churn."
  else
    emit_policy_line "formatting_churn" "OK" "no strong formatting-only churn signal detected."
  fi
  echo
  echo "## Risk Flags"
  emit_risk_flags
} > "$diff_hygiene_file"

{
  echo "# Review Input"
  echo
  echo "- generated_at: $timestamp"
  echo "- git_head: $(git rev-parse --short HEAD)"
  if [[ -n "$base_ref" ]]; then
    echo "- base_ref: $base_ref"
  else
    echo "- base_ref: working-tree"
  fi
  echo "- changed_files: $changed_count"
  echo
  echo "## Files"
  echo "- diff: $(basename "$diff_file")"
  echo "- changed list: $(basename "$changed_file")"
  echo "- diffstat: $(basename "$diffstat_file")"
  echo "- module roots: $(basename "$module_file")"
  echo "- diff hygiene: $(basename "$diff_hygiene_file")"
  if [[ -n "$base_ref" ]]; then
    echo "- commits: commit-list.txt"
  fi
} > "$review_md"

echo "bundle_dir: $out_dir"
echo "diff: $diff_file"
echo "changed_files: $changed_file"
echo "diffstat: $diffstat_file"
echo "module_roots: $module_file"
echo "diff_hygiene: $diff_hygiene_file"
echo "review_input: $review_md"
