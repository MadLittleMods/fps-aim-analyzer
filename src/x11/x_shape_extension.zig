// X Input Extension
//
// - Docs: https://www.x.org/releases/X11R7.7/doc/inputproto/XI2proto.txt
// - XML definitions of the protocol: https://gitlab.freedesktop.org/xorg/proto/xcbproto/-/blob/1388374c7149114888a6a5cd6e9bf6ad4b42adf8/src/xinput.xml

const std = @import("std");
const x = @import("x");
const common = @import("./x11_common.zig");
const x11_extension_utils = @import("./x11_extension_utils.zig");
const buffer_utils = @import("../utils/buffer_utils.zig");

/// Check to make sure we're using a compatible version of the X Input extension
/// that supports all of the features we need.
pub fn ensureCompatibleVersionOfXShapeExtension(
    sock: std.os.socket_t,
    buffer: *x.ContiguousReadBuffer,
    shape_extension: *const x11_extension_utils.ExtensionInfo,
    version: struct {
        major_version: u16,
        minor_version: u16,
    },
) !void {
    const reader = common.SocketReader{ .context = sock };
    const buffer_limit = buffer.half_len;

    {
        var message_buffer: [x.shape.query_version.len]u8 = undefined;
        x.shape.query_version.serialize(&message_buffer, shape_extension.opcode);
        try common.send(sock, &message_buffer);
    }
    const message_length = try x.readOneMsg(reader, @alignCast(buffer.nextReadBuffer()));
    try buffer_utils.checkMessageLengthFitsInBuffer(message_length, buffer_limit);
    switch (x.serverMsgTaggedUnion(@alignCast(buffer.double_buffer_ptr))) {
        .reply => |msg_reply| {
            const msg: *x.shape.query_version.Reply = @ptrCast(msg_reply);
            std.log.info("X SHAPE extension: version {}.{}", .{ msg.major_version, msg.minor_version });
            if (msg.major_version != version.major_version) {
                std.log.err("X SHAPE extension major version is {} but we expect {}", .{
                    msg.major_version,
                    version.major_version,
                });
                return error.XInputExtensionTooNew;
            }
            if (msg.minor_version < version.minor_version) {
                std.log.err("X SHAPE extension minor version is {}.{} but I've only tested >= {}.{})", .{
                    msg.major_version,
                    msg.minor_version,
                    version.major_version,
                    version.minor_version,
                });
                return error.XInputExtensionTooOld;
            }
        },
        else => |msg| {
            std.log.err("expected a reply for `x.shape.query_version` but got {}", .{msg});
            return error.ExpectedReplyButGotSomethingElse;
        },
    }
}
