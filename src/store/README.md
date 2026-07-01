# Store

The store implements similar patterns to that of Redux, although state change is
not immutable. The state MUST only be mutated in the `update` function, because
there is a lock around the update. This is necessary because it runs
independently of the UI thread.

## Main Store

`Store` owns the global application state, the message queue, and the effect
thread pool. Messages are dispatched to the main store, processed by the
appropriate child store `update` function, and then any effects declared for
that message are scheduled. Effects run after the `update` function,
asynchronously on the effect thread pool.

## Child Stores

A child store is a domain-specific slice of the main store. It consists of:

- `Message` - a union of domain messages that can be dispatched (like Redux actions).
- `State` - the state owned by the child store.
- `update` - the only place the child store mutates its state in response to
  messages (like Redux reducer).
- `Message.effects` - optional side effects that run after a message is handled.

Child stores are registered in `Store.ChildStores`. The main store uses that
list to execute updates and discover effect declarations.

### Child Store Template

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const Store = @import("./store.zig").Store;

pub const TemplateStore = struct {
    const Self = @This();
    const log = std.log.scoped(.template_store);

    pub const Message = union(enum) {
        do_some_thing: bool,

        pub const effects = .{
            .do_some_thing = .{effect_do_some_thing},
        };

        pub fn deinit(self: *@This()) void {
            switch (self.*) {
                // Handle cleanup like this.
                .do_some_thing => |*payload| {},
                // This is a compile time check to make sure that all messages
                // get cleaned up even if they are still in the queue when the app
                // closes.
                inline else => |payload| {
                    if (@typeInfo(@TypeOf(payload)) == .@"struct" and
                        @hasDecl(@TypeOf(payload), "deinit"))
                    {
                        @compileError("Payload with 'deinit' must be explicitly handled.");
                    }
                },
            }
        }
    };

    pub const State = struct {
        did_thing: bool = false,
    };

    pub fn init() !Self {
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    /// Called before the app closes.
    pub fn exit(_: *Self) void {}

    /// Only update the state in here.
    pub fn update(_: Allocator, msg: Store.Message, state: *Store.State) !void {
        switch (msg) {
            .template => |template_msg| {
                switch (template_msg) {
                    .do_some_thing => |did_some_thing| {
                        state.template_store.did_some_thing = did_some_thing;
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    /// Handle any side effects. This runs asynchronously.
    pub fn effect_do_some_thing(store: *Store, payload: bool) !void {
        _ = store;
        _ = payload;
    }
};
```
