const assertions = @import("../utils/assertions.zig");
const assert = assertions.assert;

pub const Dimensions = struct {
    width: i16,
    height: i16,
};

pub const BoundingClientRect = struct {
    point: CanvasPoint,
    dimensions: Dimensions,

    pub fn top(self: @This()) i16 {
        return self.y;
    }
    pub fn left(self: @This()) i16 {
        return self.x;
    }
    pub fn bottom(self: @This()) i16 {
        return self.y + self.dimensions.height;
    }
    pub fn right(self: @This()) i16 {
        return self.x + self.dimensions.width;
    }
};

/// Image coordinate system that allows out of bounds coordinates.
/// Top-left is (0, 0), bottom-right is (width, height).
pub const CanvasPoint = struct {
    x: i16,
    y: i16,

    pub fn stepInDirection(current_point: @This(), step_direction: StepDirection) @This() {
        return CanvasPoint{
            .x = current_point.x + step_direction.x,
            .y = current_point.y + step_direction.y,
        };
    }
};

/// Assumes image coordinate system where the top-left is (0, 0), bottom-right is
/// (width, height)
pub const StepDirection = struct {
    x: i16,
    y: i16,

    pub const Right = StepDirection{ .x = 1, .y = 0 };
    pub const Left = StepDirection{ .x = -1, .y = 0 };
    pub const Up = StepDirection{ .x = 0, .y = -1 };
    pub const Down = StepDirection{ .x = 0, .y = 1 };
};
