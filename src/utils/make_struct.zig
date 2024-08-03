const std = @import("std");

// via https://mht.wtf/post/comptime-struct/
pub fn MakeStruct(comptime in: anytype) type {
    var fields: [in.len]std.builtin.Type.StructField = undefined;
    for (in, 0..) |t, i| {
        var fieldType: type = t[1];
        var fieldName: []const u8 = t[0][0..];
        if (fieldName[0] == '?') {
            fieldType = @Type(.{ .Optional = .{ .child = fieldType } });
            fieldName = fieldName[1..];
        }
        fields[i] = .{
            .name = fieldName,
            .type = fieldType,
            .default_value = null,
            .is_comptime = false,
            .alignment = 0,
        };
    }
    return @Type(.{
        .Struct = .{
            .layout = .Auto,
            .fields = fields[0..],
            .decls = &.{},
            .is_tuple = false,
        },
    });
}
