# Changelog

All notable changes to **mob_scanner** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

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
