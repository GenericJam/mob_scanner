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

  defmodule RecordingNif do
    def scanner_scan(formats_json), do: send(self(), {:scanner_formats, formats_json})
  end

  setup do
    previous = Application.fetch_env(:mob_scanner, :nif)

    on_exit(fn ->
      case previous do
        {:ok, nif} -> Application.put_env(:mob_scanner, :nif, nif)
        :error -> Application.delete_env(:mob_scanner, :nif)
      end
    end)

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

  test "requested formats are atom-normalised and JSON-encoded for native", %{socket: socket} do
    Application.put_env(:mob_scanner, :nif, RecordingNif)

    assert MobScanner.scan(socket, formats: [:qr, :pdf417, :upce]) == socket
    assert_receive {:scanner_formats, formats_json}
    assert formats_json |> IO.iodata_to_binary() |> :json.decode() == ["qr", "pdf417", "upce"]
  end
end
