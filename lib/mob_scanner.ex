defmodule MobScanner do
  @moduledoc """
  QR code / barcode scanner — a Mob plugin (extracted from mob core in
  Wave 3).

  Opens a full-screen camera preview. When a code is detected the view
  dismisses automatically and the result is delivered to `handle_info`.
  A `scan/2` ends in one of:

      handle_info({:scan, :result, %{type: :qr, value: "https://..."}}, socket)
      handle_info({:scan, :cancelled}, socket)
      handle_info({:scan, :permission_denied}, socket)
      handle_info({:scan, :not_available}, socket)

    * `:cancelled` — the scanner closed without a code (the user cancelled;
      on Android also when no host Activity is attached or CameraX can't
      bind the camera).
    * `:permission_denied` — camera access is denied/restricted, or the user
      refused the prompt. Nothing is presented; send the user to Settings.
    * `:not_available` — the scanner could not open: iOS found no camera
      input; Android could not launch `MobScannerActivity`, or the host
      Activity was finishing/destroyed/replaced by launch time (the cause is
      logged to logcat under the `MobScanner` tag).

  **Requires the mob_camera plugin for the `:camera` permission.** The
  `:camera` runtime-permission capability (its registry handler on iOS and
  the `MobPermissionProvider` mapping on Android) is owned by mob_camera —
  activate mob_camera alongside this plugin and request `:camera` via
  `Mob.Permissions.request/2` before calling `scan/2`. mob_camera's manifest
  also carries the iOS `NSCameraUsageDescription` plist key. If `:camera` is
  still undecided when `scan/2` runs, the scanner shows the system prompt
  itself and opens once it is granted.

  iOS: `AVCaptureMetadataOutput`. Android: `CameraX` + ML Kit
  `BarcodeScanning` in a plugin-owned full-screen Activity
  (`io.mob.scanner.MobScannerActivity`), declared in the host manifest by
  the native build from this plugin's manifest.
  """

  @type format ::
          :qr
          | :ean13
          | :ean8
          | :code128
          | :code39
          | :upca
          | :upce
          | :pdf417
          | :aztec
          | :data_matrix

  @doc """
  Open the barcode scanner.

  Options:
    - `formats: [format]` — list of barcode formats to detect (default `[:qr]`)

  Core-parity note: both native sides currently ignore the formats list
  (iOS hardcodes its `metadataObjectTypes`, ios/mob_nif.m:2966-2971; the
  Android activity scans all ML Kit formats) — it is encoded and passed
  through so honoring it later is a non-breaking change.
  """
  @spec scan(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def scan(socket, opts \\ []) do
    formats = Keyword.get(opts, :formats, [:qr]) |> Enum.map(&Atom.to_string/1)
    formats_json = :json.encode(formats)
    :mob_scanner_nif.scanner_scan(formats_json)
    socket
  end
end
