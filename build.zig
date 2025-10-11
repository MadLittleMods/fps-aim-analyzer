const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    // Other example of using zigx,
    // https://github.com/marler8997/image-viewer/blob/f189f2547890d61a1770327e105b01fc704f98c4/build.zig#L43-L44
    const zigx_dep = b.dependency("zigx", .{});
    const zigimg_dep = b.dependency("zigimg", .{});

    // Building executables
    // ============================================
    //
    // Based on the zap build: https://github.com/zigzap/zap/blob/8a2d077bd8627c429de4fef3b1899296e6201c0a/build.zig
    const all_step = b.step("all", "build all executables");
    inline for ([_]struct {
        name: []const u8,
        src: []const u8,
        build_by_default: bool,
    }{
        // zig build run-main
        .{ .name = "main", .src = "src/main.zig", .build_by_default = true },
        // zig build run-screen_play
        .{ .name = "screen_play", .src = "src/main_screen_play.zig", .build_by_default = false },
    }) |exe_cfg| {
        const exe_name = exe_cfg.name;
        const exe_src = exe_cfg.src;
        const exe_build_desc = try std.fmt.allocPrint(
            b.allocator,
            "Build {s}",
            .{exe_name},
        );
        const exe_run_stepname = try std.fmt.allocPrint(
            b.allocator,
            "run-{s}",
            .{exe_name},
        );
        const exe_run_stepdesc = try std.fmt.allocPrint(
            b.allocator,
            "Run {s}",
            .{exe_name},
        );

        const exe = b.addExecutable(.{
            .name = exe_name,
            .root_source_file = .{ .path = exe_src },
            .target = target,
            .optimize = optimize,
        });
        // Make the `zigx` module available to be imported via `@import("x")`
        exe.addModule("x", zigx_dep.module("zigx"));
        // Make the `zigimg` module available to be imported via `@import("zigimg")`
        exe.addModule("zigimg", zigimg_dep.module("zigimg"));

        // The `install_artifact` marks the intent for the executable to be installed
        // into the standard location when the user invokes the "install" step.
        const install_artifact = b.addInstallArtifact(exe, .{});
        if (exe_cfg.build_by_default) {
            // Install the artifact by default when the user runs `zig build` by itself.
            //
            // Equivalent to the second-half of `b.installArtifact(exe);` that "adds it
            // to the dependencies of the top-level install step"
            b.getInstallStep().dependOn(&install_artifact.step);
        }

        // This creates a build step. It will be visible in the `zig build --help` menu,
        // and can be selected like this: `zig build xxx`
        const build_step = b.step(exe_name, exe_build_desc);
        build_step.dependOn(&install_artifact.step);
        all_step.dependOn(&install_artifact.step);

        // This *creates* a Run step in the build graph, to be executed when another
        // step is evaluated that depends on it. The next line below will establish
        // such a dependency.
        const run_artifact = b.addRunArtifact(exe);
        // By making the run step depend on the install step, it will be run from the
        // installation directory rather than directly from within the cache directory.
        // This is not necessary, however, if the application depends on other installed
        // files, this ensures they will be present and in the expected location.
        run_artifact.step.dependOn(&install_artifact.step);
        // This allows the user to pass arguments to the application in the build
        // command itself, like this: `zig build run -- arg1 arg2 etc`
        if (b.args) |args| {
            run_artifact.addArgs(args);
        }

        // This creates a build step. It will be visible in the `zig build --help` menu,
        // and can be selected like this: `zig build run-xxx`
        // This will evaluate the `run` step rather than the default, which is "install".
        const run_step = b.step(exe_run_stepname, exe_run_stepdesc);
        run_step.dependOn(&run_artifact.step);
    }

    // Testing
    // ============================================
    {
        // This creates a build step. It will be visible in the `zig build --help` menu,
        // and can be selected like this: `zig build test`
        // This will evaluate the `test` step rather than the default, which is "install".
        const test_step = b.step("test", "Run tests");
        const test_filter = b.option([]const u8, "test-filter", "Filter for test");

        // Creates a step for unit testing. This only builds the test executable
        // but does not run it.
        const unit_tests = b.addTest(.{
            .root_source_file = .{ .path = "src/main.zig" },
            .target = target,
            .optimize = optimize,
            .filter = test_filter,
        });
        unit_tests.addModule("x", zigx_dep.module("zigx"));
        unit_tests.addModule("zigimg", zigimg_dep.module("zigimg"));

        const run_unit_tests_cmd = b.addRunArtifact(unit_tests);
        // This forces tests to always be re-run instead of returning the cached result.
        run_unit_tests_cmd.has_side_effects = true;

        test_step.dependOn(&run_unit_tests_cmd.step);
    }
}
