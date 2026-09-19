# mob_scanner — Agent Instructions

**Read [`AGENTS.md`](AGENTS.md) first**, then [`~/code/mob/AGENTS.md`](../mob/AGENTS.md) for the system view. Together they cover the plugin anatomy, the mob_camera dependency, the delivered-message shapes, and the host-manifest requirements. This file just lists the mechanical pre-commit gate.

> **Keep AGENTS.md up to date** when you change delivered-message shapes, add a symbology, land a new host-app requirement, or hit a new gotcha. Fix it in the same commit, not in a follow-up.

## Pre-commit checklist

```bash
mix test
mix format
mix credo --strict       # includes ExSlop + jump_credo_checks
```

Native changes (`.m` / `.zig` / `.kt`) aren't exercised by `mix test` — they need `mix mob.deploy --native` of a host app (mob_plugin_demo) and a physical-device scan before committing. Simulators / emulators mask both the permission flow and the AVFoundation / CameraX failure modes.

The pre-push hook (`.githooks/pre-push`, activated via `git config core.hooksPath .githooks` or `mix setup`) runs format / credo / compile on every push and the full suite when `mix.exs` changes (release preflight).

## Releases

`mix.exs` version bump on master triggers `.github/workflows/release.yml` (tag + GitHub Release + Hex publish). See `~/code/mob/RELEASE.md` for the trigger model; do NOT bump versions without explicit permission.
