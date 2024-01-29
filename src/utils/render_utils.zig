const std = @import("std");

pub const Dimensions = struct {
    width: i16,
    height: i16,
};

pub fn BoundingClientRect(comptime NumberType: type) type {
    return struct {
        x: NumberType,
        y: NumberType,
        width: NumberType,
        height: NumberType,

        pub fn top(self: @This()) NumberType {
            return self.y;
        }
        pub fn left(self: @This()) NumberType {
            return self.x;
        }
        pub fn bottom(self: @This()) NumberType {
            return self.y + self.height;
        }
        pub fn right(self: @This()) NumberType {
            return self.x + self.width;
        }
    };
}
/// Find the intersection region between two BoundingClientRect's.
pub fn findIntersection(rect1: anytype, rect2: @TypeOf(rect1)) ?@TypeOf(rect1) {
    const x = @max(rect1.left(), rect2.left());
    const x_overlap = @min(rect1.right(), rect2.right()) - x;
    const y = @max(rect1.top(), rect2.top());
    const y_overlap = @min(rect1.bottom(), rect2.bottom()) - y;

    if (x_overlap >= 0 and y_overlap >= 0) {
        return .{
            .x = x,
            .y = y,
            .width = x_overlap,
            .height = y_overlap,
        };
    }

    return null;
}

test "findIntersection" {
    // Intersection
    try std.testing.expectEqual(findIntersection(
        BoundingClientRect(f32){
            .x = 1.0,
            .y = 1.0,
            .width = 2.0,
            .height = 2.0,
        },
        BoundingClientRect(f32){
            .x = 2,
            .y = 2,
            .width = 2.0,
            .height = 2.0,
        },
    ), .{
        .x = 2.0,
        .y = 2.0,
        .width = 1.0,
        .height = 1.0,
    });

    // No intersection
    try std.testing.expectEqual(findIntersection(
        BoundingClientRect(f32){
            .x = 1.0,
            .y = 1.0,
            .width = 2.0,
            .height = 2.0,
        },
        BoundingClientRect(f32){
            .x = 6.0,
            .y = 1.0,
            .width = 2.0,
            .height = 2.0,
        },
    ), null);
}
