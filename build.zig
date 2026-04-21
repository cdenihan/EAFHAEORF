const std = @import("std");

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
    const sdk_cache_path = b.option([]const u8, "sdk_cache_path", "Path for extracted KIPR SDK cache when -Dkipr_sdk_path is not set") orelse ".wombat-sdk-cache/kipr_sdk";
    const fast_ci = b.option(bool, "fast_ci", "Favor compile-validation speed for CI checks") orelse false;
    const aggressive_speed = b.option(bool, "aggressive_speed", "Reduce C/C++ diagnostics to maximize compile throughput") orelse false;
    const fast_checks = fast_ci or aggressive_speed;
    std.log.info("Build target: {s}-{s}-{s}", .{
        @tagName(target.result.cpu.arch),
        @tagName(target.result.os.tag),
        @tagName(target.result.abi),
    });
    std.log.info("Optimization mode: {s} ({s})", .{ @tagName(optimize), optimizeIntent(optimize) });
    if (requested_optimize == null) {
        std.log.info("No -Doptimize supplied; defaulting to ReleaseFast for production-speed binaries.", .{});
    }
    if (fast_ci) {
        std.log.info("Fast CI mode enabled (-Dfast_ci=true).", .{});
    }
    if (aggressive_speed) {
        std.log.warn("Aggressive speed mode enabled: C/C++ warnings disabled (-w).", .{});
    }

    // ── Extract KIPR SDK (cross-platform, pure Zig) ──────────────────
    // Compiles a small host-native tool that unpacks the headers and
    // pre-built libkipr.so from the wombat-os kipr.deb — no `sh`, `ar`,
    // or `tar` CLI needed, so this works on Windows, macOS, and Linux.
    var kipr_include: std.Build.LazyPath = undefined;
    var kipr_lib: std.Build.LazyPath = undefined;
    var extract_step: ?*std.Build.Step.Run = null;

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
        std.log.info("SDK mode: external path ({s})", .{sdk_path});
        std.log.info("SDK include path: {s}", .{if (has_usr_layout) include_usr else include_root});
        std.log.info("SDK library path: {s}", .{if (has_usr_layout) lib_usr else lib_root});
    } else {
        std.log.info("SDK mode: extracted from wombat_os package (cached at {s}).", .{sdk_cache_path});
        const wombat_dep = b.dependency("wombat_os", .{});

        const extractor = b.addExecutable(.{
            .name = "extract_kipr",
            .root_module = b.createModule(.{
                .root_source_file = b.path("build/extract_kipr.zig"),
                .target = b.graph.host,
            }),
        });

        const run_extract = b.addRunArtifact(extractor);
        run_extract.addFileArg(wombat_dep.path("updateFiles/pkgs/kipr.deb"));
        run_extract.addArg(sdk_cache_path);
        extract_step = run_extract;

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
        if (extract_step) |step| translate_c.step.dependOn(&step.step);
        break :blk &.{
            .{
                .name = "wombat_c",
                .module = translate_c.createModule(),
            },
        };
    } else &.{};
    std.log.info("Source scan: main.zig={s}, C files={d}, C++ files={d}", .{
        if (has_zig_main) "yes" else "no",
        c_files.len,
        cpp_files.len,
    });

    // ── User executable ──────────────────────────────────────────────
    const has_cpp_sources = cpp_files.len > 0;
    const library_dep_names = collectLibraryDependencyNames(b);
    const library_dep_count = library_dep_names.len;
    const needs_libcpp = has_cpp_sources or library_dep_count > 0;
    std.log.info("Detected wombat_cc_lib_* dependencies: {d}", .{library_dep_count});
    std.log.info("libc++ linkage: {s}", .{if (needs_libcpp) "enabled" else "disabled"});

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
    if (extract_step) |step| exe.step.dependOn(&step.step);

    // KIPR SDK paths (extracted at build time)
    exe.root_module.addIncludePath(kipr_include);
    exe.root_module.addLibraryPath(kipr_lib);
    exe.root_module.addRPath(.{ .cwd_relative = "/usr/lib" });
    exe.root_module.linkSystemLibrary("kipr", .{});
    linkLibraryDependencies(b, exe, target, optimize, library_dep_names, kipr_include);

    const c_compile_flags: []const []const u8 = if (fast_checks)
        &.{ "-std=c11", "-w" }
    else
        &.{ "-std=c11", "-Wall", "-Wextra" };
    const cpp_compile_flags: []const []const u8 = if (fast_checks)
        &.{ "-std=c++26", "-w" }
    else
        &.{ "-std=c++26", "-Wall", "-Wextra" };
    std.log.info("C/C++ diagnostics mode: {s}", .{if (fast_checks) "fast (-w)" else "standard (-Wall -Wextra)"});

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
    const ci_step = b.step("ci", "Alias for compile-only CI validation");
    ci_step.dependOn(check_step);

    b.installArtifact(exe);
    b.default_step = b.getInstallStep();
    std.log.info("Build steps: default install emits zig-out/bin/botball_user_program; use 'check'/'ci' for compile-only", .{});

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
) void {
    for (library_dep_names) |dep_name| {
        const lib_dep = b.lazyDependency(dep_name, .{
            .target = target,
            .optimize = optimize,
            .kipr_include = kipr_include,
        }) orelse continue;

        exe.root_module.addIncludePath(lib_dep.namedLazyPath("include"));
        exe.root_module.linkLibrary(lib_dep.artifact("lib"));
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
