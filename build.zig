const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const httpx_dep = b.dependency("httpx", .{
        .target = target,
        .optimize = optimize,
    });
    const httpx_module = httpx_dep.module("httpx");

    const mcp_module = b.addModule("mcp", .{
        .root_source_file = b.path("src/mcp.zig"),
    });
    mcp_module.addImport("httpx", httpx_module);

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

    const docs_step = b.step("docs", "Generate library documentation");
    docs_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    }).step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mcp.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addImport("httpx", httpx_module);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

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
        const exe = b.addExecutable(.{
            .name = ex.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.src),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("mcp", mcp_module);
        exe.root_module.addImport("httpx", httpx_module);

        all_step.dependOn(&b.addInstallArtifact(exe, .{}).step);

        const run_step = b.step(ex.run_step, ex.desc);
        run_step.dependOn(&b.addRunArtifact(exe).step);
    }

    // Compile-only check for cross-target CI:
    // `zig build test-compile -Dtarget=<triple>` compiles the unit tests and
    // every example for the selected 32/64-bit target without executing
    // anything, so it works for foreign targets that cannot run on the host.
    const test_compile_step = b.step("test-compile", "Compile unit tests and examples for the target without running them");
    const compile_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mcp.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    compile_tests.root_module.addImport("httpx", httpx_module);
    test_compile_step.dependOn(&compile_tests.step);

    inline for (examples) |ex| {
        const exe_check = b.addExecutable(.{
            .name = ex.name ++ "-check",
            .root_module = b.createModule(.{
                .root_source_file = b.path(ex.src),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe_check.root_module.addImport("mcp", mcp_module);
        exe_check.root_module.addImport("httpx", httpx_module);
        test_compile_step.dependOn(&exe_check.step);
    }
}
