# Skill compliance evidence register

The release process requires source-backed evidence for the native iOS workflow and the installed iOS skills. This document is intentionally an evidence register rather than a claim that a tool ran.

| Required workflow | Required evidence before release | Current evidence status |
| --- | --- | --- |
| CLI-first project generation | `make bootstrap`, generated scheme, Xcode version/log | Defined in scripts and CI; runtime evidence must be attached |
| Native Liquid Glass review | Source audit plus simulator screenshot confirmation | Surface inventory in `LiquidGlassAudit.md`; visual verification pending |
| UI patterns / state ownership | Code review notes and unit/UI coverage | Architecture documented; final audit pending |
| iOS debugger workflow | Simulator discovery, build, UI description, screenshot, scoped logs | Required by release; no final run claimed here |
| Performance audit | `Artifacts/PerformanceAudit.md` with code-first findings and fixes | Release-blocking artifact required; no final result claimed |
| Memory/memgraph audit | `Artifacts/MemoryAudit.md` with before/after ownership evidence | Release-blocking artifact required; no final result claimed |

The release guard verifies the three audit files exist and rejects release-blocking findings. Fill this register with exact scheme, simulator, commands, run identifiers, and file paths only after the corresponding run completes. It is not acceptable to mark an item complete based on intent or an unexecuted workflow.
