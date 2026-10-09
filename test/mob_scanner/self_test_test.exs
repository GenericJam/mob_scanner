defmodule MobScanner.SelfTestTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, Validator}
  alias MobScanner.SelfTest

  @plugin_dir Path.expand("../..", __DIR__)
  @ios_sim %{platform: :ios, device: :simulator}
  @emulator %{platform: :android, device: :emulator}

  defmodule AvailableNif do
    def scanner_available, do: :available
  end

  defmodule NoCameraNif do
    def scanner_available, do: :no_camera
  end

  defmodule UnregisteredNif do
    def scanner_available, do: {:error, :bridge_not_registered}
  end

  defmodule NoActivityNif do
    def scanner_available, do: {:error, :no_activity}
  end

  defmodule UndeclaredActivityNif do
    def scanner_available, do: {:error, :activity_not_declared}
  end

  defmodule BogusNif do
    def scanner_available, do: :ok
  end

  defmodule NotLoadedNif do
    def scanner_available, do: :erlang.nif_error(:nif_not_loaded)
  end

  defmodule OldStubNif do
    # A stub from before scanner_available/0 existed.
    def scanner_scan(_formats), do: :ok
  end

  defp run(ctx, nif) do
    result = SelfTest.run(ctx, nif)
    assert Mob.Plugin.SelfTest.result?(result), "#{inspect(result)} is not a self-test result"
    result
  end

  test "a native :available answer passes" do
    assert run(@ios_sim, AvailableNif) == :pass
    assert run(@emulator, AvailableNif) == :pass
  end

  test "a native :no_camera answer is a hardware skip, not a failure" do
    assert run(@ios_sim, NoCameraNif) == {:skip, :needs_hardware}
    assert run(@emulator, NoCameraNif) == {:skip, :needs_hardware}
  end

  test "Android integration errors fail, naming what is missing" do
    assert {:fail, reason} = run(@emulator, UnregisteredNif)
    assert reason =~ "bridge_not_registered"
    assert reason =~ "MobScannerBridge.register()"

    assert {:fail, reason} = run(@emulator, NoActivityNif)
    assert reason =~ "no_activity"

    assert {:fail, reason} = run(@emulator, UndeclaredActivityNif)
    assert reason =~ "io.mob.scanner.MobScannerActivity is not in the host manifest"
  end

  test "an unexpected answer fails, saying what came back and what was expected" do
    assert run(@ios_sim, BogusNif) ==
             {:fail, "scanner_available/0 on ios returned :ok, expected :available or :no_camera"}
  end

  test "an unlinked NIF (nif_not_loaded or a missing export) fails, naming the NIF" do
    assert {:fail, reason} = run(@emulator, NotLoadedNif)
    assert reason =~ "is not linked into this build"
    assert reason =~ "nif_not_loaded"

    assert {:fail, reason} = run(@ios_sim, OldStubNif)
    assert reason =~ "is not linked into this build"
    assert reason =~ "scanner_available/0 is undefined"
  end

  test "run/1 on the host (stub .erl, no native library) fails instead of raising" do
    assert {:fail, reason} = SelfTest.run(@emulator)
    assert reason =~ "mob_scanner_nif is not linked into this build"
    assert reason =~ "nif_not_loaded"
  end

  test "the manifest declares it and the validator raises no selftest warning" do
    {:ok, m} = Manifest.load(@plugin_dir)
    assert m.selftest == MobScanner.SelfTest
    assert %{errors: [], warnings: warnings} = Validator.validate_plugin(m, @plugin_dir)
    refute Enum.any?(warnings, &(&1 =~ "selftest"))
  end
end
