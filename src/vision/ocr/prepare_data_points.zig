const std = @import("std");
const neural_networks = @import("zig-neural-networks");
const DataPoint = neural_networks.DataPoint;
const image_conversion = @import("../image_conversion.zig");
const RGBImage = image_conversion.RGBImage;
const halo_text_vision = @import("../halo_text_vision.zig");
const MAX_NUM_AMMO_CHARACTERS = halo_text_vision.MAX_NUM_AMMO_CHARACTERS;
const findHaloAmmoDigits = halo_text_vision.findHaloAmmoDigits;
const IsolateDiagnostics = halo_text_vision.IsolateDiagnostics;
const print_utils = @import("../../utils/print_utils.zig");
const printLabeledImage = print_utils.printLabeledImage;

pub const DigitLabel = enum(u8) {
    zero = 0,
    one = 1,
    two = 2,
    three = 3,
    four = 4,
    five = 5,
    six = 6,
    seven = 7,
    eight = 8,
    nine = 9,
};
pub const one_hot_digit_label_map = neural_networks.convertLabelEnumToOneHotEncodedEnumMap(DigitLabel);

pub const NeuralNetworkData = struct {
    training_data_points: []DataPoint,
    testing_data_points: []DataPoint,
};

pub fn getExpectedDigitsFromFileName(file_name: []const u8) ![]const u4 {
    // ex. "26 - streets.png" (digits: 2, 6)
    // ex. "_ - breaker ghost.png" (no digits)
    var number_of_digits: usize = 0;
    var digit_accumulator: [MAX_NUM_AMMO_CHARACTERS]u4 = undefined;
    for (file_name, 0..) |character, character_index| {
        // If the first character is an underscore, no digits are expected (a control image)
        const no_digits_expected = (character == '_' and character_index == 0);
        // If we hit a space or the file extension, no more digits are expected
        const no_more_digits = (character == ' ' or character == '.') and character_index > 0;
        if (no_digits_expected or no_more_digits) {
            return digit_accumulator[0..number_of_digits];
        }

        digit_accumulator[number_of_digits] = @intCast(try std.fmt.charToDigit(character, 10));
        number_of_digits += 1;
    }

    // A valid file name should never reach this point
    return error.InvalidFileName;
}

test "getExpectedDigitsFromFileName" {
    try std.testing.expectEqualSlices(
        u4,
        &[_]u4{ 2, 6 },
        try getExpectedDigitsFromFileName("26 - streets.png"),
    );

    try std.testing.expectEqualSlices(
        u4,
        &[_]u4{ 1, 6, 3 },
        try getExpectedDigitsFromFileName("163.png"),
    );

    try std.testing.expectEqualSlices(
        u4,
        &[_]u4{},
        try getExpectedDigitsFromFileName("_ - streets.png"),
    );

    try std.testing.expectError(
        error.InvalidCharacter,
        getExpectedDigitsFromFileName("streets.png"),
    );

    try std.testing.expectError(
        error.InvalidCharacter,
        getExpectedDigitsFromFileName("fff - streets.png"),
    );

    try std.testing.expectError(
        error.InvalidCharacter,
        getExpectedDigitsFromFileName("12streets.png"),
    );
}

pub fn getHaloAmmoCounterTrainingPoints(allocator: std.mem.Allocator) !NeuralNetworkData {
    // const screenshot_dir_path = "./screenshot-data/halo-infinite/4k/default/";
    const screenshot_dir_path = "./screenshot-data/halo-infinite/1080/default/";
    var iterable_dir = try std.fs.cwd().openIterableDir(screenshot_dir_path, .{});
    defer iterable_dir.close();

    var it = iterable_dir.iterate();
    file_blk: while (try it.next()) |entry| {
        switch (entry.kind) {
            .file, .sym_link => {
                const full_file_path = try std.fs.path.join(allocator, &.{
                    screenshot_dir_path,
                    entry.name,
                });
                defer allocator.free(full_file_path);
                std.log.debug("entry.name={s} {s}", .{ entry.name, full_file_path });
                const file_stem_name = std.fs.path.stem(entry.name);

                const expected_digits = try getExpectedDigitsFromFileName(entry.name);

                // TODO: Handle special "no ammo" cases
                if (expected_digits.len == 0) {
                    continue :file_blk;
                }

                // TODO: Handle zero ("0") padded digits
                if (expected_digits[0] == 0) {
                    continue :file_blk;
                }

                // TODO: Handle red digits
                // (string includes/contains substring)
                if (std.mem.indexOf(u8, entry.name, "(red)")) |_| {
                    continue :file_blk;
                }

                const rgb_image = try RGBImage.loadImageFromFilePath(full_file_path, allocator);
                defer rgb_image.deinit(allocator);

                var isolate_diagnostics = IsolateDiagnostics.init(allocator);
                defer isolate_diagnostics.deinit(allocator);
                const maybe_results = try findHaloAmmoDigits(
                    .{
                        .image = rgb_image,
                        .crop_region = .full_screen,
                        .crop_region_x = 0,
                        .crop_region_y = 0,
                        // Since these are full screen images, the pre_crop_width and
                        // pre_crop_height are the same as the width and height
                        .pre_crop_width = rgb_image.width,
                        .pre_crop_height = rgb_image.height,
                        // These are 1:1 screenshots, so the game resolution is the same
                        // as the image resolution
                        .game_resolution_width = rgb_image.width,
                        .game_resolution_height = rgb_image.height,
                    },
                    &isolate_diagnostics,
                    allocator,
                );
                if (maybe_results) |find_results| {
                    const ammo_cropped_digits = find_results.digit_images;
                    defer {
                        for (ammo_cropped_digits) |ammo_cropped_digit| {
                            ammo_cropped_digit.deinit(allocator);
                        }
                        allocator.free(ammo_cropped_digits);
                    }

                    if (ammo_cropped_digits.len != expected_digits.len) {
                        // Debug: Show what happened during the isolation process
                        for (isolate_diagnostics.images.keys(), isolate_diagnostics.images.values(), 0..) |label, image, image_index| {
                            const debug_file_name = try std.fmt.allocPrint(allocator, "{s} - step{}: {s}.png", .{
                                file_stem_name,
                                image_index,
                                label,
                            });
                            defer allocator.free(debug_file_name);
                            const debug_full_file_path = try std.fs.path.join(allocator, &.{
                                "debug/",
                                screenshot_dir_path,
                                debug_file_name,
                            });
                            defer allocator.free(debug_full_file_path);

                            try image.saveImageToFilePath(debug_full_file_path, allocator);
                            // try printLabeledImage(debug_file_name, image, .kitty, allocator);
                        }
                    }

                    // Show the ammo counter digits that were found
                    for (ammo_cropped_digits, 0..) |ammo_cropped_digit, digit_index| {
                        const digit_label = try std.fmt.allocPrint(allocator, "Digit {}", .{digit_index});
                        defer allocator.free(digit_label);
                        try printLabeledImage(digit_label, ammo_cropped_digit, .half_block, allocator);
                    }
                }
            },
            else => continue,
        }
    }

    return .{
        .training_data_points = &.{},
        .testing_data_points = &.{},
    };
}
