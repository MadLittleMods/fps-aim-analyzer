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
            return self.y + self.dimensions.height;
        }
        pub fn right(self: @This()) NumberType {
            return self.x + self.dimensions.width;
        }
    };
}
