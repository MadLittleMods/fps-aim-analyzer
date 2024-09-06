const std = @import("std");
const neural_networks = @import("zig-neural-networks");
const argmax = neural_networks.argmax;
const save_load_utils = @import("./save_load_utils.zig");
const render_utils = @import("../../utils/render_utils.zig");
const BoundingClientRect = render_utils.BoundingClientRect;
const image_conversion = @import("../image_conversion.zig");
const RGBImage = image_conversion.RGBImage;
const GrayscaleImage = image_conversion.GrayscaleImage;
const GrayscalePixel = image_conversion.GrayscalePixel;
const rgbToGrayscaleImage = image_conversion.rgbToGrayscaleImage;
const halo_text_vision = @import("../halo_text_vision.zig");
const Screenshot = halo_text_vision.Screenshot;
const findHaloAmmoDigits = halo_text_vision.findHaloAmmoDigits;
const IsolateDiagnostics = halo_text_vision.IsolateDiagnostics;
const prepare_data_points = @import("prepare_data_points.zig");
const DigitLabel = prepare_data_points.DigitLabel;
const prepareAmmoDigitImage = prepare_data_points.prepareAmmoDigitImage;
const convertGrayscaleImageToNeuralNetworkInputs = prepare_data_points.convertGrayscaleImageToNeuralNetworkInputs;

pub const ParsedAmmoResult = struct {
    ammo_value: u32,
    ammo_counter_bounding_box: BoundingClientRect(usize),
    confidence_levels: []const f64,
};

pub const CharacterRecognition = struct {
    parsed_neural_network: std.json.Parsed(neural_networks.NeuralNetwork),

    fn getNeuralNetwork(self: @This()) neural_networks.NeuralNetwork {
        return self.parsed_neural_network.value;
    }

    pub fn init(neural_network_file_path: []const u8, allocator: std.mem.Allocator) !@This() {
        const parsed_neural_network = try save_load_utils.loadNeuralNetworkCheckpoint(
            neural_network_file_path,
            allocator,
        );

        return .{
            .parsed_neural_network = parsed_neural_network,
        };
    }

    pub fn parseDigitImage(
        self: *@This(),
        rgb_image: RGBImage,
        allocator: std.mem.Allocator,
    ) !struct { label: DigitLabel, confidence: f64 } {
        const prepared_grayscale_image = try prepareAmmoDigitImage(rgb_image, "unnamed", allocator);

        const inputs = try convertGrayscaleImageToNeuralNetworkInputs(prepared_grayscale_image, allocator);

        var neural_network = self.getNeuralNetwork();
        const outputs = try neural_network.calculateOutputs(inputs, allocator);
        defer allocator.free(outputs);
        // argmax
        const max_output_index = argmax(outputs);

        const label = @as(DigitLabel, @enumFromInt(max_output_index));

        return .{
            .label = label,
            .confidence = outputs[max_output_index],
        };
    }

    pub fn parseAmmoCounterImage(
        self: *@This(),
        screenshot: Screenshot(RGBImage),
        diagnostics: ?*IsolateDiagnostics,
        allocator: std.mem.Allocator,
    ) !?ParsedAmmoResult {
        // Find where all of the digits are in the image
        const maybe_results = try findHaloAmmoDigits(
            screenshot,
            diagnostics,
            allocator,
        );
        if (maybe_results) |find_results| {
            var character_list = std.ArrayList(u8).init(allocator);
            defer character_list.deinit();
            var confidence_list = std.ArrayList(f64).init(allocator);
            defer confidence_list.deinit();

            const ammo_cropped_digits = find_results.digit_images;
            defer {
                for (ammo_cropped_digits) |ammo_cropped_digit| {
                    ammo_cropped_digit.deinit(allocator);
                }
                allocator.free(ammo_cropped_digits);
            }

            // Put all of the digits together into a single string
            for (ammo_cropped_digits, 0..) |ammo_cropped_digit, ammo_cropped_digit_index| {
                const digit_result = try self.parseDigitImage(
                    ammo_cropped_digit,
                    allocator,
                );
                const label = digit_result.label;
                const confidence = digit_result.confidence;

                switch (label) {
                    .zero, .one, .two, .three, .four, .five, .six, .seven, .eight, .nine => {
                        try character_list.append(
                            std.fmt.digitToChar(
                                @intFromEnum(label),
                                .lower,
                            ),
                        );
                        try confidence_list.append(confidence);
                    },
                    .unknown => {
                        // If we find an unknown digit anywhere besides the last digit,
                        // we should return an error since "34%5" doesn't make sense for
                        // example. (34% does make sense though, so we should allow
                        // that)
                        if (ammo_cropped_digit_index != ammo_cropped_digits.len - 1) {
                            const parsed_ammo_debug_string = try _debugStringFromAmmoCroppedDigits(
                                self,
                                ammo_cropped_digits,
                                allocator,
                            );
                            defer allocator.free(parsed_ammo_debug_string);
                            std.log.err("Unknown digit found in the middle of the ammo counter ({s})", .{
                                parsed_ammo_debug_string,
                            });
                            return error.UnknownDigitFoundInMiddleOfAmmoCounter;
                        }
                    },
                }
            }

            return .{
                .ammo_value = try std.fmt.parseInt(u32, try character_list.toOwnedSlice(), 10),
                .ammo_counter_bounding_box = find_results.ammo_counter_bounding_box,
                .confidence_levels = try confidence_list.toOwnedSlice(),
            };
        }

        return null;
    }

    /// Given a list of cropped ammo digits, return a string representation of the
    /// digits. For example, a list of digit images showing ["3", "4", "%"] would return
    /// "34?"
    fn _debugStringFromAmmoCroppedDigits(
        self: *@This(),
        ammo_cropped_digits: []const RGBImage,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        var character_list = std.ArrayList(u8).init(allocator);

        for (ammo_cropped_digits) |ammo_cropped_digit| {
            const digit_result = try self.parseDigitImage(
                ammo_cropped_digit,
                allocator,
            );
            const label = digit_result.label;
            switch (label) {
                .zero, .one, .two, .three, .four, .five, .six, .seven, .eight, .nine => {
                    try character_list.append(
                        std.fmt.digitToChar(@intFromEnum(label), .lower),
                    );
                },
                .unknown => {
                    try character_list.append('?');
                },
            }
        }

        return character_list.toOwnedSlice();
    }
};
