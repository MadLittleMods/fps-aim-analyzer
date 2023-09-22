const render_utils = @import("render_utils.zig");

/// Holds the overall state of the application. In an ideal world, this would be
/// everything to reproduce the exact way the application looks at any given time.
pub const AppState = struct {
    root_screen_dimensions: render_utils.Dimensions,
    window_dimensions: render_utils.Dimensions,
    screenshot_capture_dimensions: render_utils.Dimensions,
    max_screenshots_shown: u8,
    current_screenshot_index: u8 = 0,
    margin: i16,
    padding: i16,

    mouse_x: i16 = 0,
};
