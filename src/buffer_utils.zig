const std = @import("std");

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
