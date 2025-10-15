// X Render Extension (RENDER)
//
// - Docs:
//    - https://www.x.org/releases/X11R7.5/doc/renderproto/renderproto.txt
//    - https://www.keithp.com/~keithp/render/protocol.html
// - XML definitions of the protocol: https://gitlab.freedesktop.org/xorg/proto/xcbproto/-/blob/98eeebfc2d7db5377b85437418fb942ea30ffc0d/src/render.xml

const std = @import("std");
const x = @import("x");
const common = @import("./x11_common.zig");
const x11_extension_utils = @import("./x11_extension_utils.zig");

/// Check to make sure we're using a compatible version of the X Render extension
/// that supports all of the features we need.
pub fn ensureCompatibleVersionOfXRenderExtension(
    x_connection: common.XConnection,
    render_extension: *const x11_extension_utils.ExtensionInfo,
    version: struct {
        major_version: u32,
        minor_version: u32,
    },
) !void {
    {
        var message_buffer: [x.render.query_version.len]u8 = undefined;
        x.render.query_version.serialize(&message_buffer, render_extension.opcode, .{
            .major_version = version.major_version,
            .minor_version = version.minor_version,
        });
        try x_connection.send(&message_buffer);
    }
    const message_length = try x.readOneMsg(x_connection.reader(), @alignCast(x_connection.buffer.nextReadBuffer()));
    try common.checkMessageLengthFitsInBuffer(message_length, x_connection.buffer.half_len);
    switch (x.serverMsgTaggedUnion(@alignCast(x_connection.buffer.double_buffer_ptr))) {
        .reply => |msg_reply| {
            const msg: *x.render.query_version.Reply = @ptrCast(msg_reply);
            std.log.info("X Render extension: version {}.{}", .{ msg.major_version, msg.minor_version });
            if (msg.major_version != version.major_version) {
                std.log.err("X Render extension major version is {} but we expect {}", .{
                    msg.major_version,
                    version.major_version,
                });
                return error.XRenderExtensionTooNew;
            }
            if (msg.minor_version < version.minor_version) {
                std.log.err("X Render extension minor version is {}.{} but I've only tested >= {}.{})", .{
                    msg.major_version,
                    msg.minor_version,
                    version.major_version,
                    version.minor_version,
                });
                return error.XRenderExtensionTooOld;
            }
        },
        else => |msg| {
            std.log.err("expected a reply for `x.render.query_version` but got {}", .{msg});
            return error.ExpectedReplyButGotSomethingElse;
        },
    }
}

pub fn findPictureFormatForVisualId(
    x_connection: common.XConnection,
    visual_id: u32,
    extensions: *const x11_extension_utils.Extensions(&.{.render}),
) !?x.render.PictureFormatInfo {
    // Find some compatible picture formats for use with the X Render extension. We want
    // to find a 24-bit depth format for use with the root window and a 32-bit depth
    // format for use with our window.
    {
        var message_buffer: [x.render.query_pict_formats.len]u8 = undefined;
        x.render.query_pict_formats.serialize(&message_buffer, extensions.render.opcode);
        try x_connection.send(&message_buffer);
    }
    const message_length = try x.readOneMsg(x_connection.reader(), @alignCast(x_connection.buffer.nextReadBuffer()));
    try common.checkMessageLengthFitsInBuffer(message_length, x_connection.buffer.half_len);
    const opt_picture_format: ?x.render.PictureFormatInfo = blk: {
        switch (x.serverMsgTaggedUnion(@alignCast(x_connection.buffer.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg: *x.render.query_pict_formats.Reply = @ptrCast(msg_reply);

                const opt_picture_format_id: ?u32 = blk_picture_format_id: {
                    for (0..msg.num_screens) |screen_index| {
                        const picture_screen = try msg.getPictureScreenAtIndex(@intCast(screen_index));
                        for (0..picture_screen.num_depths) |depth_index| {
                            const picture_depth = try picture_screen.getPictureDepthAtIndex(@intCast(depth_index));
                            const picture_visuals = picture_depth.getPictureVisuals();
                            for (picture_visuals) |picture_visual| {
                                if (picture_visual.visual_id == visual_id) {
                                    break :blk_picture_format_id picture_visual.picture_format_id;
                                }
                            }
                        }
                    }

                    break :blk_picture_format_id null;
                };

                if (opt_picture_format_id) |picture_format_id| {
                    const picture_formats = msg.getPictureFormats();
                    for (picture_formats) |picture_format| {
                        if (picture_format.picture_format_id == picture_format_id) {
                            break :blk picture_format;
                        }
                    }
                }

                return null;
            },
            else => |msg| {
                std.log.err("expected a reply for `x.render.query_pict_formats` but got {}", .{msg});
                return error.ExpectedReplyButGotSomethingElse;
            },
        }
    };

    return opt_picture_format;
}
