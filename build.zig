const std = @import("std");
const protobuf = @import("protobuf");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const protobuf_dep = b.dependency("protobuf", .{
        .target = target,
        .optimize = optimize,
    });

    const gen_proto = b.step("gen-proto", "Generate Zig protobuf sources");
    const protoc_step = protobuf.RunProtocStep.create(protobuf_dep.builder, target, .{
        .destination_directory = b.path("src/proto"),
        .source_files = &.{ "proto/sessh.proto", "proto/sessh_handshake.proto" },
        .include_directories = &.{"proto"},
    });
    gen_proto.dependOn(&protoc_step.step);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("protobuf", protobuf_dep.module("protobuf"));
    addGhosttyVtImport(b, exe_mod, target, optimize);
    addPlatformLibraries(exe_mod, target);

    const exe = b.addExecutable(.{
        .name = "sessh-dev",
        .root_module = exe_mod,
    });
    exe.step.dependOn(&protoc_step.step);

    const wrapper_install = b.addInstallFileWithDir(
        b.path("src/sessh-wrapper.sh"),
        .prefix,
        "bin/sessh",
    );
    const wrapper_path = b.getInstallPath(.prefix, "bin/sessh");
    const chmod_wrapper = b.addSystemCommand(&.{ "chmod", "755", wrapper_path });
    chmod_wrapper.step.dependOn(&wrapper_install.step);
    b.getInstallStep().dependOn(&chmod_wrapper.step);

    const run_step = b.step("run", "Run sessh");
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const install_dev_step = b.step("install-dev", "Install the current sessh-dev executable for tests");
    const install_dev = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .prefix },
        .dest_sub_path = "bin/sessh-dev",
    });
    install_dev_step.dependOn(&install_dev.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("protobuf", protobuf_dep.module("protobuf"));
    addGhosttyVtImport(b, test_mod, target, optimize);
    addPlatformLibraries(test_mod, target);

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    unit_tests.step.dependOn(&protoc_step.step);

    const test_step = b.step("test", "Run Zig tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const artifacts_step = addArtifactsStep(b, &protoc_step.step);
    b.getInstallStep().dependOn(artifacts_step);
}

const ArtifactTarget = struct {
    filename: []const u8,
    query: std.Target.Query,
};

fn addArtifactsStep(b: *std.Build, protoc_step: *std.Build.Step) *std.Build.Step {
    const artifacts_step = b.step(
        "artifacts",
        "Build/install platform binaries without replacing the wrapper",
    );

    const artifact_targets = [_]ArtifactTarget{
        .{
            .filename = "sessh-macos-aarch64",
            .query = .{ .cpu_arch = .aarch64, .os_tag = .macos },
        },
        .{
            .filename = "sessh-macos-x86_64",
            .query = .{ .cpu_arch = .x86_64, .os_tag = .macos },
        },
        .{
            .filename = "sessh-linux-arm32",
            .query = .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .musleabihf },
        },
        .{
            .filename = "sessh-linux-aarch64",
            .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
        },
        .{
            .filename = "sessh-linux-x86_64",
            .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
        },
        .{
            .filename = "sessh-linux-x86",
            .query = .{ .cpu_arch = .x86, .os_tag = .linux, .abi = .musl },
        },
        .{
            .filename = "sessh-linux-riscv64",
            .query = .{
                .cpu_arch = .riscv64,
                .os_tag = .linux,
                .abi = .musl,
                .cpu_model = .{ .explicit = &std.Target.riscv.cpu.generic_rv64 },
                .cpu_features_add = std.Target.riscv.featureSet(&.{
                    .a,
                    .v,
                    .zalrsc,
                    .zve32x,
                }),
            },
        },
    };

    const manifest_mod = b.createModule(.{
        .root_source_file = b.path("src/artifact_manifest.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const manifest_tool = b.addExecutable(.{
        .name = "sessh-artifact-manifest",
        .root_module = manifest_mod,
    });
    const manifest_run = b.addRunArtifact(manifest_tool);
    const manifest_file = manifest_run.addOutputFileArg("artifacts.manifest");

    for (artifact_targets) |artifact_target| {
        const artifact = artifactExecutable(
            b,
            artifact_target.filename,
            b.resolveTargetQuery(artifact_target.query),
        );
        artifact.step.dependOn(protoc_step);
        const install = b.addInstallArtifact(artifact, .{
            .dest_dir = .{ .override = .prefix },
            .dest_sub_path = b.fmt("libexec/sessh/{s}", .{artifact_target.filename}),
        });
        artifacts_step.dependOn(&install.step);

        manifest_run.addArg(artifact_target.filename);
        manifest_run.addFileArg(artifact.getEmittedBin());
    }

    const manifest_install = b.addInstallFile(manifest_file, "libexec/sessh/artifacts.manifest");
    artifacts_step.dependOn(&manifest_install.step);

    return artifacts_step;
}

fn artifactExecutable(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .link_libc = true,
    });
    const protobuf_dep = b.dependency("protobuf", .{
        .target = target,
        .optimize = .ReleaseSmall,
    });
    mod.addImport("protobuf", protobuf_dep.module("protobuf"));
    addGhosttyVtImport(b, mod, target, .ReleaseSmall);
    addPlatformLibraries(mod, target);

    return b.addExecutable(.{
        .name = name,
        .root_module = mod,
    });
}

fn addPlatformLibraries(mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    switch (target.result.os.tag) {
        .linux => mod.linkSystemLibrary("util", .{}),
        else => {},
    }
}

fn addGhosttyVtImport(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }
}
