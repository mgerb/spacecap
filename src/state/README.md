# State Module

Each file in `src/state/` should define one state domain (for example `audio_state` or `user_settings_state`).

A state file should expose:

1. `pub const <Domain>Actions = union(enum) { ... }`
2. `pub const <Domain>State = struct { ... }`
3. `pub fn handleActions(self: *Self, state_actor: *StateActor, action: <Domain>Actions) !void`

Example:

```zig
pub const ExampleActions = union(enum) {
    do_thing,
    set_value: u32,
};

pub const ExampleState = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Self { ... }
    pub fn deinit(self: *Self) void { ... }

    pub fn handleActions(self: *Self, state_actor: *StateActor, action: ExampleActions) !void {
        switch (action) {
            .do_thing => { ... },
            .set_value => |value| { ... },
        }
    }
};
```
