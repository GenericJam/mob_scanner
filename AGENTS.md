# mob_scanner — Agent Instructions

You're in **mob_scanner**, a Mob plugin whose only surface is a full-screen scanner view: `MobScanner.scan(socket)` opens the camera, the OS detects a QR / barcode, the view dismisses itself, and the result is delivered back to the calling screen as `handle_info({:scan, :result, %{type: _, value: _}}, socket)`. Extracted from mob core in Wave 3 of the plugin epic.

**Also read [`~/code/mob/AGENTS.md`](../mob/AGENTS.md)** for the system view — mob's three-repo topology, plugin manifest schema, `Mob.Composite` / `Mob.Sigil`, how to drive a running app from your session, and the cross-cutting pre-empt-failure rules. This file is mob_scanner-specific.

> **Keep this file current.** When you change delivered-message shapes, add a symbology, land a new host-app requirement, or hit a gotcha that would trip the next agent, fix it here in the same commit — not in a follow-up.

## What mob_scanner is, in one paragraph

A single-purpose scanning surface. `MobScanner.scan/2` calls into `:mob_scanner_nif` which pushes a full-screen view controller (iOS: `MobScannerVC` wrapping `AVCaptureMetadataOutput`) or launches a full-screen activity (Android: plugin-owned `io.mob.scanner.MobScannerActivity`, CameraX + ML Kit `BarcodeScanning`). Detection dismisses the surface. iOS delivers the result as direct Erlang terms `{:scan, :result, %{type: atom, value: binary}}`; Android delivers a `{:mob_file_result, "scan", "result", json_binary}` tuple that mob core's `Mob.Screen` server decodes into the same user-facing shape (`lib/mob/screen/server.ex:732-741`). The other terminal messages are direct `{:scan, atom}` tuples on both platforms: `:cancelled` (closed without a code), `:permission_denied` (camera access denied/restricted or refused at the prompt — nothing is presented; MOB-292), and `:not_available` (the scanner couldn't open: iOS found no camera input, Android failed to launch the Activity — cause logged under the `MobScanner` logcat tag; MOB-293).

## What mob_scanner is NOT

* **Not `mob_camera`.** That plugin owns general photo / video capture *and* the `:camera` runtime permission (its iOS registry handler and its Android `MobPermissionProvider` mapping). mob_scanner is a specialised surface for reading codes; it deliberately does not double-register `:camera`. If you want to take a picture, you want `mob_camera`.
* **Not `mob_photos`.** That's the system picker — reading images the user already has. mob_scanner reads codes off a live camera feed. Different surface, different permission story.
* **Not a decoder library.** No JS/QR parsing lives here; iOS `AVCaptureMetadataOutput` and Android ML Kit do the recognition. If a symbology isn't detected on one platform, the fix is in the platform's config (see `metadataObjectTypes` on iOS, ML Kit's default set on Android), not in Elixir.

## Anatomy of the plugin

* `lib/mob_scanner.ex` — the entire public API: `MobScanner.scan/2` + the `format` type. Delivered-message shapes are documented here canonically.
* `lib/mob_scanner/self_test.ex` — `MobScanner.SelfTest` (`Mob.Plugin.SelfTest`, manifest `selftest:`), run by `mix mob.selftest`. Calls only `:mob_scanner_nif.scanner_available/0`, the side-effect-free NIF both platforms export for it (iOS: capture-device lookup; Android: `MobScannerBridge.scanner_available()` resolves the `MobScannerActivity` Intent and checks `FEATURE_CAMERA_ANY`; the zig NIF answers `{:error, :bridge_not_registered}` when `register()` never ran). Never call `scanner_scan/1` from it — that opens the camera UI.
* `priv/mob_plugin.exs` — plugin manifest. `nifs` split by `platform:` (`:ios` compiles `.m` with `-fobjc-arc`, `:android` compiles the sibling `.zig`). No `:permissions` capability — that's mob_camera's. iOS `frameworks: ["AVFoundation"]`; Android `bridge_class: "io.mob.scanner.MobScannerBridge"` + CameraX / ML Kit `gradle_deps` kept in lockstep with mob_camera + the scanner `<activity>` via `manifest_application_snippets` (spliced into the host manifest by the native build). `host_requirements` prints the mob_camera reminder on every native build.
* `priv/native/ios/mob_scanner_nif.m` — Objective-C NIF. Extracted from `mob-core ios/mob_nif.m:2939-3046`; ships its own `scan_send2` / `scan_root_vc` because core's equivalents are private statics.
* `priv/native/jni/mob_scanner_nif.zig` — Zig NIF. Extracted from core's `mob_nif.zig` scanner paths; reaches ERTS / JNI via `@import("erts")` / `@import("jni")`, links against `get_jenv` / `g_jvm` exported from mob core into the same `.so`.
* `priv/native/android/MobScannerBridge.kt` — Kotlin bridge. Registers directly on the ComponentActivity's `ActivityResultRegistry` (a late-bound plugin can't reference the generated `MainActivity`); launches `MobScannerActivity`; the pid travels through the closure, not through core's static `pendingScanPid`.
* `MobScannerActivity` — the full-screen scanner Activity, a second top-level class in `MobScannerBridge.kt` (the bridge_kt channel copies one file per plugin). `AppCompatActivity` subclass (CameraX PreviewView + ML Kit want an AppCompat context).
* `test/mob_scanner_test.exs` — Elixir suite. Manifest validation via `MobDev.Plugin.{Manifest, Validator}`. `test/mob_scanner/self_test_test.exs` covers every `SelfTest` branch with stub NIF modules.

## Cross-repo work

**mob_camera (peer plugin, hard dependency at runtime):** the `:camera` runtime permission and the iOS `NSCameraUsageDescription` plist key both live in mob_camera. mob_scanner intentionally omits both from its manifest — declaring them here would double-register the permission handler and collide in the plist merge. Any change to how `:camera` is requested or how the plist key is authored is a **mob_camera** change; touch mob_camera and mob_scanner in the same PR only when the coupling has to shift. The two plugins also keep their CameraX / ML Kit `gradle_deps` version-locked (the native merge set-unions them, so mismatched versions would silently disagree).

**mob (framework):** the Android result path routes through core's `Mob.Screen.Server` decoder (`lib/mob/screen/server.ex:732-741`) which turns `{:mob_file_result, "scan", "result", json}` into the `{:scan, :result, %{...}}` tuple screens actually match on. If that decoder moves or the tuple shape changes, this repo's `@moduledoc` is wrong — update both. There is intentionally **no `<Scanner>` view node** in mob core: scanning is imperative (`MobScanner.scan/2` from an event handler), not declarative.

**mob_dev:** the pre-publish manifest validator that CI runs is `MobDev.Plugin.Validator`; the test suite here exercises it against the real `priv/mob_plugin.exs`, so a validator change in mob_dev can break this build without any change here.

## Testing

Elixir suite:

```bash
mix deps.get
MIX_ENV=test mix test
```

Native changes (`.m` / `.zig` / `.kt`) are **not** exercised by `mix test` — they need `mix mob.deploy --native` of a host app (mob_plugin_demo is the working target) and a physical-device scan before committing. Simulators lie for camera work: iOS Simulator has no real `AVCaptureDevice`, and Android emulators don't reproduce the OEM camera permission quirks.

Coverage priorities as issues land:
* Plugin manifest loads + validates.
* `MobScanner.scan/2` returns the socket unchanged (it's a side-effect call).
* `formats` option is atom-normalised + JSON-encoded correctly (even though native currently ignores it — see below).

## The pre-empt-failure rules that matter here

1. **You need mob_camera activated too.** If mob_scanner is added without mob_camera, iOS builds fine and then dies at first scan (no `NSCameraUsageDescription` — the scanner's own `requestAccessForMediaType:` for an undecided status needs it too). Android works standalone for the permission itself (the bridge requests `android.permission.CAMERA` when it isn't granted), but the `:camera` capability for `Mob.Permissions` still only exists via mob_camera. The host README and every `mob_plugin.exs :host_requirements` entry says this — don't quietly drop that reminder.

2. **The `formats:` option is passed through but currently ignored by both native sides.** iOS hardcodes `metadataObjectTypes` (`ios/mob_scanner_nif.m` / core `mob_nif.m:2966-2971`); Android scans all default ML Kit formats. This is **preserved core-parity behaviour**, not a bug — the argument is encoded and shipped so honoring it later is a non-breaking change. Do not write docs that promise per-format filtering until the native side actually filters.

3. **The scanner Activity is contributed by the manifest, not the host.** `priv/mob_plugin.exs` `android.manifest_application_snippets` carries `<activity android:name="io.mob.scanner.MobScannerActivity" android:exported="false" android:theme="@style/Theme.AppCompat.NoActionBar" />`; the native build splices it into the host's `<application>`. Don't move it back to `host_requirements`: mob_new ≥ 0.4.0 stopped declaring it, and a reminder-only requirement shipped an app that built, booted, and crashed with `ActivityNotFoundException` at first scan. Without the AppCompat theme, `setContentView` throws `IllegalStateException`.

4. **Delivered-message shapes are core-parity — don't drift.** iOS sends direct Erlang terms; Android sends `{:mob_file_result, ...}` that core decodes. If you change one side, either change both platforms *and* the core decoder in the same PR, or document why the asymmetry is deliberate (as it is today).

5. **`:camera` permission belongs to mob_camera; keep it there.** It is very tempting, when a user hits "camera not permitted", to add a `:permissions` entry to `priv/mob_plugin.exs` here so mob_scanner "just works" standalone. Don't. That double-registers the handler on iOS. Instead, fix mob_camera's permission flow or the docs that point users at it. What `scan/2` does itself is narrower and deliberate (MOB-292): read the OS authorization status, prompt only when it is undecided, and otherwise deliver `{:scan, :permission_denied}` *before* presenting anything — a capture session started without the grant renders a black preview until cancel.

6. **Nothing the bridge launches may throw on the caller's thread, or silently die.** `scanner_scan` runs on a BEAM scheduler thread; any exception escaping it (or the UI-thread block it posts) is uncaught and kills the whole app process. Registry register/launch goes through `launchForResult`, which first rejects a host Activity that is finishing, destroyed, or no longer the current `activityRef` (its registry would never dispatch a result, leaving the scan without a terminal message), then catches, unregisters, logs, and delivers `{:scan, :not_available}` for either case (MOB-293). Route new launches through it.

## Pre-commit checklist

Before committing, run in this order:

```bash
mix test
mix format
mix credo --strict            # includes ExSlop + jump_credo_checks
```

Native changes (`.m` / `.zig` / `.kt`) need `mix mob.deploy --native` of a host app (mob_plugin_demo) and a physical-device scan before committing (see Testing).

Pre-push hook (`.githooks/pre-push`, activated by `git config core.hooksPath .githooks`, or run `mix setup` after clone) adds format-check + credo strict + `mix compile --warnings-as-errors` on every push, and the full suite when `mix.exs` changes (release preflight).

## Release flow

Canonical process in [`~/code/mob/RELEASE.md`](../mob/RELEASE.md). mob_scanner specifics:

* Do NOT bump versions without explicit permission.
* `@version` in `mix.exs` is the trigger; pushing a bump to master fires `.github/workflows/release.yml` (tag + GH release + `hex.publish`, each step idempotent).
* CI verifies `MOB_PLUGIN_SIGN_KEY` matches the committed `priv/mob_plugin.pub` before publish (see `8ba90c3`).
* The `mob` floor pin in `mix.exs` is load-bearing; do not bump if this plugin starts using a new mob feature that hasn't shipped on Hex yet.
* **Never ship without device verification against a real camera.** Simulators / emulators mask both the permission flow and the AVFoundation / CameraX failure modes.
