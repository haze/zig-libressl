const std = @import("std");

// TODO(haze): check if ninja exists and use that
// TODO(haze): see if we can take input arguments to an already built and installed libreSSL

fn isLibreSslConfigured(library_location: []const u8) !bool {
    var libre_ssl_dir = try std.fs.cwd().openDir(library_location, .{});
    _ = libre_ssl_dir.openFile("configure", .{ .read = false, .write = false }) catch return false;
    return true;
}

fn buildLibreSsl(builder: *std.build.Builder, input_step: *std.build.LibExeObjStep, library_location: []const u8) !void {
    var libre_ssl_dir = try std.fs.cwd().openDir(library_location, .{});
    var libre_ssl_absolute_dir_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const libre_ssl_absolute_dir = try libre_ssl_dir.realpath(".", &libre_ssl_absolute_dir_buf);

    const autogen_step = std.build.RunStep.create(builder, "autogen LibreSSL");
    autogen_step.cwd = library_location;
    autogen_step.addArg("./autogen.sh");

    const configure_step = std.build.RunStep.create(builder, "configure LibreSSL");
    configure_step.cwd = library_location;
    configure_step.addArg("./configure");

    libre_ssl_dir.makeDir("build") catch |e| switch (e) {
        std.os.MakeDirError.PathAlreadyExists => {},
        else => return e,
    };

    var build_dir_path = try std.fs.path.join(builder.allocator, &[_][]const u8{ library_location, "build" });

    var build_results_dir_path = try std.fs.path.join(builder.allocator, &[_][]const u8{ build_dir_path, "out" });

    const cmake_step = std.build.RunStep.create(builder, "configure LibreSSL");
    cmake_step.cwd = build_dir_path;
    cmake_step.addArgs(&[_][]const u8{ "cmake", "-GNinja", libre_ssl_absolute_dir });
    cmake_step.step.dependOn(&configure_step.step);

    if (!try isLibreSslConfigured(library_location)) {
        configure_step.step.dependOn(&autogen_step.step);
    }

    const make_step = std.build.RunStep.create(builder, "make LibreSSL");
    make_step.cwd = build_dir_path;
    make_step.setEnvironmentVariable("DESTDIR", "out");
    make_step.setEnvironmentVariable("CC", "zig cc");
    make_step.addArgs(&[_][]const u8{ "ninja", "install" });
    make_step.step.dependOn(&cmake_step.step);

    // check if we even need to build anything
    _ = std.fs.cwd().openDir(build_results_dir_path, .{}) catch {
        // ensure that we build if there was no dir found
        // TODO(haze): stricten to "dir not found"
        input_step.step.dependOn(&make_step.step);
    };

    const libre_ssl_include_dir_path = try std.fs.path.join(builder.allocator, &[_][]const u8{ build_results_dir_path, "usr", "local", "include" });
    input_step.addIncludeDir(libre_ssl_include_dir_path);

    const libre_ssl_lib_dir_path = try std.fs.path.join(builder.allocator, &[_][]const u8{ build_results_dir_path, "usr", "local", "lib" });
    input_step.addLibPath(libre_ssl_lib_dir_path);

    input_step.linkSystemLibraryName("tls");
    input_step.linkSystemLibraryName("ssl");
    input_step.linkSystemLibraryName("crypto");
}

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const libressl_location = "libressl";

    var lib = b.addStaticLibrary("zig-libressl", "src/main.zig");
    lib.setBuildMode(mode);
    lib.install();

    var main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);
    buildLibreSsl(b, main_tests, libressl_location) catch |e| {
        std.debug.print("Failed to configure libreSSL build steps: {}\n", .{e});
        return;
    };

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
