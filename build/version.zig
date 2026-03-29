const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.version);

pub const PackageVersion = struct {
    allocator: Allocator,
    release_version: []const u8,
    nightly_version: []const u8,
    semantic_version: std.SemanticVersion,

    pub fn init(
        allocator: Allocator,
        release_version: []const u8,
        nightly_version: []const u8,
        semantic_version: std.SemanticVersion,
    ) @This() {
        return .{
            .allocator = allocator,
            .release_version = release_version,
            .nightly_version = nightly_version,
            .semantic_version = semantic_version,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.release_version);
        self.allocator.free(self.nightly_version);
    }
};

const BuildZonFile = struct {
    version: []const u8,
};

pub fn get_package_version(b: *std.Build, allocator: Allocator, ignore_version: bool) !PackageVersion {
    const manifest_source = try std.fs.cwd().readFileAllocOptions(
        allocator,
        "build.zig.zon",
        1024 * 1024 * 10,
        null,
        .of(u8),
        0,
    );
    defer allocator.free(manifest_source);

    const build_zon_file = try std.zon.parse.fromSlice(BuildZonFile, allocator, manifest_source, null, .{
        .ignore_unknown_fields = true,
    });
    defer std.zon.parse.free(allocator, build_zon_file);

    const release_version = try allocator.dupe(u8, build_zon_file.version);
    errdefer allocator.free(release_version);

    const semantic_version = try std.SemanticVersion.parse(release_version);

    const nightly_version = try get_nightly_version(
        b,
        allocator,
        release_version,
        semantic_version,
        ignore_version,
    );
    errdefer allocator.free(nightly_version);

    return .init(
        allocator,
        release_version,
        nightly_version,
        semantic_version,
    );
}

/// 0.2.0-dev.<commits since last release>+<commit hash>
///
/// e.g.
/// 0.2.0-dev.15+55937e954
///
/// Caller owns memory. Returns the release version on failure.
fn get_nightly_version(
    b: *std.Build,
    allocator: Allocator,
    release_version: []const u8,
    semantic_version: std.SemanticVersion,
    ignore_version: bool,
) ![]const u8 {
    if (!std.process.can_spawn) {
        return allocator.dupe(u8, release_version);
    }

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "git",
            "-C",
            b.build_root.path orelse ".",
            "--git-dir",
            ".git",
            "describe",
            "--tags",
            "--match",
            "v*.*.*",
            "--long",
            "--abbrev=9",
        },
    }) catch |err| {
        log.warn("Unable to run `git describe`, using release version '{s}': {}", .{ release_version, err });
        return allocator.dupe(u8, release_version);
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                log.warn("`git describe` exited with code {}, using release version '{s}'", .{ code, release_version });
                if (result.stdout.len > 0) {
                    log.warn("stdout: {s}", .{result.stdout});
                }
                if (result.stderr.len > 0) {
                    log.warn("stderr: {s}", .{result.stderr});
                }
                return allocator.dupe(u8, release_version);
            }
        },
        else => {
            log.warn("`git describe` terminated unexpectedly, using release version '{s}'", .{release_version});
            return allocator.dupe(u8, release_version);
        },
    }

    // e.g. v0.1.0-15-g55937e954
    const git_describe = std.mem.trim(u8, result.stdout, " \n\r");
    var iter = std.mem.splitScalar(u8, git_describe, '-');
    const tagged_ancestor = iter.first();
    const commit_height = iter.next() orelse {
        log.warn("Unexpected `git describe` output: {s}", .{git_describe});
        return allocator.dupe(u8, release_version);
    };
    const commit_short_hash = iter.next() orelse {
        log.warn("Unexpected `git describe` output: {s}", .{git_describe});
        return allocator.dupe(u8, release_version);
    };

    if (tagged_ancestor.len < 2 or tagged_ancestor[0] != 'v') {
        log.warn("Unexpected `git describe` output (no tags found): {s}", .{git_describe});
        return allocator.dupe(u8, release_version);
    }

    const ancestor_ver = std.SemanticVersion.parse(tagged_ancestor[1..]) catch |err| {
        log.warn("Failed to parse tagged ancestor from `git describe` output '{s}': {}", .{ git_describe, err });
        return allocator.dupe(u8, release_version);
    };

    if (!ignore_version and semantic_version.order(ancestor_ver) != .gt) {
        log.err(
            \\Spacecap version '{f}' must be greater than the latest tag '{f}'.
            \\You probably need to bump the version in build.zig.zon.
            \\Use '-Dignore-version' to suppress this error.
        ,
            .{ semantic_version, ancestor_ver },
        );
        return error.VersionMismatch;
    }

    if (commit_short_hash.len < 2 or commit_short_hash[0] != 'g') {
        log.warn("Unexpected `git describe` output: {s}", .{git_describe});
        return allocator.dupe(u8, release_version);
    }

    return std.fmt.allocPrint(allocator, "{s}-dev.{s}+{s}", .{
        release_version,
        commit_height,
        commit_short_hash[1..],
    });
}
