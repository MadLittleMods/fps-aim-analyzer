const std = @import("std");
const MakeStruct = @import("../utils/make_struct.zig").MakeStruct;
const x = @import("x");
const common = @import("./x11_common.zig");

/// X server extension info.
pub const ExtensionInfo = struct {
    extension_name: []const u8,
    /// The extension opcode is used to identify which X extension a given request is
    /// intended for (used as the major opcode). This essentially namespaces any extension
    /// requests. The extension differentiates its own requests by using a minor opcode.
    opcode: u8,
    /// Extension events are added on top of this base event code.
    base_event_code: u8,
    /// Extension error codes are added on top of this base error code.
    base_error_code: u8,
};

const AvailableExtensions = enum {
    render,
    input,
};

/// A map of X server extension names to their info.
pub fn Extensions(comptime extensions: []const AvailableExtensions) type {
    var fields: [extensions.len]std.meta.Tuple(&.{ []const u8, type }) = undefined;
    inline for (extensions, 0..) |ext, index| {
        fields[index] = .{ @tagName(ext), ExtensionInfo };
    }

    return MakeStruct(fields);
}

/// Determines whether the extension is available on the server.
pub fn getExtensionInfo(
    x_connection: common.XConnection,
    comptime extension_name: []const u8,
) !?ExtensionInfo {
    {
        const ext_name = comptime x.Slice(u16, [*]const u8).initComptime(extension_name);
        var message_buffer: [x.query_extension.getLen(ext_name.len)]u8 = undefined;
        x.query_extension.serialize(&message_buffer, ext_name);
        try common.send(x_connection.socket, &message_buffer);
    }
    const message_length = try x.readOneMsg(x_connection.reader(), @alignCast(x_connection.buffer.nextReadBuffer()));
    try common.checkMessageLengthFitsInBuffer(message_length, x_connection.buffer.half_len);
    const optional_render_extension = blk: {
        switch (x.serverMsgTaggedUnion(@alignCast(x_connection.buffer.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg: *x.ServerMsg.QueryExtension = @ptrCast(msg_reply);
                if (msg.present == 0) {
                    std.log.info("{s} extension: not present", .{extension_name});
                    break :blk null;
                }
                std.debug.assert(msg.present == 1);
                std.log.info("{s} extension: opcode={} base_event_code={} base_error_code={}", .{
                    extension_name,
                    msg.major_opcode,
                    msg.first_event,
                    msg.first_error,
                });
                std.log.info("{s} extension: {}", .{ extension_name, msg });
                break :blk ExtensionInfo{
                    .extension_name = extension_name,
                    .opcode = msg.major_opcode,
                    .base_event_code = msg.first_event,
                    .base_error_code = msg.first_error,
                };
            },
            else => |msg| {
                std.log.err("expected a reply for `x.query_extension` but got {}", .{msg});
                return error.ExpectedReplyButGotSomethingElse;
            },
        }
    };

    return optional_render_extension;
}
