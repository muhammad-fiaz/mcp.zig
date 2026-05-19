//! JSON Schema Utilities
//!
//! Provides utilities for working with JSON Schema, which is used extensively
//! in MCP for tool input validation and type definitions.

const std = @import("std");
const types = @import("types.zig");

/// JSON Schema type definitions.
pub const SchemaType = enum {
    object,
    array,
    string,
    number,
    integer,
    boolean,
    null_type,

    /// Returns the string representation of this type.
    pub fn toString(self: SchemaType) []const u8 {
        return switch (self) {
            .object => "object",
            .array => "array",
            .string => "string",
            .number => "number",
            .integer => "integer",
            .boolean => "boolean",
            .null_type => "null",
        };
    }
};

/// A JSON Schema definition.
pub const Schema = struct {
    type: ?SchemaType = null,
    properties: ?std.json.ObjectMap = null,
    required: ?[]const []const u8 = null,
    items: ?*const Schema = null,
    description: ?[]const u8 = null,
    default: ?std.json.Value = null,
    @"enum": ?[]const std.json.Value = null,
    minimum: ?f64 = null,
    maximum: ?f64 = null,
    minLength: ?u64 = null,
    maxLength: ?u64 = null,
    pattern: ?[]const u8 = null,
    title: ?[]const u8 = null,
    format: ?[]const u8 = null,

    /// Converts this schema to a JSON value for serialization.
    pub fn toJson(self: Schema, allocator: std.mem.Allocator) !std.json.Value {
        var obj: std.json.ObjectMap = .empty;
        errdefer obj.deinit(allocator);

        if (self.type) |t| {
            try obj.put(allocator, "type", .{ .string = t.toString() });
        }

        if (self.description) |desc| {
            try obj.put(allocator, "description", .{ .string = desc });
        }

        if (self.title) |t| {
            try obj.put(allocator, "title", .{ .string = t });
        }

        if (self.properties) |props| {
            try obj.put(allocator, "properties", .{ .object = props });
        }

        if (self.required) |req| {
            var arr: std.json.Array = .init(allocator);
            for (req) |name| {
                try arr.append(.{ .string = name });
            }
            try obj.put(allocator, "required", .{ .array = arr });
        }

        return .{ .object = obj };
    }
};

/// Builder for creating JSON schemas programmatically.
pub const SchemaBuilder = struct {
    schema: Schema = .{},

    /// Creates a new schema builder.
    pub fn init() SchemaBuilder {
        return .{};
    }

    /// Sets the schema type.
    pub fn setType(self: *SchemaBuilder, t: SchemaType) *SchemaBuilder {
        self.schema.type = t;
        return self;
    }

    /// Sets the type to object.
    pub fn object_(self: *SchemaBuilder) *SchemaBuilder {
        return self.setType(.object);
    }

    /// Sets the type to string.
    pub fn string_(self: *SchemaBuilder) *SchemaBuilder {
        return self.setType(.string);
    }

    /// Sets the type to number.
    pub fn number_(self: *SchemaBuilder) *SchemaBuilder {
        return self.setType(.number);
    }

    /// Sets the type to integer.
    pub fn integer_(self: *SchemaBuilder) *SchemaBuilder {
        return self.setType(.integer);
    }

    /// Sets the type to boolean.
    pub fn boolean_(self: *SchemaBuilder) *SchemaBuilder {
        return self.setType(.boolean);
    }

    /// Sets the type to array.
    pub fn array_(self: *SchemaBuilder) *SchemaBuilder {
        return self.setType(.array);
    }

    /// Sets the description.
    pub fn description(self: *SchemaBuilder, desc: []const u8) *SchemaBuilder {
        self.schema.description = desc;
        return self;
    }

    /// Sets the title.
    pub fn title_(self: *SchemaBuilder, t: []const u8) *SchemaBuilder {
        self.schema.title = t;
        return self;
    }

    /// Sets the minimum value for numbers.
    pub fn minimum_(self: *SchemaBuilder, min: f64) *SchemaBuilder {
        self.schema.minimum = min;
        return self;
    }

    /// Sets the maximum value for numbers.
    pub fn maximum_(self: *SchemaBuilder, max: f64) *SchemaBuilder {
        self.schema.maximum = max;
        return self;
    }

    /// Sets the regex pattern for strings.
    pub fn pattern_(self: *SchemaBuilder, pat: []const u8) *SchemaBuilder {
        self.schema.pattern = pat;
        return self;
    }

    /// Sets the format hint.
    pub fn format(self: *SchemaBuilder, fmt: []const u8) *SchemaBuilder {
        self.schema.format = fmt;
        return self;
    }

    /// Builds and returns the final schema.
    pub fn build(self: *SchemaBuilder) Schema {
        return self.schema;
    }
};

/// Predefined common schemas.
pub const CommonSchemas = struct {
    /// Schema for a simple string.
    pub fn string_schema(allocator: std.mem.Allocator) !Schema {
        _ = allocator;
        return Schema{ .type = .string };
    }

    /// Schema for a simple number.
    pub fn number_schema(allocator: std.mem.Allocator) !Schema {
        _ = allocator;
        return Schema{ .type = .number };
    }

    /// Schema for a simple integer.
    pub fn integer_schema(allocator: std.mem.Allocator) !Schema {
        _ = allocator;
        return Schema{ .type = .integer };
    }

    /// Schema for a simple boolean.
    pub fn boolean_schema(allocator: std.mem.Allocator) !Schema {
        _ = allocator;
        return Schema{ .type = .boolean };
    }

    /// Schema for a URI string.
    pub fn uri_schema(allocator: std.mem.Allocator) !Schema {
        _ = allocator;
        return Schema{
            .type = .string,
            .format = "uri",
        };
    }

    /// Schema for a date-time string.
    pub fn datetime_schema(allocator: std.mem.Allocator) !Schema {
        _ = allocator;
        return Schema{
            .type = .string,
            .format = "date-time",
        };
    }
};

/// Builder for creating tool input schemas.
pub const InputSchemaBuilder = struct {
    properties: std.StringHashMap(Property),
    required_fields: std.ArrayList([]const u8),
    schema_dialect: ?[]const u8 = null,

    pub const Property = struct {
        type: []const u8,
        description: ?[]const u8 = null,
        @"enum": ?[]const []const u8 = null,
        default: ?std.json.Value = null,
        minimum: ?f64 = null,
        maximum: ?f64 = null,
        minLength: ?u64 = null,
        maxLength: ?u64 = null,
        format: ?[]const u8 = null,
    };

    /// Creates a new input schema builder.
    pub fn init(allocator: std.mem.Allocator) InputSchemaBuilder {
        return .{
            .properties = .init(allocator),
            .required_fields = .empty,
        };
    }

    /// Sets the JSON Schema dialect for the root schema.
    pub fn setSchemaDialect(self: *InputSchemaBuilder, dialect: []const u8) *InputSchemaBuilder {
        self.schema_dialect = dialect;
        return self;
    }

    /// Releases resources held by the builder.
    pub fn deinit(self: *InputSchemaBuilder, allocator: std.mem.Allocator) void {
        self.properties.deinit();
        self.required_fields.deinit(allocator);
    }

    /// Adds a string property.
    pub fn addString(self: *InputSchemaBuilder, allocator: std.mem.Allocator, name: []const u8, desc: ?[]const u8, required: bool) !*InputSchemaBuilder {
        try self.properties.put(name, .{
            .type = "string",
            .description = desc,
        });
        if (required) {
            try self.required_fields.append(allocator, name);
        }
        return self;
    }

    /// Adds a number property.
    pub fn addNumber(self: *InputSchemaBuilder, allocator: std.mem.Allocator, name: []const u8, desc: ?[]const u8, required: bool) !*InputSchemaBuilder {
        try self.properties.put(name, .{
            .type = "number",
            .description = desc,
        });
        if (required) {
            try self.required_fields.append(allocator, name);
        }
        return self;
    }

    /// Adds an integer property.
    pub fn addInteger(self: *InputSchemaBuilder, allocator: std.mem.Allocator, name: []const u8, desc: ?[]const u8, required: bool) !*InputSchemaBuilder {
        try self.properties.put(name, .{
            .type = "integer",
            .description = desc,
        });
        if (required) {
            try self.required_fields.append(allocator, name);
        }
        return self;
    }

    /// Adds a boolean property.
    pub fn addBoolean(self: *InputSchemaBuilder, allocator: std.mem.Allocator, name: []const u8, desc: ?[]const u8, required: bool) !*InputSchemaBuilder {
        try self.properties.put(name, .{
            .type = "boolean",
            .description = desc,
        });
        if (required) {
            try self.required_fields.append(allocator, name);
        }
        return self;
    }

    /// Adds an enum property.
    pub fn addEnum(self: *InputSchemaBuilder, allocator: std.mem.Allocator, name: []const u8, desc: ?[]const u8, values: []const []const u8, required: bool) !*InputSchemaBuilder {
        try self.properties.put(name, .{
            .type = "string",
            .description = desc,
            .@"enum" = values,
        });
        if (required) {
            try self.required_fields.append(allocator, name);
        }
        return self;
    }

    /// Adds a string property with a default value.
    pub fn addStringWithDefault(self: *InputSchemaBuilder, allocator: std.mem.Allocator, name: []const u8, desc: ?[]const u8, default_value: []const u8, required: bool) !*InputSchemaBuilder {
        try self.properties.put(name, .{
            .type = "string",
            .description = desc,
            .default = .{ .string = default_value },
        });
        if (required) {
            try self.required_fields.append(allocator, name);
        }
        return self;
    }

    /// Adds a number property with a default value.
    pub fn addNumberWithDefault(self: *InputSchemaBuilder, allocator: std.mem.Allocator, name: []const u8, desc: ?[]const u8, default_value: f64, required: bool) !*InputSchemaBuilder {
        try self.properties.put(name, .{
            .type = "number",
            .description = desc,
            .default = .{ .float = default_value },
        });
        if (required) {
            try self.required_fields.append(allocator, name);
        }
        return self;
    }

    /// Adds an integer property with a default value.
    pub fn addIntegerWithDefault(self: *InputSchemaBuilder, allocator: std.mem.Allocator, name: []const u8, desc: ?[]const u8, default_value: i64, required: bool) !*InputSchemaBuilder {
        try self.properties.put(name, .{
            .type = "integer",
            .description = desc,
            .default = .{ .integer = default_value },
        });
        if (required) {
            try self.required_fields.append(allocator, name);
        }
        return self;
    }

    /// Adds a boolean property with a default value.
    pub fn addBooleanWithDefault(self: *InputSchemaBuilder, allocator: std.mem.Allocator, name: []const u8, desc: ?[]const u8, default_value: bool, required: bool) !*InputSchemaBuilder {
        try self.properties.put(name, .{
            .type = "boolean",
            .description = desc,
            .default = .{ .bool = default_value },
        });
        if (required) {
            try self.required_fields.append(allocator, name);
        }
        return self;
    }

    /// Adds an enum property with a default value.
    pub fn addEnumWithDefault(self: *InputSchemaBuilder, allocator: std.mem.Allocator, name: []const u8, desc: ?[]const u8, values: []const []const u8, default_value: []const u8, required: bool) !*InputSchemaBuilder {
        try self.properties.put(name, .{
            .type = "string",
            .description = desc,
            .@"enum" = values,
            .default = .{ .string = default_value },
        });
        if (required) {
            try self.required_fields.append(allocator, name);
        }
        return self;
    }

    /// Sets the string format for an existing property.
    pub fn setPropertyFormat(self: *InputSchemaBuilder, name: []const u8, fmt: []const u8) bool {
        if (self.properties.getPtr(name)) |prop| {
            prop.format = fmt;
            return true;
        }
        return false;
    }

    /// Sets the numeric bounds for an existing property.
    pub fn setPropertyRange(self: *InputSchemaBuilder, name: []const u8, minimum: ?f64, maximum: ?f64) bool {
        if (self.properties.getPtr(name)) |prop| {
            prop.minimum = minimum;
            prop.maximum = maximum;
            return true;
        }
        return false;
    }

    /// Sets string length bounds for an existing property.
    pub fn setPropertyLength(self: *InputSchemaBuilder, name: []const u8, min_len: ?u64, max_len: ?u64) bool {
        if (self.properties.getPtr(name)) |prop| {
            prop.minLength = min_len;
            prop.maxLength = max_len;
            return true;
        }
        return false;
    }

    /// Builds the final input schema as an 'InputSchema'.
    pub fn toInputSchema(self: *InputSchemaBuilder, allocator: std.mem.Allocator) !types.InputSchema {
        const props = try self.buildProperties(allocator);

        const req: ?[]const []const u8 = if (self.required_fields.items.len == 0)
            null
        else
            try allocator.dupe([]const u8, self.required_fields.items);

        return .{
            .@"$schema" = self.schema_dialect,
            .type = "object",
            .properties = if (props.count() == 0) null else .{ .object = props },
            .required = req,
        };
    }

    fn buildProperties(self: *InputSchemaBuilder, allocator: std.mem.Allocator) !std.json.ObjectMap {
        var props: std.json.ObjectMap = .empty;
        errdefer props.deinit(allocator);

        var iter = self.properties.iterator();
        while (iter.next()) |entry| {
            var prop_obj: std.json.ObjectMap = .empty;
            try prop_obj.put(allocator, "type", .{ .string = entry.value_ptr.type });
            if (entry.value_ptr.description) |desc| {
                try prop_obj.put(allocator, "description", .{ .string = desc });
            }
            if (entry.value_ptr.@"enum") |values| {
                var enum_arr: std.json.Array = .init(allocator);
                for (values) |value| {
                    try enum_arr.append(.{ .string = value });
                }
                try prop_obj.put(allocator, "enum", .{ .array = enum_arr });
            }
            if (entry.value_ptr.default) |def| {
                try prop_obj.put(allocator, "default", def);
            }
            if (entry.value_ptr.minimum) |min| {
                try prop_obj.put(allocator, "minimum", .{ .float = min });
            }
            if (entry.value_ptr.maximum) |max| {
                try prop_obj.put(allocator, "maximum", .{ .float = max });
            }
            if (entry.value_ptr.minLength) |min_len| {
                try prop_obj.put(allocator, "minLength", .{ .integer = @intCast(min_len) });
            }
            if (entry.value_ptr.maxLength) |max_len| {
                try prop_obj.put(allocator, "maxLength", .{ .integer = @intCast(max_len) });
            }
            if (entry.value_ptr.format) |fmt| {
                try prop_obj.put(allocator, "format", .{ .string = fmt });
            }
            try props.put(allocator, entry.key_ptr.*, .{ .object = prop_obj });
        }

        return props;
    }

    /// Builds the final input schema as a JSON value.
    pub fn build(self: *InputSchemaBuilder, allocator: std.mem.Allocator) !std.json.Value {
        var obj: std.json.ObjectMap = .empty;
        errdefer obj.deinit(allocator);

        if (self.schema_dialect) |dialect| {
            try obj.put(allocator, "$schema", .{ .string = dialect });
        }
        try obj.put(allocator, "type", .{ .string = "object" });

        const props = try self.buildProperties(allocator);
        try obj.put(allocator, "properties", .{ .object = props });

        if (self.required_fields.items.len > 0) {
            var req: std.json.Array = .init(allocator);
            for (self.required_fields.items) |name| {
                try req.append(.{ .string = name });
            }
            try obj.put(allocator, "required", .{ .array = req });
        }

        return .{ .object = obj };
    }
};

test "SchemaBuilder" {
    var builder: SchemaBuilder = .init();

    const schema = builder
        .string_()
        .description("A test string")
        .build();

    try std.testing.expectEqual(SchemaType.string, schema.type.?);
    try std.testing.expectEqualStrings("A test string", schema.description.?);
}

test "InputSchemaBuilder" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var builder: InputSchemaBuilder = .init(allocator);
    defer builder.deinit(allocator);

    _ = try builder.addString(allocator, "name", "User name", true);
    _ = try builder.addInteger(allocator, "age", "User age", false);

    const schema = try builder.build(allocator);

    try std.testing.expectEqualStrings("object", schema.object.get("type").?.string);
}
