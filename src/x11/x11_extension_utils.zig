const std = @import("std");
const x = @import("x");
const common = @import("./x11_common.zig");
const buffer_utils = @import("../buffer_utils.zig");

/// X server extension info.
pub const ExtensionInfo = struct {
    extension_name: []const u8,
    /// The extension opcode is used to identify which X extension a given request is
    /// intended for (used as the major opcode). This essentially namespaces any extension
    /// requests. The extension differentiates its own requests by using a minor opcode.
    opcode: u8,
    /// Extension error codes are added on top of this base error code.
    base_error_code: u8,
};

/// A map of X server extension names to their info.
pub const Extensions = struct {
    render: ExtensionInfo,
};

/// Determines whether the extension is available on the server.
pub fn getExtensionInfo(
    sock: std.os.socket_t,
    buffer: *x.ContiguousReadBuffer,
    comptime extension_name: []const u8,
) !?ExtensionInfo {
    const reader = common.SocketReader{ .context = sock };
    const buffer_limit = buffer.half_len;

    {
        const ext_name = comptime x.Slice(u16, [*]const u8).initComptime(extension_name);
        var message_buffer: [x.query_extension.getLen(ext_name.len)]u8 = undefined;
        x.query_extension.serialize(&message_buffer, ext_name);
        try common.send(sock, &message_buffer);
    }
    const message_length = try x.readOneMsg(reader, @alignCast(buffer.nextReadBuffer()));
    try buffer_utils.checkMessageLengthFitsInBuffer(message_length, buffer_limit);
    const optional_render_extension = blk: {
        switch (x.serverMsgTaggedUnion(@alignCast(buffer.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg: *x.ServerMsg.QueryExtension = @ptrCast(msg_reply);
                if (msg.present == 0) {
                    std.log.info("{s} extension: not present", .{extension_name});
                    break :blk null;
                }
                std.debug.assert(msg.present == 1);
                std.log.info("{s} extension: opcode={} base_error_code={}", .{
                    extension_name,
                    msg.major_opcode,
                    msg.first_error,
                });
                std.log.info("{s} extension: {}", .{ extension_name, msg });
                break :blk ExtensionInfo{
                    .extension_name = extension_name,
                    .opcode = msg.major_opcode,
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
