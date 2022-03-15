const std = @import("std");
const out = std.log.scoped(.libressl);
const builtin = @import("builtin");

fn isProgramAvailable(builder: *std.build.Builder, program_name: []const u8) !bool {
    const env_map = try std.process.getEnvMap(builder.allocator);
    const path_var = env_map.get("PATH") orelse return false;
    var path_iter = std.mem.tokenize(u8, path_var, if (builtin.os.tag == .windows) ";" else ":");
    while (path_iter.next()) |path| {
        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch continue;
        defer dir.close();

        var dir_iterator = dir.iterate();
        while (try dir_iterator.next()) |dir_item| {
            if (std.mem.eql(u8, dir_item.name, program_name)) return true;
        }
    }
    return false;
}

fn isLibreSslConfigured(library_location: []const u8) !bool {
    var libre_ssl_dir = try std.fs.cwd().openDir(library_location, .{});
    _ = libre_ssl_dir.openFile("configure", .{}) catch return false;
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

    if (!try isLibreSslConfigured(library_location)) {
        configure_step.step.dependOn(&autogen_step.step);
    }

    const ninja_available = isProgramAvailable(builder, "ninja") catch false;

    const make_step = std.build.RunStep.create(builder, "make LibreSSL");
    make_step.cwd = build_dir_path;
    make_step.setEnvironmentVariable("DESTDIR", "out");
    if (ninja_available) {
        make_step.addArgs(&[_][]const u8{ "ninja", "install" });
    } else {
        make_step.addArgs(&[_][]const u8{ "make", "install" });
    }

    const cmake_available = isProgramAvailable(builder, "cmake") catch false;

    if (cmake_available) {
        const cmake_step = std.build.RunStep.create(builder, "configure LibreSSL");
        cmake_step.cwd = build_dir_path;
        if (ninja_available) {
            cmake_step.addArgs(&[_][]const u8{ "cmake", "-GNinja", libre_ssl_absolute_dir });
        } else {
            cmake_step.addArgs(&[_][]const u8{ "cmake", libre_ssl_absolute_dir });
        }
        cmake_step.step.dependOn(&configure_step.step);
        make_step.step.dependOn(&cmake_step.step);
    }

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

const required_programs = [_][]const u8{
    "automake",
    "autoconf",
    "git",
    "libtool",
    "perl",
    "make",
};

fn addIncludeDirsFromPkgConfigForLibrary(builder: *std.build.Builder, step: *std.build.LibExeObjStep, name: []const u8) !void {
    var out_code: u8 = 0;
    const stdout = try builder.execAllowFail(&[_][]const u8{ "pkg-config", "--cflags", name }, &out_code, .Ignore);
    var c_flag_iter = std.mem.tokenize(u8, stdout, " ");
    while (c_flag_iter.next()) |c_flag| {
        if (std.mem.startsWith(u8, c_flag, "-I")) {
            var path = std.mem.trimRight(u8, c_flag[2..], "\t\r\n ");
            step.addIncludeDir(path);
        }
    }
}

pub fn useLibreSslForStep(
    builder: *std.build.Builder,
    step: *std.build.LibExeObjStep,
    libressl_location: []const u8,
    use_system_libressl: bool,
) !void {
    if (use_system_libressl) {
        addIncludeDirsFromPkgConfigForLibrary(builder, step, "libtls") catch |why| {
            out.err("Failed to get include directory for libtls: {}", .{why});
            return why;
        };
        step.linkSystemLibrary("tls");
        step.linkSystemLibrary("ssl");
        step.linkSystemLibrary("crypto");
    } else {
        inline for (required_programs) |program| {
            const available = isProgramAvailable(builder, program) catch false;
            if (!available) {
                out.err("{s} is required to build LibreSSL\n", .{program});
                return error.MissingRequiredProgramForBuild;
            }
        }
        buildLibreSsl(builder, step, libressl_location) catch |e| {
            out.err("Failed to configure libreSSL build steps: {}\n", .{e});
            return e;
        };
    }
}

pub fn build(b: *std.build.Builder) !void {
    const mode = b.standardReleaseOptions();

    var lib = b.addStaticLibrary("zig-libressl", "src/main.zig");
    lib.linkLibC();
    lib.setBuildMode(mode);
    lib.install();

    const use_system_libressl = b.option(bool, "use-system-libressl", "Link and build from the system installed copy of LibreSSL instead of building it from source") orelse false;

    var main_tests = b.addTest("src/normal_test.zig");
    main_tests.setBuildMode(mode);
    try useLibreSslForStep(b, main_tests, "libressl", use_system_libressl);

    var async_tests = b.addTest("src/async_test.zig");
    async_tests.test_evented_io = true;
    async_tests.setBuildMode(mode);
    try useLibreSslForStep(b, async_tests, "libressl", use_system_libressl);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
    test_step.dependOn(&async_tests.step);
}
