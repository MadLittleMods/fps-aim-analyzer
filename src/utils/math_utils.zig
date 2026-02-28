pub fn absoluteDifference(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    if (a > b) {
        return a - b;
    } else {
        return b - a;
    }
}
