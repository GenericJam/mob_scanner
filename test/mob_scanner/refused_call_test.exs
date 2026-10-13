defmodule MobScanner.RefusedCallTest do
  # Not async: the stub NIF goes into the :mob_scanner app env, which is global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  defmodule UnregisteredBridgeNif do
    def scanner_scan(_formats_json), do: {:error, :bridge_not_registered}
  end

  defmodule AcceptingNif do
    def scanner_scan(_formats_json), do: :ok
  end

  setup do
    on_exit(fn -> Application.delete_env(:mob_scanner, :nif) end)
    %{socket: Mob.Socket.new(__MODULE__)}
  end

  test "a refused scan is logged with the function and reason, and still returns the socket",
       %{socket: socket} do
    Application.put_env(:mob_scanner, :nif, UnregisteredBridgeNif)

    log = capture_log(fn -> assert MobScanner.scan(socket) == socket end)
    assert log =~ "MobScanner.scan/2"
    assert log =~ ":bridge_not_registered"
  end

  test "an accepted scan logs nothing", %{socket: socket} do
    Application.put_env(:mob_scanner, :nif, AcceptingNif)

    assert capture_log(fn -> assert MobScanner.scan(socket) == socket end) == ""
  end
end
