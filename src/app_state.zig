const render_utils = @import("render_utils.zig");

/// Holds the overall state of the application. In an ideal world, this would be
/// everything to reproduce the exact way the application looks at any given time.
pub const AppState = struct {
    /// The pixel dimensions of the screen/monitor
    root_screen_dimensions: render_utils.Dimensions,
    /// The pixel dimensions of our window
    window_dimensions: render_utils.Dimensions,
    /// The pixel dimensions of how big each screenshot capture should be.
    screenshot_capture_dimensions: render_utils.Dimensions,

    /// The max number of screenshots that will be stored and displayed.
    max_screenshots_shown: u8,
    /// The index of the next screenshot to be taken. This is used to determine
    /// the stack position in the pixmap to copy to. And the index before represents
    /// the most recent screenshot taken.
    next_screenshot_index: u8 = 0,

    /// The margin space around the window from the edge of the screen.
    margin: i16,
    /// The amount of spacing between each screenshot.
    padding: i16,

    last_click_ts: u32 = 0,

    /// The current mouse position relative to the window.
    mouse_x: i16 = 0,
};
