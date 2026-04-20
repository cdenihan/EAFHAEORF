//! Cross-platform KIPR SDK extractor.
//!
//! Extracts headers and the pre-built `libkipr.so` from the KIPR `.deb`
//! package shipped inside the wombat-os repository.  Parses the Debian `ar`
//! archive and gzip-compressed tar in pure Zig — no external tools required,
//! so `zig build` works identically on Linux, macOS, and Windows.
//!
//! Usage (called automatically by the build system):
//!     extract_kipr <kipr.deb> <output_dir>

const std = @import("std");
const flate = std.compress.flate;
const tar = std.tar;
const Sha256 = std.crypto.hash.sha2.Sha256;

// ── ar archive format ────────────────────────────────────────────────
// Global header:  "!<arch>\n"  (8 bytes)
// Per-member:     60-byte header, then `size` bytes of content,
//                 padded to 2-byte alignment.

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

/// Walk the ar archive and return the first member whose name starts with
/// "data.tar" (the payload inside a .deb package).
fn findDataTar(reader: *std.Io.Reader) !ArEntry {
    // Validate global header
    var magic_buf: [ar_magic.len]u8 = undefined;
    try reader.readSliceAll(&magic_buf);
    if (!std.mem.eql(u8, &magic_buf, ar_magic))
        return error.BadArMagic;

    // Walk entries
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

        // Skip to next entry (content + optional padding byte)
        const skip = size + (size % 2);
        _ = try reader.discard(.limited64(skip));
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const deb_path = if (args.len > 1) args[1] else return error.MissingDebArg;
    const out_path = if (args.len > 2) args[2] else return error.MissingOutArg;

    const deb_stat = try std.Io.Dir.cwd().statFile(io, deb_path, .{});
    const expected_stamp = Stamp{
        .size = deb_stat.size,
        .mtime = @as(i128, deb_stat.mtime.nanoseconds),
    };
    std.log.info("extract_kipr: source package = {s} ({d} bytes)", .{ deb_path, expected_stamp.size });

    switch (try reuseIfCurrent(io, deb_path, out_path, expected_stamp)) {
        .metadata_hit => {
            std.log.info("extract_kipr: reusing cached SDK (metadata match)", .{});
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

    // Open the .deb file
    var deb_file = try std.Io.Dir.cwd().openFile(io, deb_path, .{});
    defer deb_file.close(io);

    var file_buf: [8192]u8 = undefined;
    var file_reader = deb_file.reader(io, &file_buf);

    // Locate data.tar.gz inside the ar archive
    const entry = try findDataTar(&file_reader.interface);

    // Limit reading to just this member
    var limit_buf: [4096]u8 = undefined;
    var limited = file_reader.interface.limited(.limited64(entry.size), &limit_buf);

    // Decompress gzip
    var decompress_buf: [flate.max_window_len]u8 = undefined;
    var decompressor = flate.Decompress.init(&limited.interface, .gzip, &decompress_buf);

    // Create output directory
    var out_dir = try std.Io.Dir.cwd().createDirPathOpen(io, out_path, .{});
    defer out_dir.close(io);

    // Extract tar — strip_components=1 removes the leading "./"
    try tar.extract(io, out_dir, &decompressor.reader, .{
        .strip_components = 1,
    });

    if (decompressor.err) |err| return err;
    try writeStamp(io, out_dir, expected_stamp);
    try writeHash(io, out_dir, deb_hash);
    const elapsed_ms = extraction_start.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
    std.log.info("extract_kipr: extraction complete in {d} ms", .{elapsed_ms});
}
