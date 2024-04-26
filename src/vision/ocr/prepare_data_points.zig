const std = @import("std");
const assertions = @import("../../utils/assertions.zig");
const assert = assertions.assert;
const neural_networks = @import("zig-neural-networks");
const DataPoint = neural_networks.DataPoint;
const image_conversion = @import("../image_conversion.zig");
const RGBImage = image_conversion.RGBImage;
const GrayscaleImage = image_conversion.GrayscaleImage;
const GrayscalePixel = image_conversion.GrayscalePixel;
const rgbToGrayscaleImage = image_conversion.rgbToGrayscaleImage;
const overlayImage = image_conversion.overlayImage;
const halo_text_vision = @import("../halo_text_vision.zig");
const MAX_NUM_AMMO_CHARACTERS = halo_text_vision.MAX_NUM_AMMO_CHARACTERS;
const CHARACTER_CAPTURE_WIDTH = halo_text_vision.CHARACTER_CAPTURE_WIDTH;
const CHARACTER_CAPTURE_HEIGHT = halo_text_vision.CHARACTER_CAPTURE_HEIGHT;
const IsolateDiagnostics = halo_text_vision.IsolateDiagnostics;
const process_screenshot_data = @import("./process_screenshot_data.zig");
const getExpectedCharactersFromFileName = process_screenshot_data.getExpectedCharactersFromFileName;
const print_utils = @import("../../utils/print_utils.zig");
const printLabeledImage = print_utils.printLabeledImage;

const TRAINING_DATA_PERCENTAGE = 0.8;

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
    unknown = 10,
};
pub const one_hot_digit_label_map = neural_networks.convertLabelEnumToOneHotEncodedEnumMap(DigitLabel);

pub const NeuralNetworkData = struct {
    training_data_points: []DataPoint,
    testing_data_points: []DataPoint,
};

/// Based on `std.json.Parsed`. Just a good pattern to have everything use an arena
/// allocator and pass a `deinit` function back to free all of the memory.
pub fn Parsed(comptime T: type) type {
    return struct {
        arena: *std.heap.ArenaAllocator,
        value: T,

        pub fn deinit(self: @This()) void {
            const allocator = self.arena.child_allocator;
            self.arena.deinit();
            allocator.destroy(self.arena);
        }
    };
}

const capture_base_black_image = GrayscaleImage{
    .pixels = &[_]GrayscalePixel{.{ .value = 0.0 }} ** (CHARACTER_CAPTURE_WIDTH * CHARACTER_CAPTURE_HEIGHT),
    .width = CHARACTER_CAPTURE_WIDTH,
    .height = CHARACTER_CAPTURE_HEIGHT,
};

pub fn prepareAmmoDigitImage(rgb_image: RGBImage, debug_name: []const u8, allocator: std.mem.Allocator) !GrayscaleImage {
    const grayscale_image = try rgbToGrayscaleImage(rgb_image, allocator);
    defer grayscale_image.deinit(allocator);

    // We can't fix too big and we should never encounter this if they were
    // processed correctly.
    const is_too_big = grayscale_image.width > CHARACTER_CAPTURE_WIDTH or
        grayscale_image.height > CHARACTER_CAPTURE_HEIGHT;
    if (is_too_big) {
        std.log.err("Training digit image {s} is too big to prepare. " ++
            "Found {d}x{d} but expected {d}x{d} or smaller. " ++
            "This is probably a problem with the processing and extraction step.", .{
            debug_name,
            grayscale_image.width,
            grayscale_image.height,
            CHARACTER_CAPTURE_WIDTH,
            CHARACTER_CAPTURE_HEIGHT,
        });
        return error.TrainingDigitImageTooBig;
    }

    // If the image is smaller than what the neural network needs, just pad it out with black pixels
    var sized_grayscale_image = grayscale_image;
    const needs_expansion = grayscale_image.width < CHARACTER_CAPTURE_WIDTH or
        grayscale_image.height < CHARACTER_CAPTURE_HEIGHT;
    if (needs_expansion) {
        const expanded_image = try overlayImage(
            grayscale_image,
            capture_base_black_image,
            0,
            0,
            .left,
            .top,
            allocator,
        );

        sized_grayscale_image = expanded_image;
    }
    defer if (needs_expansion) {
        sized_grayscale_image.deinit(allocator);
    };

    return sized_grayscale_image;
}

pub fn convertGrayscaleImageToNeuralNetworkInputs(
    grayscale_image: GrayscaleImage,
    allocator: std.mem.Allocator,
) ![]const f64 {
    // TODO: We only store colors as f32 so maybe we want to adapt the
    // neural network to use f32 (instead of f64) in this case for better
    // performance? Or maybe the better f64 precision is good for the
    // weights/biases internally?
    const inputs = try allocator.alloc(f64, grayscale_image.pixels.len);
    for (grayscale_image.pixels, 0..) |pixel, i| {
        inputs[i] = @floatCast(pixel.value);
    }

    return inputs;
}

pub fn getHaloAmmoCounterTrainingPoints(allocator: std.mem.Allocator) !Parsed(NeuralNetworkData) {
    var parsed = Parsed(NeuralNetworkData){
        .arena = try allocator.create(std.heap.ArenaAllocator),
        .value = undefined,
    };
    errdefer allocator.destroy(parsed.arena);
    parsed.arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer parsed.arena.deinit();
    // Only use this for things that we are returning
    const parsed_arena_allocator = parsed.arena.allocator();

    const screenshot_dir_path = "./train/";
    var iterable_dir = try std.fs.cwd().openIterableDir(screenshot_dir_path, .{});
    defer iterable_dir.close();

    var training_list = std.ArrayList(DataPoint).init(allocator);
    defer training_list.deinit();
    var testing_list = std.ArrayList(DataPoint).init(allocator);
    defer testing_list.deinit();

    var it = iterable_dir.iterate();
    while (try it.next()) |entry| {
        switch (entry.kind) {
            .file, .sym_link => {
                const full_file_path = try std.fs.path.join(allocator, &.{
                    screenshot_dir_path,
                    entry.name,
                });
                defer allocator.free(full_file_path);

                const rgb_image = try RGBImage.loadImageFromFilePath(full_file_path, allocator);
                defer rgb_image.deinit(allocator);

                const prepared_grayscale_image = try prepareAmmoDigitImage(
                    rgb_image,
                    entry.name,
                    allocator,
                );

                // Get the expected character digit from the file name.
                const expected_characters = try getExpectedCharactersFromFileName(entry.name, allocator);
                defer allocator.free(expected_characters);
                if (expected_characters.len != 1) {
                    std.log.err("Training digits should be isolated to only a single character but we extracted \"{c}\" from {s}", .{
                        expected_characters,
                        entry.name,
                    });
                    return error.TooManyExpecedCharactersInTrainingDigitFileName;
                }

                // Convert the character into a label
                const label: DigitLabel = switch (expected_characters[0]) {
                    '0'...'9' => blk: {
                        const digit_number: u8 = @intCast(try std.fmt.charToDigit(expected_characters[0], 10));
                        break :blk @enumFromInt(digit_number);
                    },
                    else => DigitLabel.unknown,
                };

                const inputs = try convertGrayscaleImageToNeuralNetworkInputs(prepared_grayscale_image, parsed_arena_allocator);

                const data_point = DataPoint.init(
                    inputs,
                    // FIXME: Once https://github.com/ziglang/zig/pull/18112 merges and we support a Zig
                    // version that includes it, we should use `getPtrConstAssertContains(...)` instead.
                    one_hot_digit_label_map.getPtrConst(label).?,
                );

                const string_hash = std.hash.Wyhash.hash(0, entry.name);
                const hash_decimal: f64 = @as(f64, @floatFromInt(string_hash)) /
                    @as(f64, @floatFromInt(std.math.maxInt(u64)));
                if (hash_decimal <= TRAINING_DATA_PERCENTAGE) {
                    try training_list.append(data_point);
                } else {
                    try testing_list.append(data_point);
                }
            },
            else => continue,
        }
    }

    // Sanity check that we have data points to train and test with.
    if (training_list.items.len == 0) {
        return error.NoTrainingDataPoints;
    }

    if (testing_list.items.len == 0) {
        return error.NoTestingDataPoints;
    }

    const actual_training_percentage: f64 = @as(f64, @floatFromInt(training_list.items.len)) /
        @as(f64, @floatFromInt(training_list.items.len + testing_list.items.len));
    if (!std.math.approxEqRel(f64, actual_training_percentage, TRAINING_DATA_PERCENTAGE, 0.05)) {
        std.log.err("Expected training data percentage to be {d} but got {d}", .{
            TRAINING_DATA_PERCENTAGE,
            actual_training_percentage,
        });
        return error.UnexpectedTrainingDataPercentage;
    }

    // Basically, just trying to do a `toOwnedSlice()` but this way allows us to use our
    // own arena allocator. For example, even when using an `ArrayListUmanaged`, you
    // have to use the same allocator (`toOwnedSlice(allocator)`) as what you appended
    // the items. And if we use the arena allocator with the `ArrayList`, then the
    // original list memory will still be around even after we `toOwnedSlice()`.
    const training_data_points = try parsed_arena_allocator.alloc(DataPoint, training_list.items.len);
    @memcpy(training_data_points, training_list.items);
    const testing_data_points = try parsed_arena_allocator.alloc(DataPoint, testing_list.items.len);
    @memcpy(testing_data_points, testing_list.items);

    parsed.value = NeuralNetworkData{
        .training_data_points = training_data_points,
        .testing_data_points = testing_data_points,
    };

    return parsed;
}
