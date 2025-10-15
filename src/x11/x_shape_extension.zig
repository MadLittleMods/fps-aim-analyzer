// X Input Extension
//
// - Docs: https://www.x.org/releases/X11R7.7/doc/inputproto/XI2proto.txt
// - XML definitions of the protocol: https://gitlab.freedesktop.org/xorg/proto/xcbproto/-/blob/1388374c7149114888a6a5cd6e9bf6ad4b42adf8/src/xinput.xml

const std = @import("std");
const x = @import("x");
const common = @import("./x11_common.zig");
const x11_extension_utils = @import("./x11_extension_utils.zig");

/// Check to make sure we're using a compatible version of the X Input extension
/// that supports all of the features we need.
pub fn ensureCompatibleVersionOfXShapeExtension(
    x_connection: common.XConnection,
    shape_extension: *const x11_extension_utils.ExtensionInfo,
    version: struct {
        major_version: u16,
        minor_version: u16,
    },
) !void {
    {
        var message_buffer: [x.shape.query_version.len]u8 = undefined;
        x.shape.query_version.serialize(&message_buffer, shape_extension.opcode);
        try x_connection.send(&message_buffer);
    }
    const message_length = try x.readOneMsg(x_connection.reader(), @alignCast(x_connection.buffer.nextReadBuffer()));
    try common.checkMessageLengthFitsInBuffer(message_length, x_connection.buffer.half_len);
    switch (x.serverMsgTaggedUnion(@alignCast(x_connection.buffer.double_buffer_ptr))) {
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
