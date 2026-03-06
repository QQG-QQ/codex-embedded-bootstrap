# codex-embedded-bootstrap

这是一个用于嵌入式开发场景的 Codex 启动仓库。  
目标是让你在新服务器上执行一次脚本，就能恢复常用配置和技能，然后手动登录账号即可开始工作。

## 这个仓库会做什么

- 安装/检查 `@openai/codex` CLI（缺失时自动安装）
- 安装嵌入式混合工作流技能到 `~/.codex/skills/embedded-linux-hybrid-workflow`
- 将仓库内的 `AGENTS.md` 同步到你指定的工作区
- 自动备份你已有的 `AGENTS.md` 和同名 skill 目录

## 目录说明

- `assets/AGENTS.md`：默认会复制到目标工作区
- `assets/skills/embedded-linux-hybrid-workflow/`：技能文件（脚本+参考）
- `install.sh`：一键安装
- `update.sh`：更新现有安装（不重复安装 codex）

## 前置条件

- Linux/macOS Shell（bash）
- `git`
- `node` + `npm`（用于安装 codex CLI）
- 可访问 npm registry

## 快速开始

```bash
git clone https://github.com/QQG-QQ/codex-embedded-bootstrap.git
cd codex-embedded-bootstrap
bash install.sh --workspace /data/test
```

安装完成后手动登录：

```bash
codex login
```

## 常用参数

```bash
# 指定工作区（会写入 <workspace>/AGENTS.md）
bash install.sh --workspace /data/test

# 仅同步配置，不安装 codex CLI
bash install.sh --workspace /data/test --skip-codex-install

# 指定 CODEX_HOME（默认 ~/.codex）
bash install.sh --workspace /data/test --codex-home /path/to/.codex
```

## 更新配置

```bash
bash update.sh --workspace /data/test
```

## 备份位置

每次安装会生成备份目录：

```text
<workspace>/.codex-bootstrap-backups/<timestamp>/
```

包含旧版 `AGENTS.md` 和旧版 skill（如果存在）。

## 验证安装

```bash
codex --version
ls ~/.codex/skills/embedded-linux-hybrid-workflow/scripts
sed -n '1,40p' /data/test/AGENTS.md
```

## 注意事项

- `install.sh` 会覆盖目标工作区的 `AGENTS.md`（先备份后覆盖）。
- `install.sh` 会替换同名 skill 目录（先备份后替换）。
- 如果你使用 SSH 访问 GitHub，建议把仓库远端改为 `git@github.com:QQG-QQ/codex-embedded-bootstrap.git`。

