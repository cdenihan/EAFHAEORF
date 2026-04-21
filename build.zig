const std = @import("std");
const flate = std.compress.flate;
const tar = std.tar;
const Sha256 = std.crypto.hash.sha2.Sha256;

const ar_magic = "!<arch>\n";
const ar_header_len = 60;

const ArEntry = struct {
    size: u64,
};

const Stamp = struct {
    size: u64,
    mtime: i128,
};

const CacheMissReason = enum {
    output_missing,
    required_files_missing,
    hash_unavailable,
    hash_mismatch,
};

const ReuseStatus = union(enum) {
    metadata_hit,
    hash_hit,
    miss: CacheMissReason,
};

pub fn build(b: *std.Build) void {
    // ── Target & optimisation ────────────────────────────────────────
    // Default: aarch64-linux-gnu (KIPR Wombat).  Override with -Dtarget=…
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .cpu_arch = .aarch64,
            .os_tag = .linux,
            .abi = .gnu,
        },
    });
    const requested_optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size");
    const optimize = requested_optimize orelse .ReleaseFast;
    const kipr_sdk_path = b.option([]const u8, "kipr_sdk_path", "Path to a pre-extracted KIPR SDK root (supports include/lib or usr/include/usr/lib); skips SDK extraction");
    const sdk_cache_path = b.option([]const u8, "sdk_cache_path", "Path for extracted KIPR SDK cache when -Dkipr_sdk_path is not set") orelse ".zig-cache/wombat-sdk/kipr_sdk";
    std.log.info("Build summary:", .{});
    std.log.info("  Target: {s}-{s}-{s}", .{
        @tagName(target.result.cpu.arch),
        @tagName(target.result.os.tag),
        @tagName(target.result.abi),
    });
    std.log.info("  Optimize: {s}", .{@tagName(optimize)});

    // ── Extract KIPR SDK (cross-platform, pure Zig) ──────────────────
    // Uses an in-process custom step that unpacks headers and libkipr.so
    // from wombat-os/kipr.deb without external shell tools.
    var kipr_include: std.Build.LazyPath = undefined;
    var kipr_lib: std.Build.LazyPath = undefined;
    var extract_step: ?*std.Build.Step = null;

    if (kipr_sdk_path) |sdk_path| {
        const io = b.graph.io;
        const include_usr = b.pathJoin(&.{ sdk_path, "usr", "include" });
        const lib_usr = b.pathJoin(&.{ sdk_path, "usr", "lib" });
        const include_root = b.pathJoin(&.{ sdk_path, "include" });
        const lib_root = b.pathJoin(&.{ sdk_path, "lib" });
        const has_usr_layout = blk: {
            std.Io.Dir.cwd().access(io, include_usr, .{}) catch break :blk false;
            std.Io.Dir.cwd().access(io, lib_usr, .{}) catch break :blk false;
            break :blk true;
        };

        kipr_include = .{ .cwd_relative = if (has_usr_layout) include_usr else include_root };
        kipr_lib = .{ .cwd_relative = if (has_usr_layout) lib_usr else lib_root };
        std.log.info("  SDK: external path ({s})", .{sdk_path});
    } else {
        const wombat_dep = b.dependency("wombat_os", .{});
        const run_extract = ExtractKiprSdkStep.create(
            b,
            wombat_dep.path("updateFiles/pkgs/kipr.deb"),
            sdk_cache_path,
        );
        extract_step = &run_extract.step;

        kipr_include = .{ .cwd_relative = b.pathJoin(&.{ sdk_cache_path, "include" }) };
        kipr_lib = .{ .cwd_relative = b.pathJoin(&.{ sdk_cache_path, "lib" }) };
    }

    // ── Detect language mode and source files ────────────────────────
    // Single scan for entrypoint + C/C++ files to reduce build-script work.
    const sources = collectSources(b, "src");
    const has_zig_main = sources.has_zig_main;
    const c_files = sources.c_files;
    const cpp_files = sources.cpp_files;
    const wombat_imports: []const std.Build.Module.Import = if (has_zig_main) blk: {
        const translate_c = b.addTranslateC(.{
            .root_source_file = b.path("src/wombat.h"),
            .target = target,
            .optimize = optimize,
        });
        translate_c.addIncludePath(kipr_include);
        if (extract_step) |step| translate_c.step.dependOn(step);
        break :blk &.{
            .{
                .name = "wombat_c",
                .module = translate_c.createModule(),
            },
        };
    } else &.{};
    if (has_zig_main and c_files.len > 0 and cpp_files.len > 0) {
        std.log.info("  Sources: Zig=1, C={d}, C++={d}", .{ c_files.len, cpp_files.len });
    } else if (has_zig_main and c_files.len > 0) {
        std.log.info("  Sources: Zig=1, C={d}", .{c_files.len});
    } else if (has_zig_main and cpp_files.len > 0) {
        std.log.info("  Sources: Zig=1, C++={d}", .{cpp_files.len});
    } else if (c_files.len > 0 and cpp_files.len > 0) {
        std.log.info("  Sources: C={d}, C++={d}", .{ c_files.len, cpp_files.len });
    } else if (has_zig_main) {
        std.log.info("  Sources: Zig=1", .{});
    } else if (c_files.len > 0) {
        std.log.info("  Sources: C={d}", .{c_files.len});
    } else if (cpp_files.len > 0) {
        std.log.info("  Sources: C++={d}", .{cpp_files.len});
    }

    // ── User executable ──────────────────────────────────────────────
    const has_cpp_sources = cpp_files.len > 0;
    const library_dep_names = collectLibraryDependencyNames(b);
    const library_dep_count = library_dep_names.len;
    const needs_libcpp = has_cpp_sources or library_dep_count > 0;
    std.log.info("  Libraries: wombat_cc_lib_*={d}, link libc++={s}", .{
        library_dep_count,
        if (needs_libcpp) "yes" else "no",
    });

    const exe = b.addExecutable(.{
        .name = "botball_user_program",
        .root_module = b.createModule(.{
            .root_source_file = if (has_zig_main) b.path("src/main.zig") else null,
            .imports = wombat_imports,
            .target = target,
            .optimize = optimize,
            // libc is always needed (libkipr.so depends on it).
            // libc++ is only linked when C++ source files are present,
            // keeping pure-Zig builds as static as possible.
            .link_libc = true,
            .link_libcpp = if (needs_libcpp) true else null,
        }),
    });
    if (extract_step) |step| exe.step.dependOn(step);

    // KIPR SDK paths (extracted at build time)
    exe.root_module.addIncludePath(kipr_include);
    exe.root_module.addLibraryPath(kipr_lib);
    exe.root_module.addRPath(.{ .cwd_relative = "/usr/lib" });
    exe.root_module.linkSystemLibrary("kipr", .{});
    linkLibraryDependencies(b, exe, target, optimize, library_dep_names, kipr_include, extract_step);

    const c_compile_flags: []const []const u8 = &.{ "-std=c11", "-Wall", "-Wextra" };
    const cpp_compile_flags: []const []const u8 = &.{ "-std=c++26", "-Wall", "-Wextra" };

    // Compile any C source files in src/
    if (c_files.len > 0) {
        exe.root_module.addCSourceFiles(.{
            .root = b.path("src"),
            .files = c_files,
            .flags = c_compile_flags,
        });
    }

    // Link C++ source files (already collected above)
    if (has_cpp_sources) {
        exe.root_module.addCSourceFiles(.{
            .root = b.path("src"),
            .files = cpp_files,
            .flags = cpp_compile_flags,
        });
    }

    const check_step = b.step("check", "Compile botball_user_program without installation");
    check_step.dependOn(&exe.step);

    b.installArtifact(exe);
    b.default_step = b.getInstallStep();
    std.log.info("  Output: zig-out/bin/botball_user_program", .{});

    // ── Run step ─────────────────────────────────────────────────────
    // Only define a `run` step when the build target matches the host.
    const tgt = target.result;
    const host = b.graph.host.result;

    if (tgt.cpu.arch == host.cpu.arch and
        tgt.os.tag == host.os.tag and
        tgt.abi == host.abi)
    {
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(&exe.step);
        if (b.args) |args| run_cmd.addArgs(args);
        const run_step = b.step("run", "Run the executable");
        run_step.dependOn(&run_cmd.step);
    }

    // ── Validate source set ───────────────────────────────────────────
    if (!has_zig_main and c_files.len == 0 and cpp_files.len == 0) {
        std.debug.print(
            \\error: no executable entry point found in src/.
            \\       Add at least one of:
            \\         src/main.zig                         (Zig entry point)
            \\         src/*.c / *.cpp / *.cc / *.cxx      (C/C++ sources)
            \\
        , .{});
        std.process.exit(1);
    }

    const clean_step = b.step("clean", "Remove build artifacts and cached SDK");
    clean_step.makeFn = cleanArtifacts;
}

// ── Helpers ──────────────────────────────────────────────────────────

const ExtractKiprSdkStep = struct {
    step: std.Build.Step,
    deb_path: std.Build.LazyPath,
    out_path: []const u8,

    fn create(b: *std.Build, deb_path: std.Build.LazyPath, out_path: []const u8) *ExtractKiprSdkStep {
        const extract = b.allocator.create(ExtractKiprSdkStep) catch @panic("OOM");
        extract.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "extract kipr sdk",
                .owner = b,
                .makeFn = make,
            }),
            .deb_path = deb_path.dupe(b),
            .out_path = b.allocator.dupe(u8, out_path) catch @panic("OOM"),
        };
        extract.deb_path.addStepDependencies(&extract.step);
        return extract;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;
        const extract: *ExtractKiprSdkStep = @fieldParentPtr("step", step);
        const b = step.owner;
        const io = b.graph.io;
        const deb_path = extract.deb_path.getPath2(b, step);
        const out_path = extract.out_path;

        const deb_stat = try std.Io.Dir.cwd().statFile(io, deb_path, .{});
        const expected_stamp = Stamp{
            .size = deb_stat.size,
            .mtime = @as(i128, deb_stat.mtime.nanoseconds),
        };

        switch (try reuseIfCurrent(io, deb_path, out_path, expected_stamp)) {
            .metadata_hit => {
                return;
            },
            .hash_hit => {
                var out_dir = try std.Io.Dir.cwd().openDir(io, out_path, .{});
                defer out_dir.close(io);
                try writeStamp(io, out_dir, expected_stamp);
                std.log.info("extract_kipr: reusing cached SDK (content hash match)", .{});
                return;
            },
            .miss => |reason| {
                std.log.info("extract_kipr: cache miss: {s}", .{missReasonText(reason)});
                std.log.info("extract_kipr: extracting SDK from package...", .{});
            },
        }

        const extraction_start = std.Io.Timestamp.now(io, .awake);
        const deb_hash = try hashFileSha256(io, deb_path);

        std.Io.Dir.cwd().deleteTree(io, out_path) catch |err| {
            std.log.warn("extract_kipr: could not remove stale output '{s}': {}", .{ out_path, err });
        };

        var deb_file = try std.Io.Dir.cwd().openFile(io, deb_path, .{});
        defer deb_file.close(io);

        var file_buf: [8192]u8 = undefined;
        var file_reader = deb_file.reader(io, &file_buf);

        const entry = try findDataTar(&file_reader.interface);

        var limit_buf: [4096]u8 = undefined;
        var limited = file_reader.interface.limited(.limited64(entry.size), &limit_buf);

        var decompress_buf: [flate.max_window_len]u8 = undefined;
        var decompressor = flate.Decompress.init(&limited.interface, .gzip, &decompress_buf);

        var out_dir = try std.Io.Dir.cwd().createDirPathOpen(io, out_path, .{});
        defer out_dir.close(io);

        try tar.extract(io, out_dir, &decompressor.reader, .{
            .strip_components = 1,
        });

        if (decompressor.err) |err| return err;
        try writeStamp(io, out_dir, expected_stamp);
        try writeHash(io, out_dir, deb_hash);
        const elapsed_ms = extraction_start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
        std.log.info("extract_kipr: extraction complete in {d} ms", .{elapsed_ms});
    }
};

fn fileExists(io: std.Io, dir: std.Io.Dir, path: []const u8) bool {
    dir.access(io, path, .{}) catch return false;
    return true;
}

fn loadStamp(io: std.Io, dir: std.Io.Dir) !?Stamp {
    var buf: [128]u8 = undefined;
    const data = dir.readFile(io, ".kipr-stamp", &buf) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const trimmed = std.mem.trim(u8, data, " \t\r\n");

    var it = std.mem.splitScalar(u8, trimmed, ' ');
    const size_str = it.next() orelse return null;
    const mtime_str = it.next() orelse return null;

    const size = std.fmt.parseInt(u64, size_str, 10) catch return null;
    const mtime = std.fmt.parseInt(i128, mtime_str, 10) catch return null;

    return Stamp{ .size = size, .mtime = mtime };
}

fn writeStamp(io: std.Io, dir: std.Io.Dir, stamp: Stamp) !void {
    var stamp_buf: [96]u8 = undefined;
    const line = try std.fmt.bufPrint(&stamp_buf, "{d} {d}\n", .{ stamp.size, stamp.mtime });
    try dir.writeFile(io, .{ .sub_path = ".kipr-stamp", .data = line });
}

fn loadHash(io: std.Io, dir: std.Io.Dir) !?[Sha256.digest_length]u8 {
    var buf: [Sha256.digest_length * 2 + 8]u8 = undefined;
    const data = dir.readFile(io, ".kipr-stamp-sha256", &buf) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    if (trimmed.len != Sha256.digest_length * 2) return null;

    var hash: [Sha256.digest_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&hash, trimmed) catch return null;
    return hash;
}

fn writeHash(io: std.Io, dir: std.Io.Dir, hash: [Sha256.digest_length]u8) !void {
    const encoded = std.fmt.bytesToHex(hash, .lower);
    var encoded_with_newline: [Sha256.digest_length * 2 + 1]u8 = undefined;
    @memcpy(encoded_with_newline[0..encoded.len], &encoded);
    encoded_with_newline[encoded.len] = '\n';
    try dir.writeFile(io, .{
        .sub_path = ".kipr-stamp-sha256",
        .data = encoded_with_newline[0 .. encoded.len + 1],
    });
}

fn hashFileSha256(io: std.Io, path: []const u8) ![Sha256.digest_length]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var hasher = Sha256.init(.{});
    var reader_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &reader_buf);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = file_reader.interface.readSliceShort(&buf) catch |err| switch (err) {
            error.ReadFailed => return file_reader.err.?,
            else => |e| return e,
        };
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }

    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn missReasonText(reason: CacheMissReason) []const u8 {
    return switch (reason) {
        .output_missing => "no extracted SDK output directory exists yet",
        .required_files_missing => "required SDK files are missing in output directory",
        .hash_unavailable => "metadata changed and no cached SHA-256 stamp is available",
        .hash_mismatch => "metadata changed and SDK package content hash changed",
    };
}

fn reuseIfCurrent(io: std.Io, deb_path: []const u8, out_path: []const u8, expected: Stamp) !ReuseStatus {
    var dir = std.Io.Dir.cwd().openDir(io, out_path, .{}) catch return .{ .miss = .output_missing };
    defer dir.close(io);

    const has_header = fileExists(io, dir, "include" ++ std.fs.path.sep_str ++ "kipr" ++ std.fs.path.sep_str ++ "wombat.h") or
        fileExists(io, dir, "usr" ++ std.fs.path.sep_str ++ "include" ++ std.fs.path.sep_str ++ "kipr" ++ std.fs.path.sep_str ++ "wombat.h");
    const has_library = fileExists(io, dir, "lib" ++ std.fs.path.sep_str ++ "libkipr.so") or
        fileExists(io, dir, "usr" ++ std.fs.path.sep_str ++ "lib" ++ std.fs.path.sep_str ++ "libkipr.so");
    if (!has_header or !has_library) return .{ .miss = .required_files_missing };

    if (try loadStamp(io, dir)) |stamp| {
        if (stamp.size == expected.size and stamp.mtime == expected.mtime) return .metadata_hit;
    }

    const cached_hash = try loadHash(io, dir) orelse return .{ .miss = .hash_unavailable };
    const current_hash = try hashFileSha256(io, deb_path);
    if (std.mem.eql(u8, cached_hash[0..], current_hash[0..])) return .hash_hit;

    return .{ .miss = .hash_mismatch };
}

fn findDataTar(reader: *std.Io.Reader) !ArEntry {
    var magic_buf: [ar_magic.len]u8 = undefined;
    try reader.readSliceAll(&magic_buf);
    if (!std.mem.eql(u8, &magic_buf, ar_magic))
        return error.BadArMagic;

    while (true) {
        var hdr_buf: [ar_header_len]u8 = undefined;
        const n = try reader.readSliceShort(&hdr_buf);
        if (n < ar_header_len) return error.EndOfArchive;

        const raw_name = std.mem.trim(u8, hdr_buf[0..16], " /");
        const raw_size = std.mem.trim(u8, hdr_buf[48..58], " ");
        const size = try std.fmt.parseInt(u64, raw_size, 10);

        if (std.mem.startsWith(u8, raw_name, "data.tar")) {
            return .{ .size = size };
        }

        const skip = size + (size % 2);
        _ = try reader.discard(.limited64(skip));
    }
}

const SourceSet = struct {
    has_zig_main: bool,
    c_files: []const []const u8,
    cpp_files: []const []const u8,
};

/// Scan `dir_path` once for `main.zig`, C, and C++ source files.
fn collectSources(b: *std.Build, dir_path: []const u8) SourceSet {
    const io = b.graph.io;
    var c_files: std.ArrayList([]const u8) = .empty;
    var cpp_files: std.ArrayList([]const u8) = .empty;
    var has_zig_main = false;

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch
        return .{
            .has_zig_main = false,
            .c_files = &.{},
            .cpp_files = &.{},
        };
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.name, "main.zig")) has_zig_main = true;

        const ext = std.fs.path.extension(entry.name);
        if (std.mem.eql(u8, ext, ".c")) {
            c_files.append(
                b.allocator,
                b.allocator.dupe(u8, entry.name) catch @panic("OOM"),
            ) catch @panic("OOM");
            continue;
        }

        const is_cpp = std.mem.eql(u8, ext, ".cpp") or
            std.mem.eql(u8, ext, ".cc") or
            std.mem.eql(u8, ext, ".cxx");
        if (!is_cpp) continue;

        cpp_files.append(
            b.allocator,
            b.allocator.dupe(u8, entry.name) catch @panic("OOM"),
        ) catch @panic("OOM");
    }

    std.sort.heap([]const u8, c_files.items, {}, lessThanStringSlices);
    std.sort.heap([]const u8, cpp_files.items, {}, lessThanStringSlices);

    return .{
        .has_zig_main = has_zig_main,
        .c_files = c_files.toOwnedSlice(b.allocator) catch &.{},
        .cpp_files = cpp_files.toOwnedSlice(b.allocator) catch &.{},
    };
}

const lib_dep_prefix = "wombat_cc_lib_";

fn lessThanStringSlices(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn optimizeIntent(mode: std.builtin.OptimizeMode) []const u8 {
    return switch (mode) {
        .Debug => "fast iteration",
        .ReleaseSafe => "balanced safety/performance",
        .ReleaseFast => "maximum runtime performance",
        .ReleaseSmall => "minimum binary size",
    };
}

fn collectLibraryDependencyNames(b: *std.Build) []const []const u8 {
    var dep_names: std.ArrayList([]const u8) = .empty;
    for (b.available_deps) |dep| {
        const dep_name = dep[0];
        if (!std.mem.startsWith(u8, dep_name, lib_dep_prefix)) continue;

        dep_names.append(b.allocator, dep_name) catch @panic("OOM");
    }

    std.sort.heap([]const u8, dep_names.items, {}, lessThanStringSlices);
    return dep_names.toOwnedSlice(b.allocator) catch &.{};
}

fn linkLibraryDependencies(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    library_dep_names: []const []const u8,
    kipr_include: std.Build.LazyPath,
    extract_step: ?*std.Build.Step,
) void {
    for (library_dep_names) |dep_name| {
        const lib_dep = b.lazyDependency(dep_name, .{
            .target = target,
            .optimize = optimize,
            .kipr_include = kipr_include,
        }) orelse continue;

        const lib_artifact = lib_dep.artifact("lib");
        if (extract_step) |step| lib_artifact.step.dependOn(step);

        exe.root_module.addIncludePath(lib_dep.namedLazyPath("include"));
        exe.root_module.linkLibrary(lib_artifact);
    }
}

fn cleanArtifacts(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
    _ = options;
    const b = step.owner;
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    const paths = [_][]const u8{
        "zig-out",
        ".zig-cache",
        "zig-cache",
        ".wombat-sdk-cache",
    };

    for (paths) |path| {
        cwd.deleteTree(io, path) catch {
            std.log.info("Clean: {s} (not present)", .{path});
            continue;
        };
        std.log.info("Clean: removed {s}", .{path});
    }

    std.log.info("Clean complete.", .{});
}
