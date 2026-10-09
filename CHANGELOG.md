# Changelog

All notable changes to **mob_scanner** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added

- **On-device self-test** (MOB-418). `MobScanner.SelfTest` implements
  `Mob.Plugin.SelfTest` and is declared in the manifest as `selftest:`.
  It calls the new side-effect-free NIF `:mob_scanner_nif.scanner_available/0`
  and never opens the scanner. iOS answers from
  `AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo` (`:available`
  or `:no_camera`). Android calls `MobScannerBridge.scanner_available()`
  through the method ID cached at `nativeRegister`; the bridge resolves the
  `MobScannerActivity` Intent against the host manifest and checks
  `FEATURE_CAMERA_ANY`, answering `:available`, `:no_camera`,
  `{:error, :no_activity}` or `{:error, :activity_not_declared}`, and the NIF
  answers `{:error, :bridge_not_registered}` when `register()` never ran.
  `:available` passes, `:no_camera` is `{:skip, :needs_hardware}` (expected
  on the iOS Simulator), everything else fails. Run it with
  `mix mob.selftest` from a host app (mob_dev 0.7.17). Requires mob 0.9.15;
  `mob_version` in the manifest is now `~> 0.9`.

## [0.1.5] - 2026-09-30

### Behaviour change — screens must handle two more terminal messages

`scan/2` can now end in `{:scan, :permission_denied}` on both platforms.
Before, iOS showed a black preview until Cancel, which sent
`{:scan, :cancelled}`, and Android ended in `{:scan, :cancelled}`. On
Android it can also end in `{:scan, :not_available}`, where before a launch
failure crashed the app. A screen that overrides `handle_info/2` with only
`:result`/`:cancelled` clauses and no catch-all will now crash with
`FunctionClauseError`, so add clauses for both (see the README). Android
`scan/2` now shows the CAMERA permission dialog itself when the permission
isn't granted.

### Fixed
- **iOS: scanning before `:camera` was granted left a black preview until
  Cancel** (MOB-292). `scan/2` now checks the AVFoundation authorization
  status before presenting: undecided → shows the system prompt and opens the
  scanner once granted; denied/restricted (or refused at the prompt) → delivers
  the new `{:scan, :permission_denied}` without presenting anything. The camera
  input is also opened before presenting, so `{:scan, :not_available}` no
  longer comes from a modal that has to dismiss itself mid-presentation.
- **Android: an exception launching the scanner killed the whole app process**
  (MOB-293). `scanner_scan` threw `ActivityNotFoundException` (e.g. no
  `MobScannerActivity` in the host manifest) on the NIF-calling thread,
  uncaught. Registration and launch now run on the UI thread inside a guard
  that unregisters the launcher, logs the cause under the `MobScanner` logcat
  tag, and delivers `{:scan, :not_available}`. A host Activity that is
  finishing, destroyed, or replaced by the time the queued launch runs is
  rejected before anything is registered, with the same message.

### Changed
- **Signed with mob_dev 0.7.3** (MOB-297). The signature now covers every
  native build input, including the iOS `.m` NIF source this release changes.
  It verifies on host mob_dev ≥ 0.7.2, and the coverage check is enforced on
  ≥ 0.7.3.

## [0.1.4] - 2026-09-30

### Changed
- **Re-signed with plugin envelope v2** (MOB-287). mob_dev 0.7.2+ verifies
  this signature before evaluating the manifest. mob_dev 0.7.0 / 0.7.1 can't
  read v2 signatures and report this release as `invalid signature` —
  upgrade the host app to `{:mob_dev, "~> 0.7.2", only: :dev, runtime: false}`.
  No plugin code changes.

## [0.1.3] - 2026-09-30

### Fixed
- **Android: first scan crashed the app with `ActivityNotFoundException`.**
  mob_new ≥ 0.4.0 stopped declaring `io.mob.scanner.MobScannerActivity` in the
  generated `AndroidManifest.xml` (the scanner moved into this plugin), and the
  plugin only printed a `host_requirements` reminder, so every freshly
  generated app crashed at the first `MobScanner.scan/2`. The manifest now
  contributes the `<activity>` (AppCompat theme) via
  `android.manifest_application_snippets`; the native build splices it in and
  skips it when the host already declares it. Requires mob_dev ≥ 0.6.19.

## [0.1.2] - 2026-08-25

### Fixed
- **Android 15+ 16 KB page-alignment warning.** `libimage_processing_util_jni.so`
  (androidx.camera) and `libbarhopper_v3.so` (com.google.mlkit:barcode-scanning)
  were flagged as not 16 KB page-aligned on Android 15+ devices/emulators.
  Bumped `androidx.camera:camera-{camera2,lifecycle,view}` 1.3.4 → 1.4.2 (kept
  in lockstep with mob_camera's gradle_deps) and `com.google.mlkit:barcode-scanning`
  17.2.0 → 17.3.0. CameraX deliberately pinned to 1.4.2, not the current-stable
  1.6.x line — 1.6.1 requires compileSdk 36 + AGP 8.9.1+, which a real device
  build against this toolchain's compileSdk 34/AGP 8.2.0 confirmed fails
  outright. Device-verified on a physical Moto G: build, boot, and `MobScanner`
  module load all clean. (MOB-95)

## [0.1.1] - 2026-06-16

### Changed
- Signed release: the published package now carries a verified Ed25519
  signature (shared mob first-party key, regenerated in CI on every
  release). Generated apps trust it via `config :mob, :trusted_plugins`,
  so it clears the plugin signature gate without `acknowledge_unsafe_plugins`.

## [0.1.0] - 2026-06-12

Initial release. QR / barcode scanner for Mob apps.

- `MobScanner.start/2` / `stop/1`. Requires the `mob_camera` plugin for the capture pipeline.
- Extracted from mob core in the 0.7.0 plugin-extraction wave.
- Requires `mob ~> 0.7`.
