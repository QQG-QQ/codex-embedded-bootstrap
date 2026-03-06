# Embedded Linux Change Checklist

Use this checklist when a change touches multiple layers.

## Scope Mapping

- Bootloader: U-Boot, startup scripts, partition layout, secure boot assumptions.
- Kernel: config fragments, driver changes, Kconfig dependencies, module ABI.
- Device Tree: pinmux, clocks, regulators, interrupts, aliases, compatibles.
- Middleware/System: init system, service ordering, IPC contracts, permissions.
- Userspace: daemons/tools/scripts and backward compatibility with existing configs.
- Build system: Yocto/Buildroot recipes, patches, layer priority, CI pipeline steps.

## Build and Test Gates

- Clean build path documented (full image or target package build).
- Incremental build path documented for faster iteration.
- Unit/integration tests selected for impacted module(s).
- Runtime smoke test command list prepared (boot, service up, key I/O path).

## Regression Risk Checks

- Backward compatibility with existing device variants.
- ABI/API impact documented for kernel modules and userspace consumers.
- Boot-time and memory footprint impact checked.
- Error-path behavior verified (missing device, timeout, bad config).

## Patch Hygiene

- Diff is scoped to a coherent objective.
- Generated files are excluded unless required.
- Commit or patch message explains what changed, why, and how validated.
- Rollback strategy is defined for deployment environments.

## Review Packaging

- Include `changes.diff`, `diffstat.txt`, `changed-files.txt`.
- Include module grouping (`module-roots.txt`) for architecture review.
- Include explicit review focus (for example: ABI risk, sequencing, layering).
