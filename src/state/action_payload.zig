const std = @import("std");

/// A helper type for actions that require heap allocations.
/// T must define an 'init' function with (arena, args) parameters.
/// All allocations in the underlying struct are cleaned up by the
/// arena in the ActionPayload parent struct.
///
/// e.g.
///
/// ```zig
/// const UpdateDeviceAction = *ActionPayload(struct {
///     device_id: []u8,
///
///    pub fn init(
///        arena: *std.heap.ArenaAllocator,
///        args: struct { device_id: []u8 },
///     ) !@This() {
///         return .{
///             .device_id = try arena.allocator().dupe(u8, args.device_id),
///         };
///     }
/// });
///
/// // Usage looks like this.
/// const action: *UpdateDeviceAction = try .init(allocator, .{ .device_id = &.{} });
/// defer action.deinit();
/// const id = action.payload.device_id;
/// ...
/// ```
pub fn ActionPayload(T: anytype) type {
    const init_fn_type_info = @typeInfo(@TypeOf(@field(T, "init")));
    const init_fn = init_fn_type_info.@"fn";

    const compiler_error = "ActionPayload requires T.init(arena: *std.heap.ArenaAllocator, args: <anystruct>) with exactly 2 parameters where args is of type struct.";

    if (!@hasDecl(T, "init") or init_fn_type_info != .@"fn") {
        @compileError(@typeName(T) ++ " must contain an 'init' function.");
    }

    if (init_fn.params.len != 2 or @typeInfo(init_fn.params[1].type.?) != .@"struct") {
        @compileError(compiler_error);
    }

    const first_param = @typeInfo(init_fn.params[0].type.?);
    if (first_param != .pointer or first_param.pointer.child != std.heap.ArenaAllocator) {
        @compileError(compiler_error);
    }

    const InitArgs = init_fn.params[1].type.?;

    return struct {
        arena: *std.heap.ArenaAllocator,
        payload: T,

        pub fn init(allocator: std.mem.Allocator, args: InitArgs) !*@This() {
            const arena = try allocator.create(std.heap.ArenaAllocator);
            arena.* = .init(allocator);

            const self = try arena.allocator().create(@This());
            self.* = .{
                .arena = arena,
                .payload = try T.init(arena, args),
            };

            return self;
        }

        pub fn deinit(self: *@This()) void {
            const arena = self.arena;
            const allocator = self.arena.child_allocator;
            self.arena.deinit();
            allocator.destroy(arena);
        }
    };
}
