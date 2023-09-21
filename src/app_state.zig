const render_utils = @import("render_utils.zig");

/// Holds the overall state of the application. In an ideal world, this would be
/// everything to reproduce the exact way the application looks at any given time.
pub const AppState = struct {
    window_dimensions: render_utils.Dimensions,
    screenshot_capture_dimensions: render_utils.Dimensions,
    mouse_x: i16 = 0,
};
