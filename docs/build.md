# Build Instructions

## Overview

Wombat CC uses **Zig** as both its build system and cross-compiler. The KIPR SDK (headers + pre-built `libkipr.so`) is **fetched automatically** from the official [KIPR Wombat OS](https://github.com/kipr/wombat-os) repository at build time using a **pure-Zig extraction tool** — no shell commands, no platform-specific tools.

This means `zig build` works identically on **Windows**, **macOS**, and **Linux**.
Build output now reports whether the cached SDK is reused or freshly extracted.

## Prerequisites

### Option A: Install Zig directly (recommended)

Download Zig 0.16.0 or later from [ziglang.org/download](https://ziglang.org/download/) and add it to your `PATH`. Works on all platforms (Windows, macOS, Linux).

### Option B: Nix + direnv (Linux / macOS only)

```sh
cd <your-project>
direnv allow   # activates the Nix shell automatically
```

## Building

### Default Build (ReleaseFast, aarch64-linux)

```sh
zig build
```

Output: `zig-out/bin/botball_user_program`

### Debug Build

```sh
zig build -Doptimize=Debug
```

### Fast Compile Check (no install)

```sh
zig build check -Doptimize=Debug -Dfast_ci=true
```

Useful for CI and quick validation loops where you only need compile/link success.

`zig build ci` is also available as a compile-only alias for CI-style usage.

### Optional Fast Local Rebuild Loop (incremental)

```sh
zig build check -Doptimize=Debug -Dfast_ci=true -fincremental
```

For active development, you can also pair incremental mode with watch mode:

```sh
zig build check -Doptimize=Debug -Dfast_ci=true -fincremental --watch --debounce 100
```

### Clean

```sh
zig build clean
```

Removes `zig-out/`, `zig-cache/`, and any extracted KIPR SDK cache created by the build.

### All Optimization Modes

| Flag                       | Description                              |
|----------------------------|------------------------------------------|
| *(none)*                   | ReleaseFast — maximum performance        |
| `-Doptimize=Debug`         | Debug — fast compile, safety checks      |
| `-Doptimize=ReleaseSafe`   | Optimized with safety checks             |
| `-Doptimize=ReleaseFast`   | Maximum performance (explicit)           |
| `-Doptimize=ReleaseSmall`  | Optimized for binary size                |

### Build Speed Options

| Flag | Default | Effect |
| ---- | ------- | ------ |
| `-Dkipr_sdk_path=<path>` | unset | Skip SDK extraction and use an already-extracted SDK at `<path>/include` + `<path>/lib` (or `<path>/usr/include` + `<path>/usr/lib`) |
| `-Dsdk_cache_path=<path>` | `.wombat-sdk-cache/kipr_sdk` | Location for extracted SDK cache when `-Dkipr_sdk_path` is not set |
| `-Dfast_ci=true` | `false` | Favors compile-check throughput (used by `zig build check`) |
| `-Daggressive_speed=true` | `false` | Reduces C/C++ diagnostics (`-w`) to maximize compile throughput |
| `-fincremental` | off | Enables Zig incremental compilation (may reduce changed-file rebuild time; benchmark per machine/project) |
| `--cache-dir <path>` | Zig default | Override local Zig cache path (use fast local storage) |
| `--global-cache-dir <path>` | Zig default | Override global Zig cache path (use persistent/shared storage) |
| `--watch --debounce <ms>` | off / N/A | Rebuild automatically on changes with configurable debounce |

Recommended fast validation loop:

```sh
zig build check -Doptimize=Debug -Dfast_ci=true
```

## How It Works

On the first build, the Zig package manager downloads the pinned wombat-os release tarball (cached after first fetch). Then:

1. **`build/extract_kipr.zig`** is compiled for the host and executed
2. It parses the `ar` archive format, decompresses gzip, and extracts the tar — all in pure Zig
3. Headers land in the build cache at `include/kipr/`; `libkipr.so` at `lib/`
4. Your source files are cross-compiled to `aarch64-linux-gnu`
5. The binary is linked against `libkipr.so` for symbol resolution

At runtime on the Wombat, `libkipr.so` is already installed at `/usr/lib/libkipr.so`.

SDK extraction reuse is validated with a two-stage cache check:

1. Fast metadata match (`size` + `mtime`)
2. SHA-256 fallback when metadata changed (handles timestamp-only changes)

This reduces redundant re-extraction while keeping cache reuse safe.

### Static vs Dynamic Linking

The build is as static as possible. The only dynamic dependencies are the ones required by the Wombat runtime:

| Library | Linking | Why |
|---------|---------|-----|
| Zig standard library | **Static** | Compiled into the binary |
| libc++ (C++ runtime) | **Static** | Only included when `.cpp` files are present; omitted in pure-Zig mode |
| `libkipr.so` | Dynamic | Pre-built shared library on the Wombat |
| `libc.so.6` / `libpthread.so.0` | Dynamic | glibc — required by `libkipr.so` on the Wombat |

In pure-Zig mode (no `.cpp` files), the binary has **zero** static C++ overhead.

## Language Support

### Zig (default)

Write your code in `src/main.zig`. KIPR bindings are generated by the build system via `translate-c`:

```zig
const wombat = @import("wombat_c");

pub fn main() void {
    wombat.motor(0, 100);
    wombat.msleep(1000);
    wombat.ao();
}
```

The bindings update automatically when the SDK version changes — no manual maintenance.

### C / C++

Delete `src/main.zig` and add `.c` / `.cpp` / `.cc` / `.cxx` files to `src/`. They are discovered and compiled automatically.

- `.c` files are compiled as C11
- `.cpp`, `.cc`, `.cxx` files are compiled as C++17

Use `#include <kipr/wombat.h>` to access the KIPR API.

### Library packages

The root build auto-links any dependency whose key (the name used under `.dependencies` in `build.zig.zon` or with `--save=...`) starts with `wombat_cc_lib_`. Each library package should expose:

- artifact: `lib`
- named lazy path: `include`

This supports both local path dependencies and fetched libraries:

```sh
zig fetch --save=wombat_cc_lib_<name> <url>
```

#### Build contract for each library package

Each `wombat_cc_lib_*` package should:

1. Build and install a static library artifact named `lib`
2. Export its public headers via `b.addNamedLazyPath("include", ...)`
3. Accept `-Dtarget`, `-Doptimize`, and `-Dkipr_include` from the parent build

Minimal `lib/<Name>/build.zig` template:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const kipr_include = b.option(std.Build.LazyPath, "kipr_include", "Path to KIPR headers") orelse
        @panic("missing required build option: -Dkipr_include");

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "lib",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });

    lib.root_module.addIncludePath(b.path("include"));
    lib.root_module.addIncludePath(kipr_include);
    lib.root_module.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &.{"MyLibrary.cpp"},
        .flags = &.{ "-std=c++17", "-Wall", "-Wextra" },
    });

    b.addNamedLazyPath("include", b.path("include"));
    b.installArtifact(lib);
}
```

#### Example: local library dependency

Add to your root `build.zig.zon`:

```zig
.dependencies = .{
    .wombat_cc_lib_drivetrain = .{ .path = "lib/Drivetrain" },
};
```

Then run:

```sh
zig build
```

#### Example: fetched library dependency

```sh
zig fetch --save=wombat_cc_lib_drivetrain https://example.com/drive-train.tar.gz
zig build
```

### Importing headers in your main program

#### C / C++

When a library exports named lazy path `include`, you can include headers with angle brackets:

```cpp
#include <Arm.hpp>
#include <Drivetrain.hpp>
```

Example:

```cpp
int main() {
    Drivetrain drivetrain(0, 1, 2, 3, 0, 1);
    drivetrain.SetPerformance(1.0, 1.0, 1.0, 1.0);
    drivetrain.DriveForwardLineTracking(5000, 1000);
    return 0;
}
```

#### Zig

Zig does not directly consume C++ classes from C++ headers. If you want to use Drivetrain/Arm from `main.zig`, expose a C ABI shim from the library and import it through a build-provided `translate-c` module.

Example C shim header (`drivetrain_c_api.h`):

```c
typedef struct DrivetrainHandle DrivetrainHandle;
DrivetrainHandle* drivetrain_create(int fl, int fr, int rl, int rr, int fl_ir, int fr_ir);
void drivetrain_destroy(DrivetrainHandle* handle);
void drivetrain_drive_forward_line_tracking(DrivetrainHandle* handle, int ticks, int speed);
```

In your build script, create a `b.addTranslateC(...)` module for this header and expose/import it as `drivetrain_c` (same pattern as `wombat_c`).

Example Zig call site:

```zig
const dt = @import("drivetrain_c");

pub fn main() void {
    const drive = dt.drivetrain_create(0, 1, 2, 3, 0, 1);
    defer dt.drivetrain_destroy(drive);
    dt.drivetrain_drive_forward_line_tracking(drive, 5000, 1000);
}
```

If you need direct class usage, prefer a C++ main program.

### Mixed (Zig + C/C++)

When `src/main.zig` exists, it becomes the entry point. Any C/C++ files in `src/` are still compiled and linked alongside the Zig code — useful for gradual migration or calling C helpers.

## Updating the KIPR SDK

```sh
zig fetch --save=wombat_os https://github.com/kipr/wombat-os/archive/refs/tags/<NEW_TAG>.tar.gz
```

This updates the URL and content hash in `build.zig.zon`.

## GitHub Actions

| Workflow | Trigger | What it does |
|----------|---------|--------------|
| CI | Push to `main`, pull requests | Builds with ReleaseFast, uploads artifact |
| Release | Push `v*` tag | Builds with ReleaseFast, creates GitHub Release |
| Sync Template | Weekly (Monday) / manual | Syncs infrastructure + checks for SDK updates, opens PRs |

### Sync Template workflow

The **Sync Template** workflow automatically keeps your project up to date so you can focus on writing code. It runs every Monday and can be triggered manually from the Actions tab.

It performs two independent checks:

#### 1. Template infrastructure sync

Syncs build scripts, CI workflows, and documentation from the **latest tagged release** of the upstream template repository.

**What gets synced:**
- `build.zig`, `build/` — build configuration and tools
- `.github/workflows/` — CI, release, and sync workflows
- `docs/` — documentation
- `.editorconfig`, `.envrc`, `.gitignore`, `flake.nix`, `flake.lock` — editor and environment configs

**What is never overwritten:**
- `src/` — your source code
- `build.zig.zon` — your project name, version, and dependency pins
- `README.md` — your project readme

When changes are detected, the workflow opens a pull request on the `auto/sync-template` branch. The `.wombat-cc-version` file tracks which template tag your project is based on (and in this template repository is automatically updated on tag releases).

#### 2. KIPR SDK dependency update

Checks whether a newer [wombat-os](https://github.com/kipr/wombat-os) release is available. If so, it runs `zig fetch --save=wombat_os` to update the URL and content hash in `build.zig.zon` and opens a pull request on the `auto/update-wombat-os` branch.

After merging, the next `zig build` will download the new SDK version automatically.

#### Setup

Enable *Allow GitHub Actions to create and approve pull requests* under **Settings → Actions → General** for the workflow to create PRs.

**Manual trigger with a specific template tag:**
From the Actions tab, select *Sync Template* → *Run workflow* and optionally provide a tag name (leave empty for the latest tag).

## Troubleshooting

### First build is slow

The first build downloads the wombat-os tarball (~50 MB). Subsequent builds use the Zig package cache.

On Zig 0.16+, fetched packages are stored in `zig-pkg/` in the project directory. In CI, cache this directory alongside `.zig-cache/` and `zig-cache/` to avoid re-fetch/recompress work on each run.

For local builds, extracted SDK files are cached in `.wombat-sdk-cache/kipr_sdk` by default to avoid repeated extraction work across build graph changes.

### Build fails with "Could not open source directory"

Ensure `src/` exists and contains at least one source file (`.zig`, `.c`, `.cpp`, `.cc`, or `.cxx`).

### Zig not found

Install Zig from [ziglang.org/download](https://ziglang.org/download/) or use `nix develop`.

### "undefined symbol" errors

The function may not exist in the current libwallaby version. Update the SDK with `zig fetch --save=wombat_os …`.

### Windows: extractor arg API errors after upgrade

If you see old API errors mentioning `initWithAllocator` or `argsWithAllocator`, clean caches and rebuild with the updated template:

```sh
zig build clean
zig build
```

### Windows: installing Zig

The recommended way to install Zig on Windows is via [WinGet](https://learn.microsoft.com/en-us/windows/package-manager/winget/):

```powershell
winget install zig.zig
```

Alternatively, download the `.zip` from [ziglang.org/download](https://ziglang.org/download/) and add the folder to your `PATH`.
