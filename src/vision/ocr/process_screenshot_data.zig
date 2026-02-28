const std = @import("std");
const assertions = @import("../../utils/assertions.zig");
const assert = assertions.assert;
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

/// Given a screenshot file name, extract the expected characters from the file name
/// that represent the ammo counter digits.
pub fn getExpectedCharactersFromFileName(file_name: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    // ex. "26 - streets.png" (digits: '2', '6')
    // ex. "32% - cliffhanger stalker.png" (characters: '3', '2', '%')
    // ex. "_ - breaker ghost.png" (no digits)
    var number_of_digits: usize = 0;
    var character_accumulator: [MAX_NUM_AMMO_CHARACTERS]u8 = undefined;
    for (file_name, 0..) |character, character_index| {
        if (number_of_digits > MAX_NUM_AMMO_CHARACTERS) {
            return error.ExpectedLessAmmoCharacters;
        }

        // If the first character is an underscore, no digits are expected (a control image)
        const no_digits_expected = (character == '_' and character_index == 0);
        // If we hit a space or the file extension, no more digits are expected
        const no_more_digits = (character == ' ' or character == '.') and character_index > 0;
        if (no_digits_expected or no_more_digits) {
            const character_slice = try allocator.alloc(u8, number_of_digits);
            @memcpy(character_slice, character_accumulator[0..number_of_digits]);
            return character_slice;
        }

        switch (character) {
            '0'...'9', '%' => character_accumulator[number_of_digits] = character,
            else => return error.UnableToHandleCharacter,
        }

        number_of_digits += 1;
    }

    // A valid file name should never reach this point
    return error.InvalidFileName;
}

test "getExpectedCharactersFromFileName" {
    const base_allocator = std.testing.allocator;
    var arena_allocator = std.heap.ArenaAllocator.init(base_allocator);
    defer arena_allocator.deinit();
    const allocator = arena_allocator.allocator();

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ '2', '6' },
        try getExpectedCharactersFromFileName("26 - streets.png", allocator),
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ '1', '6', '3' },
        try getExpectedCharactersFromFileName("163.png", allocator),
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ '3', '2', '%' },
        try getExpectedCharactersFromFileName("32% - cliffhanger stalker.png", allocator),
    );

    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{},
        try getExpectedCharactersFromFileName("_ - streets.png", allocator),
    );

    try std.testing.expectError(
        error.UnableToHandleCharacter,
        getExpectedCharactersFromFileName("streets.png", allocator),
    );

    try std.testing.expectError(
        error.UnableToHandleCharacter,
        getExpectedCharactersFromFileName("fff - streets.png", allocator),
    );

    try std.testing.expectError(
        error.UnableToHandleCharacter,
        getExpectedCharactersFromFileName("12streets.png", allocator),
    );
}

/// Take all of the screenshot data and extract the individual digits from the ammo
/// counter to get it ready for training in the neural network.
///
/// This is an operation that only needs to happen once when new screenshots are added.
pub fn processScreenshotData(allocator: std.mem.Allocator) !void {
    const screenshot_directories = [_][]const u8{
        "./screenshot-data/halo-infinite/1080/default/",
        "./screenshot-data/halo-infinite/1080/black/",
        "./screenshot-data/halo-infinite/1080/white/",
        "./screenshot-data/halo-infinite/1080/red/",
        "./screenshot-data/halo-infinite/4k/default/",
        "./screenshot-data/halo-infinite/4k/black/",
        "./screenshot-data/halo-infinite/4k/white/",
    };

    for (screenshot_directories) |screenshot_dir_path| {
        // Generate a small prefix string, ex. "4k default", that we can use when saving
        // the individual digit images in one big directory.
        const directory_descriptor_string = blk: {
            // `./screenshot-data/halo-infinite/4k/white/` -> `4k/white`
            const relative_path = try std.fs.path.relative(
                allocator,
                "./screenshot-data/halo-infinite/",
                screenshot_dir_path,
            );
            defer allocator.free(relative_path);
            var split_iterator = std.mem.splitScalar(u8, relative_path, std.fs.path.sep);

            // We just assume there are only two directory descriptors (the resolution
            // and the type of image like "default" or "black")
            const descriptors = try allocator.alloc([]const u8, 2);
            defer allocator.free(descriptors);
            var descriptor_index: usize = 0;
            while (split_iterator.next()) |descriptor| : (descriptor_index += 1) {
                // Make sure we don't have more than two directory descriptors that we expect
                if (descriptor_index >= descriptors.len) {
                    std.log.err("Expected at most {d} directory descriptors, but found more with this given path {s}", .{
                        descriptors.len,
                        screenshot_dir_path,
                    });
                    return error.TooManyDirectoryDescriptors;
                }

                descriptors[descriptor_index] = descriptor;
            }

            // Combine the descriptors into a space separated string
            const directory_descriptor_string = try std.mem.join(
                allocator,
                " ",
                descriptors,
            );

            break :blk directory_descriptor_string;
        };
        defer allocator.free(directory_descriptor_string);

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

                    const expected_characters = try getExpectedCharactersFromFileName(entry.name, allocator);
                    defer allocator.free(expected_characters);

                    // TODO: Handle special "no ammo" cases
                    if (expected_characters.len == 0) {
                        continue :file_blk;
                    }

                    // TODO: Handle zero ("0") padded digits
                    if (expected_characters[0] == '0') {
                        continue :file_blk;
                    }

                    // TODO: Handle red digits
                    // (string includes/contains substring)
                    if (std.mem.indexOf(u8, entry.name, "(red)")) |_| {
                        continue :file_blk;
                    }
                    // TODO: Handle obstructed digits
                    if (std.mem.indexOf(u8, entry.name, "camo marker")) |_| {
                        continue :file_blk;
                    }

                    const files_to_ignore = [_][]const u8{
                        // TODO: Handle dim ammo counter when switching weapons
                        "screenshot-data/halo-infinite/4k/default/12 - cliffhanger switching weapons.png",
                        // TODO: Handle more false positive patterns
                        "screenshot-data/halo-infinite/4k/default/13 - streets burger.png",
                        "screenshot-data/halo-infinite/4k/default/16 - streets burger.png",
                        "screenshot-data/halo-infinite/4k/default/18 - streets burger.png",
                        "screenshot-data/halo-infinite/4k/default/21 - streets burger.png",
                        "screenshot-data/halo-infinite/4k/default/23 - streets burger.png",
                        "screenshot-data/halo-infinite/4k/default/25 - streets burger.png",
                        "screenshot-data/halo-infinite/4k/default/27 - streets burger.png",
                        // TODO: Handle really weird UI margins
                        "screenshot-data/halo-infinite/4k/default/35 - the pit 100 UI margin.png",
                        "screenshot-data/halo-infinite/4k/default/35 - the pit 100 UI margin2.png",
                        "screenshot-data/halo-infinite/4k/default/35 - the pit 100 UI margin3.png",
                        "screenshot-data/halo-infinite/4k/default/35 - the pit threat seeker 100 UI margin.png",
                        "screenshot-data/halo-infinite/4k/default/36 - the pit 100 UI margin2.png",
                        "screenshot-data/halo-infinite/4k/default/36 - the pit threat seeker 100 UI margin.png",
                    };
                    for (files_to_ignore) |file_to_ignore| {
                        if (std.mem.indexOf(u8, full_file_path, file_to_ignore)) |_| {
                            continue :file_blk;
                        }
                    }

                    const rgb_image = try RGBImage.loadImageFromFilePath(full_file_path, allocator);
                    defer rgb_image.deinit(allocator);

                    var isolate_diagnostics = IsolateDiagnostics.init(allocator);
                    defer isolate_diagnostics.deinit(allocator);

                    _ = blk: {
                        const maybe_results = findHaloAmmoDigits(
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
                        ) catch |err| break :blk err;
                        if (maybe_results) |find_results| {
                            const ammo_cropped_digits = find_results.digit_images;
                            defer {
                                for (ammo_cropped_digits) |ammo_cropped_digit| {
                                    ammo_cropped_digit.deinit(allocator);
                                }
                                allocator.free(ammo_cropped_digits);
                            }
                            // Show the ammo counter digits that were found
                            for (ammo_cropped_digits, 0..) |ammo_cropped_digit, digit_index| {
                                const digit_label = try std.fmt.allocPrint(allocator, "Digit {}", .{digit_index});
                                defer allocator.free(digit_label);
                                try printLabeledImage(digit_label, ammo_cropped_digit, .half_block, allocator);
                            }

                            const expected_number_of_number_digits: usize = digit_blk: {
                                var num: usize = 0;
                                for (expected_characters) |expected_character| {
                                    switch (expected_character) {
                                        '0'...'9' => num += 1,
                                        else => num += 0,
                                    }
                                }
                                break :digit_blk num;
                            };

                            const matches_number_digits = ammo_cropped_digits.len == expected_number_of_number_digits;
                            const matches_expected_characters = ammo_cropped_digits.len == expected_characters.len;

                            // Let's just be lenient. If we find just the numbers we're
                            // looking for, good enough, if we find all characters,  that's
                            // also fine.
                            if (!(matches_number_digits or matches_expected_characters)) {
                                std.log.err("Expected {} (only numbers) or {} (all) digits, but found {}", .{
                                    expected_number_of_number_digits,
                                    expected_characters.len,
                                    ammo_cropped_digits.len,
                                });
                                break :blk error.FoundIncorrectNumberOfDigits;
                            }

                            // Save out all of the digits invidually so they're
                            // available to review and train on
                            for (ammo_cropped_digits, 0..) |ammo_cropped_digit, digit_index| {
                                const expected_character = expected_characters[digit_index];

                                const digit_file_name = try std.fmt.allocPrint(allocator, "{c} - {s} - {s}", .{
                                    expected_character,
                                    directory_descriptor_string,
                                    entry.name,
                                });
                                defer allocator.free(digit_file_name);
                                const digit_file_path = try std.fs.path.join(allocator, &.{
                                    "./train/",
                                    digit_file_name,
                                });
                                defer allocator.free(digit_file_path);
                                try ammo_cropped_digit.saveImageToFilePath(digit_file_path, allocator);
                            }
                        }
                    } catch |err| {
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
                            // For small images, make it easier to pixel peep
                            if (image.width < 200 and image.height < 200) {
                                try printLabeledImage(debug_full_file_path, image, .half_block, allocator);
                            } else {
                                try printLabeledImage(debug_full_file_path, image, .kitty, allocator);
                            }
                        }

                        return err;
                    };
                },
                else => continue :file_blk,
            }
        }
    }
}
