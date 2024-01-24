const std = @import("std");
const neural_networks = @import("zig-neural-networks");
const DataPoint = neural_networks.DataPoint;
const image_conversion = @import("../image_conversion.zig");
const RGBImage = image_conversion.RGBImage;

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

pub fn getHaloAmmoCounterTrainingPoints(allocator: std.mem.Allocator) !NeuralNetworkData {
    const screenshot_dir_path = "./screenshot-data/halo-infinite/4k/default/";
    var iterable_dir = try std.fs.cwd().openIterableDir(screenshot_dir_path, .{});
    defer iterable_dir.close();

    var it = iterable_dir.iterate();
    while (try it.next()) |entry| {
        switch (entry.kind) {
            .file, .sym_link => {
                const full_file_path = try std.fs.path.join(allocator, &.{
                    screenshot_dir_path,
                    entry.name,
                });
                defer allocator.free(full_file_path);
                std.log.debug("entry.name={s} {s}", .{ entry.name, full_file_path });

                const rgb_image = try RGBImage.loadImageFromFilePath(full_file_path, allocator);
                defer rgb_image.deinit(allocator);
            },
            else => continue,
        }
    }

    return .{
        .training_data_points = &.{},
        .testing_data_points = &.{},
    };
}
