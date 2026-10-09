//! mob_scanner_nif — Android QR/barcode scanner tier-1 ZIG plugin NIF.
//!
//! Extracted from mob-core's `mob_nif.zig`: nif_scanner_scan
//! (mob_nif.zig:2671-2683) plus the scan paths of mob_deliver_file_result
//! (mob_nif.zig:2267-2308). The Kotlin side is the plugin-owned bridge class
//! `io.mob.scanner.MobScannerBridge`, which launches the plugin-owned
//! full-screen `io.mob.scanner.MobScannerActivity` (CameraX + ML Kit
//! BarcodeScanning) and feeds its Intent result back. Scan results arrive
//! back via the exported deliver thunks.
//!
//! Delivered message shapes:
//!   * cancelled -> {:scan, :cancelled}
//!     (core: Kotlin nativeDeliverAtom2(pid, "scan", "cancelled"),
//!     MobBridge.kt.eex:1364 + 1370, and the cancelled branch of
//!     mob_deliver_file_result, mob_nif.zig:2283-2285)
//!   * not_available     -> {:scan, :not_available}      (MOB-293: the
//!     scanner Activity could not be launched; iOS sends the same atom when
//!     no camera input opens)
//!   * permission_denied -> {:scan, :permission_denied}  (MOB-292: :camera
//!     refused or not grantable)
//!   * result    -> {:mob_file_result, "scan", "result", json_binary}
//!     (core: Kotlin nativeDeliverFileResult(pid, "scan", "result", json),
//!     MobBridge.kt.eex:1374, into mob_deliver_file_result's non-cancelled
//!     branch, mob_nif.zig:2286-2306 — event/sub/json all as BINARIES,
//!     tagged with the :mob_file_result atom). Core's Mob.Screen handle_info
//!     (lib/mob/screen.ex:343-391, scan branch :382-384) decodes the JSON
//!     and re-dispatches the user-facing
//!     {:scan, :result, %{type: atom, value: binary}} tuple; that decoder
//!     stays in core (camera/photos/files/audio use it too).
//!
//! Build path: compiled via `addZigObject` from `-Dplugin_zig_nifs`, reaching
//! mob-core ERTS / JNI bindings through `@import("erts")` / `@import("jni")`.
//! `get_jenv` + `g_jvm` are mob-core exports linked into the same `.so`.
const std = @import("std");
const erts = @import("erts");
const jni = @import("jni");

// mob-core exports (linked into the same .so). NOT duplicated.
extern fn get_jenv(attached: *c_int) ?*jni.JNIEnv;
extern var g_jvm: ?*jni.JavaVM;

// ── Plugin-owned bridge-class method-id cache ────────────────────────────
const ScannerMethods = struct {
    scanner_scan: jni.JMethodID = null,
    scanner_available: jni.JMethodID = null,
};

var g_scanner: ScannerMethods = .{};
var g_scanner_cls: jni.JClass = null;

// ── nativeRegister thunk — cache the bridge jclass + method id ────────────
export fn Java_io_mob_scanner_MobScannerBridge_nativeRegister(jenv: *jni.JNIEnv, cls: jni.JClass) callconv(.c) void {
    g_scanner_cls = jni.newGlobalRef(jenv, cls);
    if (g_scanner_cls == null) return;
    // A failed lookup leaves NoSuchMethodError pending, which would break the
    // next JNI call and throw out of register(); the null method id is
    // reported by scanner_available/0 instead (MOB-418).
    g_scanner.scanner_scan = jni.getStaticMethodID(jenv, cls, "scanner_scan", "(JLjava/lang/String;)V");
    jni.exceptionClear(jenv);
    g_scanner.scanner_available = jni.getStaticMethodID(jenv, cls, "scanner_available", "()I");
    jni.exceptionClear(jenv);
}

// ── Thread-attach + pid round-trip helpers (mirror mob-core / camera) ─────
inline fn detachIfAttached(attached: c_int) void {
    if (attached != 0) {
        if (g_jvm) |jvm| jni.detachCurrentThread(jvm);
    }
}

inline fn pidToJlong(pid: erts.ErlNifPid) jni.JLong {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) {
        return @bitCast(pid.pid);
    }
    return @intCast(pid.pid);
}

inline fn pidFromLong(jpid: jni.JLong) erts.ErlNifPid {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) {
        return .{ .pid = @bitCast(jpid) };
    }
    const low: u32 = @truncate(@as(u64, @bitCast(jpid)));
    return .{ .pid = low };
}

/// Call `MobScannerBridge.<method>(pid_long, arg)` — async; results land
/// later via the deliver thunks. Returns :ok unconditionally.
fn callBridgePidStr(env: ?*erts.ErlNifEnv, method: jni.JMethodID, pid: erts.ErlNifPid, arg: ?[*:0]const u8) erts.ERL_NIF_TERM {
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jarg: jni.JString = if (arg) |a| jni.newStringUTF(jenv, a) else null;
    jenv.*.CallStaticVoidMethod.?(jenv, g_scanner_cls, method, pidToJlong(pid), jarg);
    if (jarg != null) jni.deleteLocalRef(jenv, jarg);
    detachIfAttached(attached);
    return erts.ok(env);
}

// ── Inbound delivery thunks ───────────────────────────────────────────────

fn sendScanStatus(pid_long: jni.JLong, comptime status: [:0]const u8) void {
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const msg = erts.makeTuple(env, .{ erts.atom(env, "scan"), erts.atom(env, status) });
    _ = erts.enif_send(null, &pid, env, msg);
}

// {:scan, :cancelled} — parity with core's cancelled delivery
// (nativeDeliverAtom2(pid, "scan", "cancelled"), MobBridge.kt.eex:1364+1370,
// and the cancelled branch of mob_deliver_file_result, mob_nif.zig:2283-2285).
export fn Java_io_mob_scanner_MobScannerBridge_nativeDeliverScanCancelled(
    jenv: *jni.JNIEnv,
    cls: jni.JClass,
    pid_long: jni.JLong,
) callconv(.c) void {
    _ = jenv;
    _ = cls;
    sendScanStatus(pid_long, "cancelled");
}

// {:scan, :not_available} — the scanner Activity could not be launched.
export fn Java_io_mob_scanner_MobScannerBridge_nativeDeliverScanNotAvailable(
    jenv: *jni.JNIEnv,
    cls: jni.JClass,
    pid_long: jni.JLong,
) callconv(.c) void {
    _ = jenv;
    _ = cls;
    sendScanStatus(pid_long, "not_available");
}

// {:scan, :permission_denied} — the :camera runtime permission was refused.
export fn Java_io_mob_scanner_MobScannerBridge_nativeDeliverScanPermissionDenied(
    jenv: *jni.JNIEnv,
    cls: jni.JClass,
    pid_long: jni.JLong,
) callconv(.c) void {
    _ = jenv;
    _ = cls;
    sendScanStatus(pid_long, "permission_denied");
}

// {:mob_file_result, "scan", "result", json_binary} — EXACT replica of
// core's mob_deliver_file_result("scan", "result", json) non-cancelled
// branch (mob_nif.zig:2286-2306): event + sub + json all delivered as
// binaries under the :mob_file_result tag. Core's Mob.Screen
// (lib/mob/screen.ex:382-384) decodes this into
// {:scan, :result, %{type: atom, value: binary}}.
export fn Java_io_mob_scanner_MobScannerBridge_nativeDeliverScanResult(
    jenv: *jni.JNIEnv,
    cls: jni.JClass,
    pid_long: jni.JLong,
    json: jni.JString,
) callconv(.c) void {
    _ = cls;
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);

    const json_c = jenv.*.GetStringUTFChars.?(jenv, json, null) orelse return;
    defer jenv.*.ReleaseStringUTFChars.?(jenv, json, json_c);

    const event = "scan";
    const sub = "result";
    const jl = std.mem.len(json_c);

    var eb: erts.ErlNifBinary = undefined;
    var sb: erts.ErlNifBinary = undefined;
    var jb: erts.ErlNifBinary = undefined;
    if (erts.enif_alloc_binary(event.len, &eb) == 0) return;
    if (erts.enif_alloc_binary(sub.len, &sb) == 0) return;
    if (erts.enif_alloc_binary(jl, &jb) == 0) return;
    @memcpy(eb.data[0..event.len], event);
    @memcpy(sb.data[0..sub.len], sub);
    @memcpy(jb.data[0..jl], json_c[0..jl]);

    const msg = erts.makeTuple(env, .{
        erts.atom(env, "mob_file_result"),
        erts.enif_make_binary(env, &eb),
        erts.enif_make_binary(env, &sb),
        erts.enif_make_binary(env, &jb),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── NIFs ──────────────────────────────────────────────────────────────────

// Copy a binary/iolist arg into a null-terminated buffer. The bridge call
// (newStringUTF) copies the jstring synchronously, so a stack buffer is fine.
// (Same proven helper as mob_camera's binArgZ.)
fn binArgZ(env: ?*erts.ErlNifEnv, term: erts.ERL_NIF_TERM, buf: []u8) bool {
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_inspect_binary(env, term, &bin) == 0 and
        erts.enif_inspect_iolist_as_binary(env, term, &bin) == 0) return false;
    const n = @min(bin.size, buf.len - 1);
    @memcpy(buf[0..n], bin.data[0..n]);
    buf[n] = 0;
    return true;
}

// PARITY: core's nif_scanner_scan (mob_nif.zig:2671-2683) passes the
// formats-JSON binary through to the bridge unchanged; the Kotlin side
// ignores it (core MobBridge.kt.eex:1361-1365 — the scanner activity scans
// all ML Kit formats). Arity stays 1 to match the .erl stub.
fn nif_scanner_scan(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    var jbuf: [1024]u8 = undefined;
    if (!binArgZ(env, argv[0], &jbuf)) return erts.badarg(env);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, g_scanner.scanner_scan, pid, @ptrCast(&jbuf));
}

// scanner_available/0 — side-effect-free readiness probe (MOB-418, the
// self-test's native call). Never opens the camera or launches anything:
// MobScannerBridge.scanner_available() inspects the host Activity and its
// PackageManager and answers a small code. 0 is never a Kotlin answer: it is
// what CallStaticIntMethod returns when the method threw.
//   1 -> available                       (Activity declared, a camera exists)
//   2 -> no_camera                       (no FEATURE_CAMERA_ANY)
//   3 -> {error, no_activity}            (bootstrap never called setActivity)
//   4 -> {error, activity_not_declared}  (MobScannerActivity missing from the
//                                         host manifest: scan would end in
//                                         {:scan, :not_available})
//   5 -> {error, query_failed}           (the PackageManager query threw)
//   other -> {error, unexpected_bridge_answer}
//   {error, bridge_not_registered}       nativeRegister never ran or the
//                                         method-ID lookup failed
fn nif_scanner_available(env: ?*erts.ErlNifEnv, argc: c_int, argv: [*]const erts.ERL_NIF_TERM) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (g_scanner_cls == null or g_scanner.scanner_available == null) return scanError(env, "bridge_not_registered");
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return scanError(env, "no_jni_env");
    const code = jenv.*.CallStaticIntMethod.?(jenv, g_scanner_cls, g_scanner.scanner_available);
    jni.exceptionClear(jenv);
    detachIfAttached(attached);
    return switch (code) {
        1 => erts.atom(env, "available"),
        2 => erts.atom(env, "no_camera"),
        3 => scanError(env, "no_activity"),
        4 => scanError(env, "activity_not_declared"),
        5 => scanError(env, "query_failed"),
        else => scanError(env, "unexpected_bridge_answer"),
    };
}

fn scanError(env: ?*erts.ErlNifEnv, comptime reason: [:0]const u8) erts.ERL_NIF_TERM {
    return erts.makeTuple(env, .{ erts.atom(env, "error"), erts.atom(env, reason) });
}

// ── NIF table + init entry point ─────────────────────────────────────────
fn nifLoad(env: ?*erts.ErlNifEnv, priv: *?*anyopaque, info: erts.ERL_NIF_TERM) callconv(.c) c_int {
    _ = env;
    _ = priv;
    _ = info;
    return 0;
}

const nif_funcs = [_]erts.ErlNifFunc{
    .{ .name = "scanner_scan", .arity = 1, .fptr = nif_scanner_scan, .flags = 0 },
    .{ .name = "scanner_available", .arity = 0, .fptr = nif_scanner_available, .flags = 0 },
};

var nif_entry: erts.ErlNifEntry = .{
    .major = erts.ERL_NIF_MAJOR_VERSION,
    .minor = erts.ERL_NIF_MINOR_VERSION,
    .name = "mob_scanner_nif",
    .num_of_funcs = nif_funcs.len,
    .funcs = &nif_funcs,
    .load = nifLoad,
    .reload = null,
    .upgrade = null,
    .unload = null,
    .vm_variant = erts.ERL_NIF_VM_VARIANT,
    .options = 1,
    .sizeof_ErlNifResourceTypeInit = erts.SIZEOF_ErlNifResourceTypeInit,
    .min_erts = erts.ERL_NIF_MIN_ERTS_VERSION,
};

pub export fn mob_scanner_nif_nif_init() callconv(.c) *erts.ErlNifEntry {
    return &nif_entry;
}
