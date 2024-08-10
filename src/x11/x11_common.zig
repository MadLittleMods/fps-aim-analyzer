// This file is pretty much just copied from the zigx repo
const std = @import("std");
const x = @import("x");
const common = @This();

/// The maximum length of an x11 request we can send to the server in bytes. To send
/// bigger requests, we either need to split them up or support the Big Requests
/// Extension.
pub const MAX_REQUEST_LENGTH_BYTES = 262140;

pub const SocketReader = std.io.Reader(std.os.socket_t, std.os.RecvFromError, readSocket);

pub fn send(sock: std.os.socket_t, data: []const u8) !void {
    const sent = try x.writeSock(sock, data, 0);
    if (sent != data.len) {
        std.log.err("send {} only sent {}\n", .{ data.len, sent });
        return error.DidNotSendAllData;
    }
}

pub const ConnectResult = struct {
    sock: std.os.socket_t,
    setup: x.ConnectSetup,
    pub fn reader(self: ConnectResult) SocketReader {
        return .{ .context = self.sock };
    }
    pub fn send(self: ConnectResult, data: []const u8) !void {
        try common.send(self.sock, data);
    }
};

pub fn connectSetupMaxAuth(
    sock: std.os.socket_t,
    comptime max_auth_len: usize,
    auth_name: x.Slice(u16, [*]const u8),
    auth_data: x.Slice(u16, [*]const u8),
) !?u16 {
    var buf: [x.connect_setup.auth_offset + max_auth_len]u8 = undefined;
    const len = x.connect_setup.getLen(auth_name.len, auth_data.len);
    if (len > max_auth_len)
        return error.AuthTooBig;
    return connectSetup(sock, buf[0..len], auth_name, auth_data);
}

pub fn connectSetup(
    sock: std.os.socket_t,
    msg: []u8,
    auth_name: x.Slice(u16, [*]const u8),
    auth_data: x.Slice(u16, [*]const u8),
) !?u16 {
    std.debug.assert(msg.len == x.connect_setup.getLen(auth_name.len, auth_data.len));

    x.connect_setup.serialize(msg.ptr, 11, 0, auth_name, auth_data);
    try send(sock, msg);

    const reader = SocketReader{ .context = sock };
    const connect_setup_header = try x.readConnectSetupHeader(reader, .{});
    switch (connect_setup_header.status) {
        .failed => {
            std.log.err("connect setup failed, version={}.{}, reason='{s}'", .{
                connect_setup_header.proto_major_ver,
                connect_setup_header.proto_minor_ver,
                connect_setup_header.readFailReason(reader),
            });
            return error.ConnectSetupFailed;
        },
        .authenticate => {
            std.log.err("AUTHENTICATE! not implemented", .{});
            return error.NotImplemetned;
        },
        .success => {
            // TODO: check version?
            std.log.debug("SUCCESS! version {}.{}", .{ connect_setup_header.proto_major_ver, connect_setup_header.proto_minor_ver });
            return connect_setup_header.getReplyLen();
        },
        else => |status| {
            std.log.err("Error: expected 0, 1 or 2 as first byte of connect setup reply, but got {}", .{status});
            return error.MalformedXReply;
        },
    }
}

fn connectSetupAuth(
    display_num: ?u32,
    sock: std.os.socket_t,
    auth_filename: []const u8,
) !?u16 {
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    // TODO: test bad auth
    // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
    //if (try connectSetupMaxAuth(sock, 1000, .{ .ptr = "wat", .len = 3}, .{ .ptr = undefined, .len = 0})) |_|
    //    @panic("todo");

    const auth_mapped = try x.MappedFile.init(auth_filename, .{});
    defer auth_mapped.unmap();

    var auth_filter = x.AuthFilter{
        .addr = .{ .family = .wild, .data = &[0]u8{} },
        .display_num = display_num,
    };

    var addr_buf: [x.max_sock_filter_addr]u8 = undefined;
    if (auth_filter.applySocket(sock, &addr_buf)) {
        std.log.debug("applied address filter {}", .{auth_filter.addr});
    } else |err| {
        // not a huge deal, we'll just try all auth methods
        std.log.warn("failed to apply socket to auth filter with {s}", .{@errorName(err)});
    }

    var auth_it = x.AuthIterator{ .mem = auth_mapped.mem };
    while (auth_it.next() catch {
        std.log.warn("auth file '{s}' is invalid", .{auth_filename});
        return null;
    }) |entry| {
        if (auth_filter.isFiltered(auth_mapped.mem, entry)) |reason| {
            std.log.debug("ignoring auth because {s} does not match: {}", .{ @tagName(reason), entry.fmt(auth_mapped.mem) });
            continue;
        }
        const name = entry.name(auth_mapped.mem);
        const data = entry.data(auth_mapped.mem);
        const name_x = x.Slice(u16, [*]const u8){
            .ptr = name.ptr,
            .len = @intCast(name.len),
        };
        const data_x = x.Slice(u16, [*]const u8){
            .ptr = data.ptr,
            .len = @intCast(data.len),
        };
        std.log.debug("trying auth {}", .{entry.fmt(auth_mapped.mem)});
        if (try connectSetupMaxAuth(sock, 1000, name_x, data_x)) |reply_len|
            return reply_len;
    }

    return null;
}

pub fn connect(allocator: std.mem.Allocator) !ConnectResult {
    const display = x.getDisplay();
    const parsed_display = x.parseDisplay(display) catch |err| {
        std.log.err("invalid display '{s}': {s}", .{ display, @errorName(err) });
        std.os.exit(0xff);
    };

    const sock = x.connect(display, parsed_display) catch |err| {
        std.log.err("failed to connect to display '{s}': {s}", .{ display, @errorName(err) });
        std.os.exit(0xff);
    };
    errdefer x.disconnect(sock);

    const setup_reply_len: u16 = blk: {
        if (try x.getAuthFilename(allocator)) |auth_filename| {
            defer auth_filename.deinit(allocator);
            if (try connectSetupAuth(parsed_display.display_num, sock, auth_filename.str)) |reply_len|
                break :blk reply_len;
        }

        // Try no authentication
        std.log.debug("trying no auth", .{});
        var msg_buf: [x.connect_setup.getLen(0, 0)]u8 = undefined;
        if (try connectSetup(
            sock,
            &msg_buf,
            .{ .ptr = undefined, .len = 0 },
            .{ .ptr = undefined, .len = 0 },
        )) |reply_len| {
            break :blk reply_len;
        }

        std.log.err("the X server rejected our connect setup message", .{});
        std.os.exit(0xff);
    };

    const connect_setup = x.ConnectSetup{
        .buf = try allocator.allocWithOptions(u8, setup_reply_len, 4, null),
    };
    std.log.debug("connect setup reply is {} bytes", .{connect_setup.buf.len});
    const reader = SocketReader{ .context = sock };
    try x.readFull(reader, connect_setup.buf);

    return ConnectResult{ .sock = sock, .setup = connect_setup };
}

pub fn asReply(comptime T: type, msg_bytes: []align(4) u8) !*T {
    const generic_msg: *x.ServerMsg.Generic = @ptrCast(msg_bytes.ptr);
    if (generic_msg.kind != .reply) {
        std.log.err("expected reply but got {}", .{generic_msg});
        return error.UnexpectedReply;
    }
    return @alignCast(@ptrCast(generic_msg));
}

fn readSocket(sock: std.os.socket_t, buffer: []u8) !usize {
    return x.readSock(sock, buffer, 0);
}

/// Sanity check that we're not running into data integrity (corruption) issues caused
/// by overflowing and wrapping around to the front ofq the buffer.
pub fn checkMessageLengthFitsInBuffer(message_length: usize, buffer_limit: usize) !void {
    if (message_length > buffer_limit) {
        std.debug.panic("Reply is bigger than our buffer (data corruption will ensue) {} > {}. In order to fix, increase the buffer size.", .{
            message_length,
            buffer_limit,
        });
    }
}

/// Given a list of picture formats, finds the first one that matches the desired depth.
pub fn findMatchingPictureFormatForDepth(
    formats: []const x.render.PictureFormatInfo,
    desired_depth: u8,
) !x.render.PictureFormatInfo {
    for (formats) |format| {
        if (format.depth != desired_depth) continue;
        return format;
    }
    return error.PictureFormatNotFound;
}

pub fn findMatchingPixmapFormatForDepth(
    formats: []const x.Format,
    desired_depth: u8,
) !x.Format {
    for (formats) |format| {
        if (format.depth != desired_depth) continue;
        return format;
    }
    return error.PixmapFormatNotFound;
}

pub fn getFirstScreenFromConnectionSetup(conn_setup: x.ConnectSetup) *x.Screen {
    const fixed = conn_setup.fixed();

    const format_list_offset = x.ConnectSetup.getFormatListOffset(fixed.vendor_len);
    const format_list_limit = x.ConnectSetup.getFormatListLimit(format_list_offset, fixed.format_count);
    const screen_ptr = conn_setup.getFirstScreenPtr(format_list_limit);

    return screen_ptr;
}

pub fn getPixmapFormatsFromConnectionSetup(conn_setup: x.ConnectSetup) ![]const x.Format {
    const fixed = conn_setup.fixed();

    const format_list_offset = x.ConnectSetup.getFormatListOffset(fixed.vendor_len);
    const format_list_limit = x.ConnectSetup.getFormatListLimit(format_list_offset, fixed.format_count);
    const pixmap_formats = try conn_setup.getFormatList(format_list_offset, format_list_limit);

    return pixmap_formats;
}

/// Returns the number of bytes required to store the image data in a PutImage request.
pub fn getPutImageDataLenBytes(
    width: usize,
    height: usize,
    format: x.Format,
) usize {
    const bytes_per_pixel = format.bits_per_pixel / 8;
    const scanline_len = std.mem.alignForward(
        u16,
        @as(u16, @intCast(bytes_per_pixel * width)),
        format.scanline_pad / 8,
    );
    const data_len_bytes = height * scanline_len;

    return data_len_bytes;
}
