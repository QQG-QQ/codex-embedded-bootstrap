#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  install.sh --workspace <path> [options]

Required:
  --workspace PATH        Target workspace, AGENTS.md will be written here

Options:
  --codex-home PATH       Codex home directory (default: $CODEX_HOME or ~/.codex)
  --skip-codex-install    Skip codex CLI install step
  -h, --help              Show help
EOF
}

workspace=""
codex_home="${CODEX_HOME:-$HOME/.codex}"
skip_codex_install=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      [[ $# -ge 2 ]] || { echo "error: --workspace needs a value" >&2; exit 2; }
      workspace="$2"
      shift 2
      ;;
    --codex-home)
      [[ $# -ge 2 ]] || { echo "error: --codex-home needs a value" >&2; exit 2; }
      codex_home="$2"
      shift 2
      ;;
    --skip-codex-install)
      skip_codex_install=1
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

[[ -n "$workspace" ]] || { echo "error: --workspace is required" >&2; usage; exit 2; }

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
assets_dir="$script_dir/assets"
agents_src="$assets_dir/AGENTS.md"
skill_name="embedded-linux-hybrid-workflow"
skill_src="$assets_dir/skills/$skill_name"

agents_dst="$workspace/AGENTS.md"
skills_dir="$codex_home/skills"
skill_dst="$skills_dir/$skill_name"

timestamp="$(date +%Y%m%d-%H%M%S)"
backup_root="$workspace/.codex-bootstrap-backups/$timestamp"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "error: required command not found: $cmd" >&2
    exit 1
  fi
}

render_agents() {
  local dst="$1"
  local escaped_codex_home
  escaped_codex_home="$(printf '%s' "$codex_home" | sed 's/[\/&]/\\&/g')"
  sed "s|__CODEX_HOME__|$escaped_codex_home|g" "$agents_src" > "$dst"
}

install_codex_cli() {
  if command -v codex >/dev/null 2>&1; then
    echo "[ok] codex already installed: $(codex --version 2>/dev/null || echo unknown)"
    return 0
  fi

  require_cmd node
  require_cmd npm

  echo "[info] codex not found, installing @openai/codex ..."
  if npm install -g @openai/codex; then
    echo "[ok] codex installed globally"
    return 0
  fi

  echo "[warn] global install failed, fallback to user prefix ~/.local"
  mkdir -p "$HOME/.local"
  npm install -g @openai/codex --prefix "$HOME/.local"
  echo "[ok] codex installed to $HOME/.local"
  echo "[note] ensure PATH contains: $HOME/.local/bin"
}

backup_if_exists() {
  local src="$1"
  local dst="$2"
  if [[ -e "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
  fi
}

sync_configs() {
  [[ -f "$agents_src" ]] || { echo "error: missing file: $agents_src" >&2; exit 1; }
  [[ -d "$skill_src" ]] || { echo "error: missing directory: $skill_src" >&2; exit 1; }

  mkdir -p "$workspace"
  mkdir -p "$skills_dir"
  mkdir -p "$backup_root"

  backup_if_exists "$agents_dst" "$backup_root/AGENTS.md"
  backup_if_exists "$skill_dst" "$backup_root/skills/$skill_name"

  render_agents "$agents_dst"
  rm -rf "$skill_dst"
  cp -a "$skill_src" "$skill_dst"
  find "$skill_dst/scripts" -type f -name '*.sh' -exec chmod +x {} \;
}

if [[ "$skip_codex_install" == "0" ]]; then
  install_codex_cli
else
  echo "[info] skip codex install"
fi

sync_configs

echo "[done] bootstrap completed"
echo "workspace: $workspace"
echo "codex_home: $codex_home"
echo "backup: $backup_root"
echo "next: run 'codex login'"
