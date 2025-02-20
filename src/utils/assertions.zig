const std = @import("std");

/// Comptime assert with custom message
pub fn comptime_assert(comptime ok: bool, comptime msg: []const u8, args: anytype) void {
    if (!ok) {
        @compileLog(std.fmt.comptimePrint(msg, args));
        @compileError("comptime_assert failed");
    }
}

/// Assert with custom message
pub fn assert(ok: bool, comptime msg: []const u8, args: anytype) void {
    if (std.debug.runtime_safety and !ok) {
        std.debug.panic(msg, args);
        // This alternative doesn't work right (seems like UB given this branch is unreachable)
        // std.debug.print(msg, args);
        // unreachable;
    }
}

/// `std.math.approxEqAbs` but with support for `comptime_float`
///
/// FIXME: This can be removed once https://github.com/ziglang/zig/pull/18463 is merged
/// and we're using a supported version of Zig.
///
/// Performs an approximate comparison of two floating point values `x` and `y`.
/// Returns true if the absolute difference between them is less or equal than
/// the specified tolerance.
///
/// The `tolerance` parameter is the absolute tolerance used when determining if
/// the two numbers are close enough; a good value for this parameter is a small
/// multiple of `floatEps(T)`.
///
/// Note that this function is recommended for comparing small numbers
/// around zero; using `approxEqRel` is suggested otherwise.
///
/// NaN values are never considered equal to any value.
pub fn approxEqAbs(comptime T: type, x: T, y: T, tolerance: T) bool {
    std.debug.assert(@typeInfo(T) == .Float or @typeInfo(T) == .ComptimeFloat);
    std.debug.assert(tolerance >= 0);

    // Fast path for equal values (and signed zeros and infinites).
    if (x == y)
        return true;

    if (std.math.isNan(x) or std.math.isNan(y))
        return false;

    return @fabs(x - y) <= tolerance;
}
