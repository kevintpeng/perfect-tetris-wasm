const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Expose the library root
    const root_module = libModule(b, target, optimize);
    b.modules.put(b.dupe("perfect-tetris"), root_module) catch @panic("OOM");

    // Install step
    const exe = pcExecutable(b, "pc", target, optimize);
    b.installArtifact(exe);

    runStep(b, exe);
    solveStep(b, target, optimize);
    testStep(b, target);
    benchStep(b, target);
    trainStep(b, target, optimize);
    releaseStep(b);
    wasmStep(b);
}

const Dependency = enum {
    args,
    engine,
    nterm,
    vaxis,
    zmai,

    pub fn module(dep: Dependency, b: *Build, args: anytype) *Build.Module {
        return switch (dep) {
            .nterm => module(.engine, b, args).import_table.get("nterm").?,
            else => b.dependency(@tagName(dep), args).module(@tagName(dep)),
        };
    }
};

fn importDependencies(
    module: *Build.Module,
    deps: []const Dependency,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    for (deps) |dep| {
        const dep_module = dep.module(module.owner, .{
            .target = target,
            .optimize = optimize,
        });
        module.addImport(switch (dep) {
            .args => "zig-args",
            else => @tagName(dep),
        }, dep_module);
    }
}

fn packageVersion(b: *Build) []const u8 {
    var ast = std.zig.Ast.parse(b.allocator, @embedFile("build.zig.zon"), .zon) catch
        @panic("OOM");
    defer ast.deinit(b.allocator);

    var buf: [2]std.zig.Ast.Node.Index = undefined;
    const zon = ast.fullStructInit(&buf, ast.nodes.items(.data)[0].lhs) orelse
        @panic("Failed to parse build.zig.zon");

    for (zon.ast.fields) |field| {
        const field_name = ast.tokenSlice(ast.firstToken(field) - 2);
        if (std.mem.eql(u8, field_name, "version")) {
            const version_string = ast.tokenSlice(ast.firstToken(field));
            // Remove surrounding quotes
            return version_string[1 .. version_string.len - 1];
        }
    }
    @panic("Field 'version' missing from build.zig.zon");
}

fn minifyJson(b: *Build, path: Build.LazyPath) Build.LazyPath {
    const minify_exe = b.addExecutable(.{
        .name = "minify-json",
        .root_source_file = b.path("src/build/minify-json.zig"),
        .target = b.resolveTargetQuery(
            Build.parseTargetQuery(.{ .arch_os_abi = "native" }) catch unreachable,
        ),
    });

    const minify_cmd = b.addRunArtifact(minify_exe);
    minify_cmd.expectExitCode(0);
    minify_cmd.addFileArg(path);
    return minify_cmd.captureStdOut();
}

fn hashFiles(b: *Build, files: []const Build.LazyPath) Build.LazyPath {
    const hash_exe = b.addExecutable(.{
        .name = "hash-files",
        .root_source_file = b.path("src/build/hash-files.zig"),
        .target = b.resolveTargetQuery(
            Build.parseTargetQuery(.{ .arch_os_abi = "native" }) catch unreachable,
        ),
    });

    const hash_cmd = b.addRunArtifact(hash_exe);
    hash_cmd.expectExitCode(0);
    for (files) |file| {
        hash_cmd.addFileArg(file);
    }
    return hash_cmd.captureStdOut();
}

fn libModule(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *Build.Module {
    const mod = b.createModule(.{ .root_source_file = b.path("src/root.zig") });
    importDependencies(mod, &.{ .engine, .zmai }, target, optimize);
    mod.addAnonymousImport("nn_4l_json", .{
        .root_source_file = minifyJson(b, b.path("NNs/Fast3.json")),
    });
    return mod;
}

fn pcExecutable(
    b: *Build,
    name: []const u8,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *Build.Step.Compile {
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("perfect-tetris", libModule(b, target, optimize));
    importDependencies(
        exe_mod,
        &.{ .args, .engine, .nterm, .vaxis, .zmai },
        target,
        optimize,
    );

    const options = b.addOptions();
    options.addOption([]const u8, "version", packageVersion(b));
    exe_mod.addImport("build", options.createModule());

    return b.addExecutable(.{ .name = name, .root_module = exe_mod });
}

fn runStep(b: *Build, exe: *Build.Step.Compile) void {
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const step = b.step("run", "Run the app");
    step.dependOn(&run_cmd.step);
}

fn solveStep(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/scripts/solve.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("perfect-tetris", libModule(b, target, optimize));
    importDependencies(exe_mod, &.{.engine}, target, optimize);

    const exe = b.addExecutable(.{ .name = "solve", .root_module = exe_mod });

    const install_NNs = b.addInstallDirectory(.{
        .source_dir = b.path("NNs"),
        .install_dir = .bin,
        .install_subdir = "NNs",
    });

    const run_cmd = b.addRunArtifact(exe);
    const install = b.addInstallArtifact(exe, .{});
    install.step.dependOn(&install_NNs.step);

    const step = b.step("solve", "Run the PC solver");
    step.dependOn(&run_cmd.step);
    step.dependOn(&install.step);
}

fn testStep(b: *Build, target: Build.ResolvedTarget) void {
    const lib = libModule(b, target, .Debug);
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = lib.root_source_file,
            .target = target,
            .optimize = .Debug,
        }),
    });
    lib_tests.root_module.import_table =
        lib.import_table.clone(b.allocator) catch @panic("OOM");

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const step = b.step("test", "Run library tests");
    step.dependOn(&run_lib_tests.step);
}

fn benchStep(b: *Build, target: Build.ResolvedTarget) void {
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/scripts/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    exe_mod.addImport("perfect-tetris", libModule(b, target, .ReleaseFast));
    importDependencies(exe_mod, &.{.engine}, target, .ReleaseFast);

    const exe = b.addExecutable(.{ .name = "benchmarks", .root_module = exe_mod });

    const run_cmd = b.addRunArtifact(exe);
    const install = b.addInstallArtifact(exe, .{});

    const step = b.step("bench", "Run benchmarks");
    step.dependOn(&run_cmd.step);
    step.dependOn(&install.step);
}

fn trainStep(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/scripts/train.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("perfect-tetris", libModule(b, target, optimize));
    importDependencies(exe_mod, &.{ .engine, .nterm, .zmai }, target, optimize);

    const exe = b.addExecutable(.{ .name = "nn-train", .root_module = exe_mod });

    const run_cmd = b.addRunArtifact(exe);
    const install = b.addInstallArtifact(exe, .{});

    const step = b.step("train", "Train neural networks");
    step.dependOn(&run_cmd.step);
    step.dependOn(&install.step);
}

fn releaseStep(b: *Build) void {
    const step = b.step("release", "Build release binaries");

    var files: std.ArrayList(Build.LazyPath) = .init(b.allocator);
    defer files.deinit();

    inline for (.{
        .{ .triple = "x86_64-linux", .cpu = "x86_64" },
        .{ .triple = "x86_64-windows", .cpu = "x86_64" },
        .{ .triple = "x86_64-linux", .cpu = "x86_64_v3" },
        .{ .triple = "x86_64-windows", .cpu = "x86_64_v3" },
    }) |target| {
        const resolved_target = b.resolveTargetQuery(Build.parseTargetQuery(.{
            .arch_os_abi = target.triple,
            .cpu_features = target.cpu,
        }) catch unreachable);

        var triple_parts = std.mem.splitScalar(u8, target.triple, '-');
        _ = triple_parts.next();
        const name = std.fmt.allocPrint(b.allocator, "pc-{s}-{s}", .{
            target.cpu,
            triple_parts.next().?,
        }) catch @panic("OOM");
        defer b.allocator.free(name);

        const exe = pcExecutable(b, name, resolved_target, .ReleaseFast);
        exe.root_module.strip = true;
        const install = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = "release" } },
            .pdb_dir = .disabled,
        });
        step.dependOn(&install.step);

        files.append(exe.getEmittedBin()) catch @panic("OOM");
    }

    const checksums = b.addInstallFile(hashFiles(b, files.items), "release/sha256.txt");
    step.dependOn(&checksums.step);
}

fn wasmStep(b: *Build) void {
    const wasm_target = b.resolveTargetQuery(Build.parseTargetQuery(.{
        .arch_os_abi = "wasm32-freestanding",
    }) catch unreachable);

    // Create the WASM module with embedded dependencies
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm_api.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });

    // Add the perfect-tetris library as import
    wasm_mod.addImport("perfect-tetris", libModule(b, wasm_target, .ReleaseSmall));
    importDependencies(wasm_mod, &.{ .engine, .zmai }, wasm_target, .ReleaseSmall);

    const wasm = b.addExecutable(.{
        .name = "pc-solver",
        .root_module = wasm_mod,
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.root_module.strip = true;

    const install = b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
    });

    const step = b.step("wasm", "Build WebAssembly module for browser");
    step.dependOn(&install.step);
}
