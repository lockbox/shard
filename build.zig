const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "struct.foo",
        // In this case the main source file is merely a path, however, in more
        // complicated build scripts, this could be a generated file.
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    // clap for the main exe
    const clap_dep = b.dependency("clap", .{ .target = target, .optimize = optimize }).module("clap");
    exe.root_module.addImport("clap", clap_dep);

    // add + link all the core dependencies
    try add_deps(b, exe, target, optimize);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Creates a step for unit testing. This only builds the test executable
    // but does not run it.
    const unit_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/shard.zig" },
        .target = target,
        .optimize = optimize,
    });

    // add deps to test binary
    try add_deps(b, unit_tests, target, optimize);
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // build docs off of main executable
    const generate_docs = b.addInstallDirectory(.{ .source_dir = exe.getEmittedDocs(), .install_dir = .prefix, .install_subdir = "docs" });
    const docs_step = b.step("docs", "Build docs to ./zig-out/docs/");
    docs_step.dependOn(&generate_docs.step);
}

/// Add all the dependencies via the compile step
fn add_deps(b: *std.Build, build_step: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) !void {
    // C deps
    build_step.linkLibC();
    const libsla = b.addStaticLibrary(.{
        .name = "sla",
        .target = target,
        .optimize = optimize,
    });

    try build_sleigh(libsla, b);
    build_step.linkLibrary(libsla);

    // at some point we'll use actual binutils-bfd master
    //build_step.addIncludePath("./deps/binutils-gdb/bfd");
    //build_step.addIncludePath("./deps/binutils-gdb");
    //build_step.addIncludePath("./deps/binutils-gdb/include");

    // link against z3
    // little out of my comfort zone atm to replace the z3 build chain with zig
    //build_step.addObjectFile(.{ .path = "./deps/libz3.so" });
}

/// Builds the packaged SLEIGH library
fn build_sleigh(sleigh_lib: *std.Build.Step.Compile, b: *std.Build) !void {
    const flags = [_][]const u8{
        "-march=native",
        "-O3",
        "-Werror",
        "-Wno-sign-compare",
        "-Werror=return-type",
        "-fno-sanitize=undefined", // not going to hunt down all the UBSAN issues for now
        "-D__TERMINAL__",
        "-std=c++11",
        "-fPIC",
    };

    var sources = std.ArrayList([]const u8).init(b.allocator);
    {
        var dir = try std.fs.cwd().openDir("deps/sleigh", .{ .iterate = true, .access_sub_paths = true });
        var walker = try dir.walk(b.allocator);
        defer walker.deinit();

        const valid_exts = [_][]const u8{".cc"};
        while (try walker.next()) |entry| {
            const file_ext = std.fs.path.extension(entry.basename);
            const include_file = for (valid_exts) |e| {
                if (std.mem.eql(u8, file_ext, e)) break true;
            } else false;

            if (include_file) {
                const file_path = try std.fmt.allocPrint(b.allocator, "deps/sleigh/{s}", .{b.dupe(entry.path)});
                try sources.append(file_path);
            }
        }
    }

    // add gluon bindings -- not used atm but this doesn't behave how i think it
    // does. Not sure this command is actually building gluon
    //const built_gluon = b.addSystemCommand(&[_][]const u8{ "pushd deps/gluon/", "cargo build -p gluon_c-api --release" });
    //built_gluon.has_side_effects = true;
    //exe.addLibraryPath(.{.path="./deps/gluon/target/release/"});

    // add source files
    sleigh_lib.addCSourceFiles(.{ .files = sources.items, .flags = &flags });

    // link bfd
    sleigh_lib.linkSystemLibrary("bfd");

    // link zstd
    sleigh_lib.linkSystemLibrary("z");

    // link stdc++
    sleigh_lib.linkLibCpp();
}
