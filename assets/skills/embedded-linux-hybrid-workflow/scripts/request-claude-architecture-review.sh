#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  request-claude-architecture-review.sh [bundle_dir] [focus]

Examples:
  request-claude-architecture-review.sh artifacts/hybrid-review
  request-claude-architecture-review.sh artifacts/hybrid-review "kernel/user ABI and refactor roadmap"

Environment:
  CODEAGENT_WRAPPER  Optional wrapper path (default: codeagent-wrapper, then ~/.claude/bin/codeagent-wrapper)
  CLAUDE_BACKEND     Optional backend name (default: claude)
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

bundle_dir="${1:-artifacts/hybrid-review}"
focus="${2:-architecture explanation, cross-layer risk, and refactor roadmap}"
backend="${CLAUDE_BACKEND:-claude}"

wrapper="${CODEAGENT_WRAPPER:-codeagent-wrapper}"
if ! command -v "$wrapper" >/dev/null 2>&1; then
  fallback_wrapper="$HOME/.claude/bin/codeagent-wrapper"
  if [[ -x "$fallback_wrapper" ]]; then
    wrapper="$fallback_wrapper"
  else
    echo "error: codeagent-wrapper not found" >&2
    exit 1
  fi
fi

review_input="$bundle_dir/review-input.md"
diffstat="$bundle_dir/diffstat.txt"
changed="$bundle_dir/changed-files.txt"
modules="$bundle_dir/module-roots.txt"
diff_file="$bundle_dir/changes.diff"

for file in "$review_input" "$diffstat" "$changed" "$modules" "$diff_file"; do
  if [[ ! -f "$file" ]]; then
    echo "error: missing required file: $file" >&2
    exit 1
  fi
done

output_file="$bundle_dir/claude-architecture-review-$(date +%Y%m%d-%H%M%S).md"

"$wrapper" --backend "$backend" - <<EOF | tee "$output_file"
You are a principal embedded Linux reviewer.

Review this change package with focus on: $focus

Artifacts:
- @${review_input}
- @${diffstat}
- @${changed}
- @${modules}
- @${diff_file}

Return markdown with these sections:
1. Architecture Walkthrough
2. Cross-Layer Risks (bootloader/kernel/dtb/driver/userspace/build/CI)
3. Regression and Compatibility Risks
4. Refactor Roadmap (phased, low-risk-first)
5. Must-Fix Items Before Merge
6. Nice-to-Have Improvements

Rules:
- Keep findings actionable and mapped to specific files or modules.
- Prioritize stability, backward compatibility, and debuggability.
- Call out assumptions explicitly.
EOF

echo "review_output: $output_file"
