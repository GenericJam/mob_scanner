defmodule MobScannerTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, Validator}

  @plugin_dir Path.expand("..", __DIR__)

  describe "plugin manifest" do
    setup do
      {:ok, manifest} = Manifest.load(@plugin_dir)
      %{manifest: manifest}
    end

    test "loads and validates clean (round-trips)", %{manifest: m} do
      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "classifies as tier 1 (NIF plugin)", %{manifest: m} do
      assert Manifest.tier(m) == 1
    end

    test "passes the full pre-publish validator (paths, NIF modules)", %{manifest: m} do
      assert %{errors: []} = Validator.validate_plugin(m, @plugin_dir)
    end

    test "declares the cross-platform NIF pattern: one module, both platforms",
         %{manifest: m} do
      assert [ios, android] = m.nifs
      assert ios.module == :mob_scanner_nif and ios.platform == :ios and ios.lang == :objc
      assert android.module == :mob_scanner_nif and android.platform == :android
      assert android.lang == :zig
    end

    test "declares NO runtime-permission capability (:camera is owned by mob_camera)",
         %{manifest: m} do
      refute Map.has_key?(m, :permissions)
    end

    test "declares android.permission.CAMERA so scanner-without-mob_camera still has the uses-permission",
         %{manifest: m} do
      assert "android.permission.CAMERA" in m.android.permissions
    end

    test "carries the CameraX + ML Kit + AppCompat gradle deps moved out of the mob_new template",
         %{manifest: m} do
      assert "com.google.mlkit:barcode-scanning:17.3.0" in m.android.gradle_deps
      assert "androidx.camera:camera-camera2:1.4.2" in m.android.gradle_deps
      assert "androidx.camera:camera-lifecycle:1.4.2" in m.android.gradle_deps
      assert "androidx.camera:camera-view:1.4.2" in m.android.gradle_deps
      assert "androidx.appcompat:appcompat:1.6.1" in m.android.gradle_deps
    end

    test "iOS needs only the AVFoundation framework; the camera plist key stays with mob_camera",
         %{manifest: m} do
      assert m.ios.frameworks == ["AVFoundation"]
      refute Map.has_key?(m.ios, :plist_keys)
    end

    test "contributes the scanner <activity> with an AppCompat theme to the host manifest",
         %{manifest: m} do
      assert [snippet] = m.android.manifest_application_snippets
      assert snippet =~ ~s(android:name="io.mob.scanner.MobScannerActivity")
      assert snippet =~ ~s(android:exported="false")
      assert snippet =~ "Theme.AppCompat.NoActionBar"
    end

    test "host_requirements keep the mob_camera dependency reminder", %{manifest: m} do
      assert Enum.any?(m.host_requirements, &(&1 =~ "mob_camera" and &1 =~ ":camera"))
    end

    test "every native source dir + Kotlin bridge + scanner Activity the manifest references exists",
         %{manifest: m} do
      for %{native_dir: dir} <- m.nifs do
        assert File.dir?(Path.join(@plugin_dir, dir)), "missing #{dir}"
      end

      assert File.exists?(Path.join(@plugin_dir, m.android.bridge_kt))

      # The Activity ships next to the bridge (same io.mob.scanner package);
      # it is launched by Intent from the bridge and must exist for the
      # contributed <activity> declaration to resolve.
      assert File.exists?(Path.join(@plugin_dir, "priv/native/android/MobScannerBridge.kt"))
    end
  end

  describe "NIF stub agreement" do
    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "the manifest NIF module is the shipped .erl stub and loads on the host" do
      assert Code.ensure_loaded?(:mob_scanner_nif)
    end

    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "every NIF the public API calls is exported by the stub at the right arity" do
      exports = :mob_scanner_nif.module_info(:exports)

      for fa <- [scanner_scan: 1] do
        assert fa in exports, "#{inspect(fa)} missing from mob_scanner_nif exports"
      end
    end

    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "host (no native linked) falls back to nif_not_loaded, not a load crash" do
      assert_raise ErlangError, ~r/nif_not_loaded/, fn ->
        :mob_scanner_nif.scanner_scan(:json.encode(["qr"]))
      end
    end
  end

  describe "Android JNI linkage" do
    # A Kotlin `external fun` with no matching zig export throws
    # UnsatisfiedLinkError the first time it runs. The terminal-status thunks
    # (:not_available, :permission_denied) only run on failure paths a
    # happy-path device scan never takes, so a missing export would ship.
    @describetag :requires_zig
    @describetag :tmp_dir

    test "the bridge's Kotlin externals and the zig NIF's JNI exports are the same set",
         %{tmp_dir: tmp} do
      jni_dir = Path.join(Mix.Project.deps_paths()[:mob], "android/jni")
      obj = Path.join(tmp, "mob_scanner_nif.o")

      {out, status} =
        System.cmd(
          "zig",
          [
            "build-obj",
            "-target",
            "aarch64-linux-android",
            "-femit-bin=#{obj}",
            "--dep",
            "erts",
            "--dep",
            "jni",
            "-Mroot=" <> Path.join(@plugin_dir, "priv/native/jni/mob_scanner_nif.zig"),
            "-Merts=" <> Path.join(jni_dir, "mob_erts.zig"),
            "-Mjni=" <> Path.join(jni_dir, "mob_zig.zig")
          ],
          stderr_to_stdout: true
        )

      assert status == 0, out

      {symbols, 0} = System.cmd("nm", ["-g", obj])

      exported =
        ~r/ T Java_io_mob_scanner_MobScannerBridge_(\w+)/
        |> Regex.scan(symbols, capture: :all_but_first)
        |> MapSet.new(&hd/1)

      externals =
        ~r/external fun (\w+)/
        |> Regex.scan(
          File.read!(Path.join(@plugin_dir, "priv/native/android/MobScannerBridge.kt")),
          capture: :all_but_first
        )
        |> MapSet.new(&hd/1)

      assert externals == exported
    end
  end

  describe "public API surface (extraction parity with old Mob.Scanner)" do
    test "exports the full extracted surface" do
      exports = MobScanner.__info__(:functions)

      for fa <- [scan: 1, scan: 2] do
        assert fa in exports, "#{inspect(fa)} missing from MobScanner"
      end
    end
  end
end
