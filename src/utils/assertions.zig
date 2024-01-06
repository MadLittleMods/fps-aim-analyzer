const std = @import("std");

pub fn comptime_assert(
    /// Condition to assert
    ok: bool,
    /// Whatever would make the assertion failure easier to understand
    diagnostic_value: anytype,
) void {
    if (!ok) {
        @compileLog(diagnostic_value);
        @compileError("comptime_assert failed");
    }
}

/// Test assertion with custom message
pub fn assert(ok: bool, msg: []const u8, args: anytype) void {
    if (!ok) {
        std.debug.print(msg, args);
        // assertion failure
        unreachable;
    }
}

/// `std.math.approxEqAbs` but with support for `comptime_float`
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
