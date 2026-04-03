const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module for external projects.
    // Allows: const mcp = @import("mcp"); after adding as dependency.
    _ = b.addModule("mcp", .{
        .root_source_file = b.path("src/mcp.zig"),
    });

    // Static library (for release artifacts)
    const lib = b.addLibrary(.{
        .name = "mcp",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mcp.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(lib);

    // Internal module with target/optimize for building examples and tests.
    const mcp_module = b.createModule(.{
        .root_source_file = b.path("src/mcp.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/mcp.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const compile_unit_tests = b.step("test-compile", "Compile unit tests without running");
    compile_unit_tests.dependOn(&unit_tests.step);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Example: Simple Server
    const server_mod = b.createModule(.{
        .root_source_file = b.path("examples/simple_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_mod.addImport("mcp", mcp_module);

    const server_example = b.addExecutable(.{
        .name = "example-server",
        .root_module = server_mod,
    });
    b.installArtifact(server_example);

    const run_server = b.addRunArtifact(server_example);
    const server_step = b.step("run-server", "Run the example server");
    server_step.dependOn(&run_server.step);

    // Example: Simple Client
    const client_mod = b.createModule(.{
        .root_source_file = b.path("examples/simple_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_mod.addImport("mcp", mcp_module);

    const client_example = b.addExecutable(.{
        .name = "example-client",
        .root_module = client_mod,
    });
    b.installArtifact(client_example);

    const run_client = b.addRunArtifact(client_example);
    if (b.args) |args| {
        run_client.addArgs(args);
    }
    const client_step = b.step("run-client", "Run the example client");
    client_step.dependOn(&run_client.step);

    // Example: Weather Server
    const weather_mod = b.createModule(.{
        .root_source_file = b.path("examples/weather_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    weather_mod.addImport("mcp", mcp_module);

    const weather_example = b.addExecutable(.{
        .name = "weather-server",
        .root_module = weather_mod,
    });
    b.installArtifact(weather_example);

    const run_weather = b.addRunArtifact(weather_example);
    const weather_step = b.step("run-weather", "Run the weather server example");
    weather_step.dependOn(&run_weather.step);

    // Example: Calculator Tool Server
    const calc_mod = b.createModule(.{
        .root_source_file = b.path("examples/calculator_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    calc_mod.addImport("mcp", mcp_module);

    const calc_example = b.addExecutable(.{
        .name = "calculator-server",
        .root_module = calc_mod,
    });
    b.installArtifact(calc_example);

    const run_calc = b.addRunArtifact(calc_example);
    const calc_step = b.step("run-calc", "Run the calculator server example");
    calc_step.dependOn(&run_calc.step);
}
