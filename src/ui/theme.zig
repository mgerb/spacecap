const c = @import("imguiz").imguiz;

pub const red = Color.init("#c24d3f");
pub const light_red = Color.init("#cf625a");
pub const green = Color.init("#29ae62");
pub const light_green = Color.init("#36c37d");
pub const light_blue = Color.init("#5bbcff");
pub const blue = Color.init("#3791d2");
pub const dark_blue = Color.init("#2a7cb7");
pub const text = Color.init("#faf4eb");
pub const light_accent = Color.init("#f2e6cf");
pub const accent = Color.init("#e1ccad");
pub const dark_1 = Color.init("#0a0a0a");
pub const dark_2 = Color.init("#212121");
pub const dark_3 = Color.init("#363636");

fn hex_to_imvec4(comptime hex: []const u8) c.ImVec4 {
    const start = if (hex.len > 0 and hex[0] == '#') 1 else 0;
    const digits = hex.len - start;
    if (digits != 6 and digits != 8) {
        @compileError("hex color must be rrggbb, #rrggbb, rrggbbaa, or #rrggbbaa");
    }

    const r = hex_byte(hex[start], hex[start + 1]);
    const g = hex_byte(hex[start + 2], hex[start + 3]);
    const b = hex_byte(hex[start + 4], hex[start + 5]);
    const a = if (digits == 8) hex_byte(hex[start + 6], hex[start + 7]) else 255;

    return .{
        .x = @as(f32, @floatFromInt(r)) / 255.0,
        .y = @as(f32, @floatFromInt(g)) / 255.0,
        .z = @as(f32, @floatFromInt(b)) / 255.0,
        .w = @as(f32, @floatFromInt(a)) / 255.0,
    };
}

fn hex_byte(comptime high: u8, comptime low: u8) u8 {
    return hex_digit(high) * 16 + hex_digit(low);
}

fn hex_digit(comptime digit: u8) u8 {
    return switch (digit) {
        '0'...'9' => digit - '0',
        'a'...'f' => digit - 'a' + 10,
        'A'...'F' => digit - 'A' + 10,
        else => @compileError("hex color contains a non-hex digit"),
    };
}

pub const Color = struct {
    hex: []const u8,
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn init(comptime hex: []const u8) Color {
        const start = if (hex.len > 0 and hex[0] == '#') 1 else 0;
        const digits = hex.len - start;
        if (digits != 6 and digits != 8) {
            @compileError("hex color must be rrggbb, #rrggbb, rrggbbaa, or #rrggbbaa");
        }

        const r = hex_byte(hex[start], hex[start + 1]);
        const g = hex_byte(hex[start + 2], hex[start + 3]);
        const b = hex_byte(hex[start + 4], hex[start + 5]);
        const a = if (digits == 8) hex_byte(hex[start + 6], hex[start + 7]) else 255;

        return .{ .hex = hex, .r = r, .g = g, .b = b, .a = a };
    }

    pub fn as_vec4(self: Color) c.ImVec4 {
        return .{
            .x = @as(f32, @floatFromInt(self.r)) / 255.0,
            .y = @as(f32, @floatFromInt(self.g)) / 255.0,
            .z = @as(f32, @floatFromInt(self.b)) / 255.0,
            .w = @as(f32, @floatFromInt(self.a)) / 255.0,
        };
    }

    pub fn as_vec4_with_alpha(self: Color, alpha: f32) c.ImVec4 {
        var vec = self.as_vec4();
        vec.w = alpha;
        return vec;
    }
};
