defmodule MobScanner.AndroidWireTest do
  use ExUnit.Case, async: false

  alias MobDev.Plugin.Manifest

  @plugin_dir Path.expand("../..", __DIR__)
  @android_json_dir System.get_env("ANDROID_HOME")
                    |> then(fn
                      nil -> []
                      home -> Path.wildcard(Path.join(home, "sources/android-*/org/json"))
                    end)
                    |> Enum.sort()
                    |> List.last()
  @kotlinc System.find_executable("kotlinc")
  @javac System.find_executable("javac")
  @java System.find_executable("java")
  @missing_tool Enum.find(
                  [
                    {@android_json_dir, "Android SDK sources"},
                    {@kotlinc, "kotlinc"},
                    {@javac, "javac"},
                    {@java, "java"}
                  ],
                  fn {path, _name} -> is_nil(path) end
                )

  if @missing_tool do
    {_path, name} = @missing_tool
    @moduletag skip: "#{name} unavailable; Android wire harness cannot compile"
  end

  setup_all do
    if @missing_tool do
      :ok
    else
      tmp =
        Path.join(
          System.tmp_dir!(),
          "mob_scanner_android_wire_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      {:ok, manifest} = Manifest.load(@plugin_dir)
      bridge = Path.join(@plugin_dir, manifest.android.bridge_kt)
      helper = extract_wire_helper(File.read!(bridge))
      classes = compile_android_json!(tmp)
      jar = compile_kotlin_harness!(tmp, classes, helper)

      %{classpath: Enum.join([jar, classes], ":")}
    end
  end

  test "platform JSON round-trips quotes", context do
    assert_harness!(context, "quote")
  end

  test "platform JSON round-trips backslashes", context do
    assert_harness!(context, "backslash")
  end

  test "platform JSON round-trips newlines and controls", context do
    assert_harness!(context, "control")
  end

  test "serialized UTF-8 round-trips BMP and supplementary Unicode", context do
    assert_harness!(context, "unicode")
  end

  test "decoded value and type UTF-8 limits reject oversize data", context do
    assert_harness!(context, "oversize")
  end

  test "requested formats become the exact ML Kit option set", context do
    assert_harness!(context, "formats")
  end

  defp extract_wire_helper(source) do
    pattern = Regex.compile!("// TESTABLE_WIRE_START\\n(.*?)// TESTABLE_WIRE_END", "s")
    [_, helper] = Regex.run(pattern, source)

    """
    package io.mob.scanner

    import com.google.mlkit.vision.barcode.BarcodeScannerOptions
    import com.google.mlkit.vision.barcode.common.Barcode
    import org.json.JSONArray
    import org.json.JSONException
    import org.json.JSONObject

    #{helper}
    """
  end

  defp compile_android_json!(tmp) do
    source_dir = Path.join(tmp, "json-src/org/json")
    classes = Path.join(tmp, "json-classes")
    File.mkdir_p!(source_dir)
    File.mkdir_p!(classes)

    java_sources =
      @android_json_dir
      |> Path.join("*.java")
      |> Path.wildcard()
      |> Enum.map(fn source ->
        destination = Path.join(source_dir, Path.basename(source))
        File.write!(destination, host_compilable_android_source(File.read!(source)))
        destination
      end)

    {_output, 0} = System.cmd(@javac, ["-d", classes | java_sources], stderr_to_stdout: true)
    classes
  end

  defp host_compilable_android_source(source) do
    imports = Regex.compile!("^import (?:static )?(?:android|libcore)\\..*;\\n", "m")
    annotations = Regex.compile!("@(UnsupportedAppUsage|NonNull|Nullable)\\b")
    system_api = Regex.compile!("@SystemApi\\([^\\n]*\\)")

    source
    |> String.replace(imports, "")
    |> String.replace(annotations, "")
    |> String.replace(system_api, "")
  end

  defp compile_kotlin_harness!(tmp, classes, helper) do
    wire = Path.join(tmp, "ScannerWire.kt")
    barcode = Path.join(tmp, "Barcode.kt")
    options = Path.join(tmp, "BarcodeScannerOptions.kt")
    harness = Path.join(tmp, "WireHarness.kt")
    jar = Path.join(tmp, "wire-harness.jar")

    File.write!(wire, helper)
    File.write!(barcode, barcode_stub())
    File.write!(options, options_stub())
    File.write!(harness, harness_source())

    {output, status} =
      System.cmd(
        @kotlinc,
        [
          "-classpath",
          classes,
          "-include-runtime",
          "-d",
          jar,
          wire,
          barcode,
          options,
          harness
        ],
        stderr_to_stdout: true
      )

    assert status == 0, output
    jar
  end

  defp barcode_stub do
    """
    package com.google.mlkit.vision.barcode.common

    object Barcode {
        const val FORMAT_QR_CODE = 1
        const val FORMAT_EAN_13 = 2
        const val FORMAT_EAN_8 = 3
        const val FORMAT_CODE_128 = 4
        const val FORMAT_CODE_39 = 5
        const val FORMAT_UPC_A = 6
        const val FORMAT_UPC_E = 7
        const val FORMAT_PDF417 = 8
        const val FORMAT_AZTEC = 9
        const val FORMAT_DATA_MATRIX = 10
    }
    """
  end

  defp options_stub do
    """
    package com.google.mlkit.vision.barcode

    class BarcodeScannerOptions private constructor(val formats: IntArray) {
        class Builder {
            private var formats = intArrayOf()

            fun setBarcodeFormats(first: Int, vararg rest: Int) = apply {
                formats = intArrayOf(first, *rest)
            }

            fun build() = BarcodeScannerOptions(formats)
        }
    }
    """
  end

  defp harness_source do
    ~S"""
    package io.mob.scanner

    import com.google.mlkit.vision.barcode.common.Barcode
    import org.json.JSONArray

    private fun assertRoundTrip(value: String, type: String = "qr") {
        val bytes = checkNotNull(ScannerWire.encodeResult(value, type))
        val json = bytes.toString(Charsets.UTF_8)
        val decoded = JSONArray(json).getJSONObject(0)
        check(decoded.getString("value") == value)
        check(decoded.getString("type") == type)
    }

    private fun testFormats() {
        val requested = checkNotNull(
            ScannerWire.barcodeFormats("[\"qr\",\"pdf417\",\"qr\",\"upce\"]")
        )
        check(
            requested.contentEquals(
                intArrayOf(Barcode.FORMAT_QR_CODE, Barcode.FORMAT_PDF417, Barcode.FORMAT_UPC_E)
            )
        )
        val repeated = "[" + List(74) { "\"data_matrix\"" }.joinToString(",") + "]"
        check(repeated.length > 1024)
        check(
            checkNotNull(ScannerWire.barcodeFormats(repeated))
                .contentEquals(intArrayOf(Barcode.FORMAT_DATA_MATRIX))
        )
        val options = checkNotNull(ScannerWire.scannerOptions(requested))
        check(options.formats.contentEquals(requested))
        check(ScannerWire.formatName(Barcode.FORMAT_UPC_A) == "upca")
        check(ScannerWire.formatName(Barcode.FORMAT_DATA_MATRIX) == "data_matrix")
        check(ScannerWire.barcodeFormats("[]") == null)
        check(ScannerWire.barcodeFormats("[\"qr\",\"unknown\"]") == null)
        check(ScannerWire.barcodeFormats("not json") == null)
        check(ScannerWire.barcodeFormats("[\"" + "q".repeat(16 * 1024) + "\"]") == null)
    }

    private fun testOversize() {
        check(ScannerWire.encodeResult("a".repeat(16 * 1024), "q".repeat(64)) != null)
        check(ScannerWire.encodeResult("a".repeat(16 * 1024 + 1), "qr") == null)
        check(ScannerWire.encodeResult("ok", "q".repeat(65)) == null)
        check(ScannerWire.encodeResult("😀".repeat(4096), "qr") != null)
        check(ScannerWire.encodeResult("😀".repeat(4097), "qr") == null)
    }

    fun main(args: Array<String>) {
        when (args.single()) {
            "quote" -> assertRoundTrip("say \"scan\"", "q\"r")
            "backslash" -> assertRoundTrip("C:\\scanner\\path", "q\\r")
            "control" -> assertRoundTrip("line one\nline two\u0000\u0001\t")
            "unicode" -> assertRoundTrip("snow=雪 emoji=😀 music=𝄞", "二维码")
            "oversize" -> testOversize()
            "formats" -> testFormats()
            else -> error("unknown scenario")
        }
        println("ok")
    }
    """
  end

  defp assert_harness!(context, scenario) do
    {output, status} =
      System.cmd(@java, ["-cp", context.classpath, "io.mob.scanner.WireHarnessKt", scenario],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output == "ok\n"
  end
end
