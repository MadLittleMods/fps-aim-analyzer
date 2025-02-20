const render_utils = @import("../utils/render_utils.zig");

/// Holds the overall state of the application. In an ideal world, this would be
/// everything to reproduce the exact way the application looks at any given time.
pub const AppState = struct {
    /// The pixel dimensions of the screen/monitor
    root_screen_dimensions: render_utils.Dimensions,
    // We don't need transparency (32-bit) for the window or the pixmap
    // since we're just display opaque screenshots.
    window_depth: u8 = 24,
    pixmap_depth: u8 = 24,

    /// The total number of screenshots we show
    num_screenshots: u8,
    /// The current screenshot index to show
    screenshot_index: u8 = 0,
};
