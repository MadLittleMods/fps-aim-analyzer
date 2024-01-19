pub const Dimensions = struct {
    width: i16,
    height: i16,
};

pub const BoundingClientRect = struct {
    x: i16,
    y: i16,
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
