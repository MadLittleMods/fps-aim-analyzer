// X Render Extension
//
// - Docs:
//    - https://www.x.org/releases/X11R7.5/doc/renderproto/renderproto.txt
//    - https://www.keithp.com/~keithp/render/protocol.html
// - XML definitions of the protocol: https://gitlab.freedesktop.org/xorg/proto/xcbproto/-/blob/98eeebfc2d7db5377b85437418fb942ea30ffc0d/src/render.xml

const std = @import("std");
const x = @import("x");
const common = @import("./x11_common.zig");
const x11_extension_utils = @import("./x11_extension_utils.zig");
const buffer_utils = @import("../buffer_utils.zig");

pub fn ensureCompatibleVersionOfXRenderExtension(
    sock: std.os.socket_t,
    buffer: *x.ContiguousReadBuffer,
    render_extension: *const x11_extension_utils.ExtensionInfo,
) !void {
    const reader = common.SocketReader{ .context = sock };
    const buffer_limit = buffer.half_len;

    {
        var message_buffer: [x.render.query_version.len]u8 = undefined;
        x.render.query_version.serialize(&message_buffer, render_extension.opcode, .{
            .major_version = 0,
            .minor_version = 11,
        });
        try common.send(sock, &message_buffer);
    }
    const message_length = try x.readOneMsg(reader, @alignCast(buffer.nextReadBuffer()));
    try buffer_utils.checkMessageLengthFitsInBuffer(message_length, buffer_limit);
    switch (x.serverMsgTaggedUnion(@alignCast(buffer.double_buffer_ptr))) {
        .reply => |msg_reply| {
            const msg: *x.render.query_version.Reply = @ptrCast(msg_reply);
            std.log.info("RENDER extension: version {}.{}", .{ msg.major_version, msg.minor_version });
            if (msg.major_version != 0) {
                std.log.err("X Render extension major version {} too new", .{msg.major_version});
                return error.XRenderExtensionTooNew;
            }
            if (msg.minor_version < 11) {
                std.log.err("X Render extension minor version {} too old", .{msg.minor_version});
                return error.XRenderExtensionTooOld;
            }
        },
        else => |msg| {
            std.log.err("expected a reply for `x.render.query_version` but got {}", .{msg});
            return error.ExpectedReplyButGotSomethingElse;
        },
    }
}
