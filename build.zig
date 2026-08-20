const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Fetch httpx dependency
    const httpx_dep = b.dependency("httpx", .{});
    const httpx_module = httpx_dep.module("httpx");

    _ = b.addModule("mcp", .{
        .root_source_file = b.path("src/mcp.zig"),
    });

    // Static library artifact
    const lib = b.addLibrary(.{
        .name = "mcp",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mcp.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lib.root_module.addImport("httpx", httpx_module);
    b.installArtifact(lib);

    // Documentation generation
    const docs_step = b.step("docs", "Generate library documentation");
    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    docs_step.dependOn(&install_docs.step);

    // Internal module used by examples and tests
    const mcp_module = b.createModule(.{
        .root_source_file = b.path("src/mcp.zig"),
        .target = target,
        .optimize = optimize,
    });
    mcp_module.addImport("httpx", httpx_module);

    // Unit tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/mcp.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("httpx", httpx_module);
    const unit_tests = b.addTest(.{ .root_module = test_mod });

    const test_compile_step = b.step("test-compile", "Compile unit tests without running");
    test_compile_step.dependOn(&unit_tests.step);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Helper: add a named example executable
    const all_step = b.step("run-all-examples", "Build all examples");

    const Example = struct { name: []const u8, src: []const u8, run_step: []const u8, desc: []const u8 };
    const examples = [_]Example{
        .{ .name = "example-server", .src = "examples/simple_server.zig", .run_step = "run-server", .desc = "Run the simple server example" },
        .{ .name = "example-client", .src = "examples/simple_client.zig", .run_step = "run-client", .desc = "Run the simple client example" },
        .{ .name = "weather-server", .src = "examples/weather_server.zig", .run_step = "run-weather", .desc = "Run the weather server example" },
        .{ .name = "calculator-server", .src = "examples/calculator_server.zig", .run_step = "run-calc", .desc = "Run the calculator server example" },
        .{ .name = "advanced-server", .src = "examples/advanced_server.zig", .run_step = "run-advanced", .desc = "Run the advanced server example" },
        .{ .name = "filesystem-server", .src = "examples/filesystem_server.zig", .run_step = "run-filesystem", .desc = "Run the filesystem server example" },
        .{ .name = "notes-server", .src = "examples/notes_server.zig", .run_step = "run-notes", .desc = "Run the notes server example" },
        .{ .name = "http-server", .src = "examples/http_server.zig", .run_step = "run-http", .desc = "Run the HTTP server example" },
        .{ .name = "middleware-server", .src = "examples/middleware_server.zig", .run_step = "run-middleware", .desc = "Run the middleware server example" },
        .{ .name = "batch-client", .src = "examples/batch_client.zig", .run_step = "run-batch", .desc = "Run the batch client example" },
        .{ .name = "rate-limiter-example", .src = "examples/rate_limiter_example.zig", .run_step = "run-rate-limiter", .desc = "Run the rate limiter example" },
        .{ .name = "health-check-example", .src = "examples/health_check_example.zig", .run_step = "run-health-check", .desc = "Run the health check example" },
        .{ .name = "shutdown-example", .src = "examples/shutdown_example.zig", .run_step = "run-shutdown", .desc = "Run the shutdown example" },
        .{ .name = "validator-example", .src = "examples/validator_example.zig", .run_step = "run-validator", .desc = "Run the validator example" },
    };

    inline for (examples) |ex| {
        const mod = b.createModule(.{
            .root_source_file = b.path(ex.src),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("mcp", mcp_module);
        mod.addImport("httpx", httpx_module);

        const exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = mod,
        });
        b.installArtifact(exe);

        const run_artifact = b.addRunArtifact(exe);
        run_artifact.step.dependOn(&exe.step);

        const run_step = b.step(ex.run_step, ex.desc);
        run_step.dependOn(&run_artifact.step);
        all_step.dependOn(&exe.step);
    }
}
