const render_utils = @import("utils/render_utils.zig");
const halo_text_vision = @import("vision/halo_text_vision.zig");
const ScreenshotRegion = halo_text_vision.ScreenshotRegion;

/// Holds the overall state of the application. In an ideal world, this would be
/// everything to reproduce the exact way the application looks at any given time.
pub const AppState = struct {
    /// The pixel dimensions of the screen/monitor
    root_screen_dimensions: render_utils.Dimensions,
    /// The pixel dimensions of our window
    window_dimensions: render_utils.Dimensions,
    /// The pixel dimensions of how big each screenshot capture should be.
    screenshot_capture_dimensions: render_utils.Dimensions,

    /// The pixel dimension region of the screen we're looking at to analyze the ammo
    /// counter.
    ammo_counter_bounding_box: render_utils.BoundingClientRect(usize),
    ammo_counter_screenshot_region: ScreenshotRegion,
    ammo_value: u32 = 0,

    /// The ms timestamp of the last time the left mouse button was clicked.
    last_left_click_ts: i64 = 0,

    /// The max number of screenshots that will be stored and displayed.
    max_screenshots_shown: u8,
    /// The index of the next interesting screenshot to use. This is used to determine
    /// the stack position in the pixmap to copy to. And the index before represents the
    /// most recent screenshot taken.
    next_interesting_screenshot_index: u8 = 0,

    /// We keep track the last N number of screenshot requests for the ammo counter. The
    /// request IDs are re-used as we cycle through the ring buffer. We also keep track
    /// of a corresponding index to a screenshot in a pixmap (of the center region).
    ///
    /// This is the size of the ring buffer to use. It should be big enough to store all
    /// of the frames possible that could happen in `INPUT_DELAY_MAX_MS` with a nice
    /// safety margin.
    scratch_ring_buffer_size: u32 = 256,
    /// The next index in the scratch buffer to use.
    next_scratch_index: u32 = 0,

    /// The margin space around the window from the edge of the screen.
    margin: i16,
    /// The amount of spacing between each screenshot.
    padding: i16,

    /// The current mouse position relative to the window.
    mouse_x: i16 = 0,
};
