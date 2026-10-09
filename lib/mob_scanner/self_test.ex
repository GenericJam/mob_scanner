defmodule MobScanner.SelfTest do
  @moduledoc """
  The plugin's on-device proof (`Mob.Plugin.SelfTest`), run by
  `mix mob.selftest` and mob_ci for every activated plugin.

  The scanner's only feature, `MobScanner.scan/2`, opens a full-screen camera
  view, so the test never calls it. It asks the side-effect-free
  `:mob_scanner_nif.scanner_available/0` instead: no camera input is opened,
  no permission is requested, nothing is presented or launched.

    * **iOS** — the Objective-C NIF runs the same
      `AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo` lookup
      `scan/2` does before presenting. Any answer proves the NIF is linked and
      registered via `ERL_NIF_INIT`. `:available` (a capture device exists) is
      a pass. `:no_camera` is `{:skip, :needs_hardware}`: the iOS Simulator
      has no capture device, so this is the expected result there, and a scan
      on it would end in `{:scan, :not_available}`.
    * **Android** — the zig NIF calls `MobScannerBridge.scanner_available()`
      through the method ID cached by `nativeRegister`, so any answer proves
      the Kotlin bridge is registered. The bridge resolves the explicit
      `MobScannerActivity` Intent against the host's `PackageManager` (the
      same lookup the scan launch does) and then checks
      `FEATURE_CAMERA_ANY`. `:available` is a pass: the bootstrap handed the
      bridge an Activity, the manifest snippet declared the scanner Activity,
      and a camera exists (a default emulator emulates one, so a pass is
      expected there). `:no_camera` is `{:skip, :needs_hardware}`, reported
      only after the Activity check passed.
    * Failures: the host stub's `nif_not_loaded`;
      `{:error, :bridge_not_registered}` (`register()` never ran or the
      method-ID lookup failed); `{:error, :no_activity}` (the bootstrap never
      called `setActivity`, a scan would only ever answer `:cancelled`);
      `{:error, :activity_not_declared}` (the manifest snippet was not spliced,
      a scan would answer `:not_available`); `{:error, :query_failed}` (the
      PackageManager query threw); `{:error, :no_jni_env}` (the NIF could not
      attach to the JVM); anything else.
  """
  @behaviour Mob.Plugin.SelfTest

  @impl true
  def run(ctx), do: run(ctx, :mob_scanner_nif)

  @doc false
  @spec run(Mob.Plugin.SelfTest.ctx(), module()) :: Mob.Plugin.SelfTest.result()
  def run(%{platform: platform}, nif) do
    case nif.scanner_available() do
      :available ->
        :pass

      :no_camera ->
        {:skip, :needs_hardware}

      {:error, :bridge_not_registered} ->
        {:fail,
         "scanner_available/0 on #{platform} returned {:error, :bridge_not_registered}: " <>
           "MobScannerBridge.register() never ran or its method-ID lookup failed, expected :available or :no_camera"}

      {:error, :no_activity} ->
        {:fail,
         "scanner_available/0 on #{platform} returned {:error, :no_activity}: the plugin bootstrap " <>
           "never handed MobScannerBridge an Activity, expected :available or :no_camera"}

      {:error, :activity_not_declared} ->
        {:fail,
         "scanner_available/0 on #{platform} returned {:error, :activity_not_declared}: " <>
           "io.mob.scanner.MobScannerActivity is not in the host manifest, expected :available or :no_camera"}

      other ->
        {:fail,
         "scanner_available/0 on #{platform} returned #{inspect(other)}, expected :available or :no_camera"}
    end
  rescue
    e in [ErlangError, UndefinedFunctionError] ->
      {:fail, "#{nif} is not linked into this build: #{Exception.message(e)}"}
  end
end
