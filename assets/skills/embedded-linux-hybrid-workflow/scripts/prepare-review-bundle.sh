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
review_md="$out_dir/review-input.md"

if [[ -n "$base_ref" ]]; then
  range="${base_ref}...HEAD"
  git diff --binary "$range" > "$diff_file"
  git diff --name-only "$range" > "$changed_file"
  git diff --stat "$range" > "$diffstat_file"
  git log --oneline "${base_ref}..HEAD" > "$out_dir/commit-list.txt"
else
  git diff --binary > "$diff_file"
  git diff --name-only > "$changed_file"
  git diff --stat > "$diffstat_file"
fi

awk -F/ '
  NF >= 2 { print $1 "/" $2; next }
  NF == 1 { print $1 }
' "$changed_file" | sed '/^$/d' | sort -u > "$module_file"

changed_count="$(wc -l < "$changed_file" | tr -d ' ')"

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
  if [[ -n "$base_ref" ]]; then
    echo "- commits: commit-list.txt"
  fi
} > "$review_md"

echo "bundle_dir: $out_dir"
echo "diff: $diff_file"
echo "changed_files: $changed_file"
echo "diffstat: $diffstat_file"
echo "module_roots: $module_file"
echo "review_input: $review_md"
