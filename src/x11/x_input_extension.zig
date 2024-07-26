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
pub fn ensureCompatibleVersionOfXInputExtension(
    sock: std.os.socket_t,
    buffer: *x.ContiguousReadBuffer,
    input_extension: *const x11_extension_utils.ExtensionInfo,
    version: struct {
        major_version: u16,
        minor_version: u16,
    },
) !void {
    const reader = common.SocketReader{ .context = sock };
    const buffer_limit = buffer.half_len;

    {
        var message_buffer: [x.inputext.query_version.len]u8 = undefined;
        x.inputext.query_version.serialize(&message_buffer, input_extension.opcode, .{
            .major_version = version.major_version,
            .minor_version = version.minor_version,
        });
        try common.send(sock, &message_buffer);
    }
    const message_length = try x.readOneMsg(reader, @alignCast(buffer.nextReadBuffer()));
    try common.checkMessageLengthFitsInBuffer(message_length, buffer_limit);
    switch (x.serverMsgTaggedUnion(@alignCast(buffer.double_buffer_ptr))) {
        .reply => |msg_reply| {
            const msg: *x.inputext.query_version.Reply = @ptrCast(msg_reply);
            std.log.info("X Input extension: version {}.{}", .{ msg.major_version, msg.minor_version });
            if (msg.major_version != version.major_version) {
                std.log.err("X Input extension major version is {} but we expect {}", .{
                    msg.major_version,
                    version.major_version,
                });
                return error.XInputExtensionTooNew;
            }
            if (msg.minor_version < version.minor_version) {
                std.log.err("X Input extension minor version is {}.{} but I've only tested >= {}.{})", .{
                    msg.major_version,
                    msg.minor_version,
                    version.major_version,
                    version.minor_version,
                });
                return error.XInputExtensionTooOld;
            }
        },
        else => |msg| {
            std.log.err("expected a reply for `x.inputext.query_version` but got {}", .{msg});
            return error.ExpectedReplyButGotSomethingElse;
        },
    }
}
