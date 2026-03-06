# AGENTS.md

## Default Rule For This Workspace

Use `embedded-linux-hybrid-workflow` as the default for software work unless the user explicitly overrides it.

Primary policy:
- `Codex` is the main execution engine (edit/build/test/fix/patch).
- `Claude` is the secondary review engine (architecture explanation, design docs, refactor roadmap).

## Model Routing (User Locked)

Use this model preference order by default:
- capability ceiling: `GPT-5.4 pro`
- coding execution (Codex scenarios): `GPT-5.3-Codex`
- architecture and complex professional analysis: `GPT-5.4`

Routing policy:
- implementation/debug/build/test loops should prioritize the Codex execution path
- architecture tradeoff analysis and refactor-roadmap tasks should invoke secondary architecture review
- if secondary backend is unavailable (runtime/auth/network/subscription), continue with Codex-only execution and explicitly mark fallback status

## Embedded Full-Stack Scope

Default problem-solving scope is end-to-end embedded engineering:
- hardware interfaces and board-level constraints (power, clocks, pinmux, buses, interrupts, reset paths)
- boot and low-level stack (ROM/bootloader, kernel, dts/dtsi, drivers)
- system and middleware (filesystems, services, IPC, security, update/recovery)
- userspace applications, tooling, build system, CI, release validation

Expectations:
- analyze issues from low level to high level and back (cross-layer root-cause first)
- provide actionable fixes with validation commands and risk notes
- do not stop at analysis when implementation and verification are feasible

## Standard Execution Path

Preferred one-command orchestration:

```bash
bash /home/ameba_builder/.codex/skills/embedded-linux-hybrid-workflow/scripts/hybrid-run.sh \
  --build "<build_cmd>" \
  --test "<test_cmd>"
```

Expanded path:
1. Codex execution loop (`run-codex-ci-loop.sh`)
2. Review bundle export (`prepare-review-bundle.sh`)
3. Claude architecture review (`request-claude-architecture-review.sh`)
4. Codex applies high-priority review feedback and re-validates

## Task Routing And PR Size Policy

Default routing:
- Tier 0 (single-file, low-risk, no API/ABI/config impact): `Codex only` fast path (skip Claude bundle/review by default)
- Tier 1+ (touches 3+ files, 2+ layers, or API/ABI/config changes): full `embedded-linux-hybrid-workflow`

PR/change sizing:
- prefer small, single-purpose changes
- target: <= 300 changed lines and <= 8 files when feasible
- if expected change is larger, split into phased patches with clear dependency order

## Delivery Metrics Baseline (DORA)

Track and review these metrics:
- deployment frequency
- lead time for changes
- change failure rate
- failed deployment recovery time
- reliability

Review cadence:
- lightweight check every 2 weeks
- deeper trend review monthly

Use the metrics to identify bottlenecks before process/tool changes.

## Context Gathering Rules (Claude-Inspired)

Before deep implementation, gather compact context:
- README and main build/config files
- directory/module scope related to the task
- current branch/head and workspace status

Budget:
- Tier 0: hard cap 10 minutes or 8 meaningful discovery commands (whichever comes first)
- Tier 1+: hard cap 20 minutes or 15 meaningful discovery commands unless blocked by unknown architecture/API constraints
- stop immediately when target files, expected outputs, and validation commands are clear

`hybrid-run.sh` auto-generates `context-snapshot.md`.

## Execution Timebox And WIP Limits

To reduce process overhead:
- WIP limit = 1 active implementation task at a time
- do not open a second coding thread before the first has build/test outcome
- if analysis budget is exhausted, choose the smallest reversible implementation and validate quickly

## CI Feedback Loop Optimization

CI defaults:
- enable dependency/build caching where the CI platform supports it
- parallelize independent test partitions when deterministic and stable
- prioritize fast pre-merge checks; keep long-running suites in post-merge/nightly lanes

## Exploration Trigger Rules

Do deeper exploration before coding when any condition is true:
- task touches 3+ files or 2+ system layers
- multiple valid implementation approaches exist
- architecture/API/ABI decision is required

In those cases, explicitly document:
- assumptions
- selected approach and tradeoffs
- files/modules to change
- validation commands

## Build/Test Failure Policy

Default behavior:
- classify failures with `classify-build-failure.sh`
- retry transient failures once (configurable): network timeout, registry/index fetch error, mirror hiccup, runner interruption
- fast-fail deterministic failures
- write fallback/retry decisions into summary/report artifacts

Recommended runner:

```bash
bash /home/ameba_builder/.codex/skills/embedded-linux-hybrid-workflow/scripts/run-codex-ci-loop.sh \
  --max-retries 1 \
  --retry-delay 5 \
  "<build_cmd>" "<test_cmd>" [output_dir]
```

## Testing Quality Bar (Claude-Inspired)

For non-trivial tasks, map tests to requirement scenarios:
- happy path
- edge/boundary conditions
- error/failure handling
- state transitions (if stateful)

Do not mark task complete if only partial scenario coverage is validated.

## Completion Gates

Do not mark a task complete until all applicable gates pass:
- build succeeds
- tests mapped to required scenarios pass
- lint/static checks pass (if defined by repo)
- no unresolved high-priority review findings

## Claude Review Trigger (Secondary Engine)

Invoke Claude review when any of these is true:
- user asks for architecture walkthrough/design explanation/doc
- user asks for refactor strategy or phased roadmap
- change spans bootloader/kernel/dtb/driver/middleware/userspace/build/CI
- change touches 3+ files or 2+ system layers
- API/ABI or backward-compatibility risk is present

Do not invoke Claude review for Tier 0 unless user explicitly requests it.

Default review flow:

```bash
bash /home/ameba_builder/.codex/skills/embedded-linux-hybrid-workflow/scripts/prepare-review-bundle.sh [output_dir] [base_ref]
bash /home/ameba_builder/.codex/skills/embedded-linux-hybrid-workflow/scripts/request-claude-architecture-review.sh [bundle_dir] [focus]
```

## AI-Assisted Coding Guardrails

Use AI-generated code as a draft, not final output:
- require human review before merge
- require automated test evidence for changed behavior
- run security-relevant checks where available (SAST/dependency/license/secret scan)
- avoid accepting generated code that introduces unknown dependencies without review

For prompts/instructions, include security expectations explicitly:
- input validation and error handling
- authn/authz boundaries and least privilege
- secrets handling and logging hygiene
- dependency and supply-chain risk awareness

## Artifact Directory Standard

For non-trivial tasks, store run artifacts under:
- `artifacts/<YYYY-MM-DD>/<task-id>/`

Expected contents:
- `context-snapshot.md`
- build/test logs
- patch/diff artifacts
- review notes and final summary

## Required Deliverables

Tier 0 final output (minimal):
- changed file(s)
- key build/test command result (or explicit skip reason)
- one-line residual risk or next validation step

For non-trivial tasks, final output should include:
- changed files/modules summary
- build/test results with key commands
- patch/diff artifact status
- Claude findings (if invoked) and prioritized action list
- residual risks, assumptions, and next validation step

## Embedded Linux Checklist

For cross-layer changes, consult:

`/home/ameba_builder/.codex/skills/embedded-linux-hybrid-workflow/references/embedded-linux-checklist.md`

## Override Rules

- If user says `Codex only`, skip Claude review.
- If user says `analysis only` or `no code changes`, do not run execution loop.
- If Claude backend is unavailable, continue with Codex-only path and mark Claude status as `unavailable (runtime|auth|network)` in reports.

## Git Sync Policy

Default for this workspace:
- for completed updates, commit and push changes to the configured Git remote `main` branch
- unless the user explicitly says not to commit/push
- if push is blocked by auth/network/policy, report the exact failure and stop without rewriting history
- this includes Codex capability/rule/workflow optimizations, especially changes in:
  - `AGENTS.md`
  - `~/.codex/skills/embedded-linux-hybrid-workflow/scripts/*`
  - bootstrap installer/update assets used for environment recovery
