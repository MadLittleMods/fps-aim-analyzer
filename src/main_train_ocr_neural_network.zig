const std = @import("std");
const neural_networks = @import("zig-neural-networks");
const argmax = neural_networks.argmax;
const argmaxOneHotEncodedValue = neural_networks.argmaxOneHotEncodedValue;
const zigimg = @import("zigimg");
const prepare_data_points = @import("vision/ocr/prepare_data_points.zig");
const save_load_utils = @import("vision/ocr/save_load_utils.zig");
const CustomNoiseLayer = @import("vision/ocr/CustomNoiseLayer.zig");
const image_conversion = @import("vision/image_conversion.zig");
const GrayscaleImage = image_conversion.GrayscaleImage;
const GrayscalePixel = image_conversion.GrayscalePixel;
const convertToRgbImage = image_conversion.convertToRgbImage;
const halo_text_vision = @import("vision/halo_text_vision.zig");
const CHARACTER_CAPTURE_WIDTH = halo_text_vision.CHARACTER_CAPTURE_WIDTH;
const CHARACTER_CAPTURE_HEIGHT = halo_text_vision.CHARACTER_CAPTURE_HEIGHT;
const print_utils = @import("./utils/print_utils.zig");
const printLabeledImage = print_utils.printLabeledImage;

// Set the logging levels
pub const std_options = struct {
    pub const log_level = .debug;

    pub const log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .zig_neural_networks, .level = .debug },
    };
};

const checkpoint_file_name_prefix: []const u8 = "neural_network_checkpoint_epoch_";

const BATCH_SIZE: u32 = 100;
const LEARN_RATE: f64 = 0.05;
const MOMENTUM = 0.9;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer switch (gpa.deinit()) {
        .ok => {},
        .leak => std.log.err("GPA allocator: Memory leak detected", .{}),
    };

    // Argument parsing
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    // `zig build run-train_ocr -- --resume-training-from-last-checkpoint`
    const should_resume = for (args) |arg| {
        if (std.mem.eql(u8, arg, "--resume-training-from-last-checkpoint")) {
            break true;
        }
    } else false;
    const display_failing_test_points = for (args) |arg| {
        if (std.mem.eql(u8, arg, "--display-failing-test-points")) {
            break true;
        }
    } else false;

    // Getting the training/testing data ready
    // =======================================
    //
    const parsed_neural_network_data = try prepare_data_points.getHaloAmmoCounterTrainingPoints(allocator);
    defer parsed_neural_network_data.deinit();
    const neural_network_data = parsed_neural_network_data.value;

    // Neural network
    // =======================================

    // Register the custom layer types we will be using with the library (this is used
    // for deserialization).
    try neural_networks.Layer.registerCustomLayer(CustomNoiseLayer, allocator);
    defer neural_networks.Layer.deinitCustomLayerMap(allocator);

    // Setup the layers we'll be using in our custom neural network.
    //
    // Let's add a custom noise layer to the beginning of the network to to add some
    // variation to each image input which should help reduce overfitting. In the
    // future, we could also add some random scaling, translations, and rotations.
    var custom_noise_layer = try CustomNoiseLayer.init(
        0.01,
        0.75,
        // It's nicer to have a fixed seed so we can reproduce the same results.
        123,
    );
    defer custom_noise_layer.deinit(allocator);
    var dense_layer1 = try neural_networks.DenseLayer.init(
        CHARACTER_CAPTURE_WIDTH * CHARACTER_CAPTURE_HEIGHT,
        100,
        allocator,
    );
    defer dense_layer1.deinit(allocator);
    var activation_layer1 = try neural_networks.ActivationLayer.init(neural_networks.ActivationFunction{
        .elu = .{},
    });
    defer activation_layer1.deinit(allocator);
    var dense_layer2 = try neural_networks.DenseLayer.init(
        100,
        @typeInfo(prepare_data_points.DigitLabel).Enum.fields.len,
        allocator,
    );
    defer dense_layer2.deinit(allocator);
    var activation_layer2 = try neural_networks.ActivationLayer.init(neural_networks.ActivationFunction{
        .soft_max = .{},
    });
    defer activation_layer2.deinit(allocator);

    var base_layers = [_]neural_networks.Layer{
        dense_layer1.layer(),
        activation_layer1.layer(),
        dense_layer2.layer(),
        activation_layer2.layer(),
    };

    // Create the neural network
    var starting_epoch_index: u32 = 0;
    var opt_parsed_neural_network: ?std.json.Parsed(neural_networks.NeuralNetwork) = null;
    var neural_network_for_testing = blk: {
        if (should_resume) {
            const checkpoint_file_info = try save_load_utils.findLatestNeuralNetworkCheckpoint(
                checkpoint_file_name_prefix,
                allocator,
            );
            defer allocator.free(checkpoint_file_info.file_path);
            starting_epoch_index = checkpoint_file_info.epoch_index;

            const parsed_neural_network = try save_load_utils.loadNeuralNetworkCheckpoint(
                checkpoint_file_info.file_path,
                allocator,
            );
            opt_parsed_neural_network = parsed_neural_network;
            break :blk parsed_neural_network.value;
        }

        break :blk try neural_networks.NeuralNetwork.initFromLayers(
            &base_layers,
            neural_networks.CostFunction{ .cross_entropy = .{} },
        );
    };
    defer if (opt_parsed_neural_network) |parsed_neural_network| {
        // Since parsing uses an arena allocator internally, we can just rely on their
        // `deinit()` method to cleanup everything.
        parsed_neural_network.deinit();
    } else {
        neural_network_for_testing.deinit(allocator);
    };

    // Combine the layers specific for training with the layers for testing to create
    // the final network.
    var training_layers = blk: {
        var training_specific_layers = [_]neural_networks.Layer{
            // The CustomNoiseLayer should only be used during training to reduce
            // overfitting. It doesn't make sense to run during testing because we don't
            // want to skew our inputs at all.
            custom_noise_layer.layer(),
        };

        const training_layers = try allocator.alloc(
            neural_networks.Layer,
            neural_network_for_testing.layers.len + training_specific_layers.len,
        );

        var training_layer_index: usize = 0;
        for (training_specific_layers) |layer| {
            training_layers[training_layer_index] = layer;
            training_layer_index += 1;
        }
        for (neural_network_for_testing.layers) |layer| {
            training_layers[training_layer_index] = layer;
            training_layer_index += 1;
        }

        break :blk training_layers;
    };

    var neural_network_for_training = try neural_networks.NeuralNetwork.initFromLayers(
        training_layers,
        neural_networks.CostFunction{ .cross_entropy = .{} },
    );
    defer neural_network_for_training.deinit(allocator);

    if (display_failing_test_points) {
        try displayFailingTestPoints(
            &neural_network_for_testing,
            neural_network_data,
            starting_epoch_index,
            allocator,
        );
    } else {
        try train(
            &neural_network_for_training,
            &neural_network_for_testing,
            neural_network_data,
            starting_epoch_index,
            allocator,
        );
    }
}

pub fn displayFailingTestPoints(
    neural_network_for_testing: *neural_networks.NeuralNetwork,
    neural_network_data: prepare_data_points.NeuralNetworkData,
    current_epoch_index: u32,
    allocator: std.mem.Allocator,
) !void {
    // Do a full cost break-down with all of the test points after each epoch
    const cost = try neural_network_for_testing.cost_many(neural_network_data.testing_data_points, allocator);
    const accuracy = try neural_network_for_testing.getAccuracyAgainstTestingDataPoints(
        neural_network_data.testing_data_points,
        allocator,
    );
    std.log.debug("epoch end {d: <3} {s: >18} -> cost {d}, accuracy with *ALL* test points {d}", .{
        current_epoch_index,
        "",
        cost,
        accuracy,
    });

    for (neural_network_data.testing_data_points, 0..) |*testing_data_point, testing_data_point_index| {
        const outputs = try neural_network_for_testing.calculateOutputs(
            testing_data_point.inputs,
            allocator,
        );
        defer allocator.free(outputs);
        // argmax
        const max_output_index = argmax(outputs);

        // Assume one-hot encoded expected outputs
        const max_expected_outputs_index = try argmaxOneHotEncodedValue(testing_data_point.expected_outputs);

        if (max_output_index == max_expected_outputs_index) {
            continue;
        }

        const grayscale_pixels = try allocator.alloc(GrayscalePixel, testing_data_point.inputs.len);
        defer allocator.free(grayscale_pixels);
        for (testing_data_point.inputs, 0..) |input, input_index| {
            grayscale_pixels[input_index] = GrayscalePixel{
                .value = @floatCast(input),
            };
        }

        const grayscale_image = GrayscaleImage{
            .width = CHARACTER_CAPTURE_WIDTH,
            .height = CHARACTER_CAPTURE_HEIGHT,
            .pixels = grayscale_pixels,
        };
        const rgb_image = try convertToRgbImage(grayscale_image, allocator);
        defer rgb_image.deinit(allocator);
        const label = try std.fmt.allocPrint(allocator, "Wrong: Testing data point {} (expected: {s}) (predicted: {s})", .{
            testing_data_point_index,
            @tagName(@as(prepare_data_points.DigitLabel, @enumFromInt(max_expected_outputs_index))),
            @tagName(@as(prepare_data_points.DigitLabel, @enumFromInt(max_output_index))),
        });
        defer allocator.free(label);
        try printLabeledImage(label, rgb_image, .half_block, allocator);
    }
}

/// Runs the training loop so the neural network can learn, and prints out progress
/// updates as it goes.
pub fn train(
    neural_network_for_training: *neural_networks.NeuralNetwork,
    neural_network_for_testing: *neural_networks.NeuralNetwork,
    neural_network_data: prepare_data_points.NeuralNetworkData,
    starting_epoch_index: u32,
    allocator: std.mem.Allocator,
) !void {
    const start_timestamp_seconds = std.time.timestamp();

    var current_epoch_index: usize = starting_epoch_index;
    while (true) : (current_epoch_index += 1) {
        // We assume the data is already shuffled so we skip shuffling on the first
        // epoch. Using a pre-shuffled dataset also gives us nice reproducible results
        // during the first epoch when trying to debug things  (like gradient checking).
        var shuffled_training_data_points = neural_network_data.training_data_points;
        if (current_epoch_index > 0) {
            // Shuffle the data after each epoch
            shuffled_training_data_points = try neural_networks.shuffleData(
                neural_network_data.training_data_points,
                allocator,
                .{},
            );
        }
        // Skip freeing on the first epoch since we didn't shuffle anything and
        // assumed it was already shuffled.
        defer if (current_epoch_index > 0) {
            allocator.free(shuffled_training_data_points);
        };

        // Split the training data into mini batches so way we can get through learning
        // iterations faster. It does make the learning progress a bit noisy because the
        // cost landscape is a bit different for each batch but it's fast and apparently
        // the noise can even be beneficial in various ways, like for escaping settle
        // points in the cost gradient (ridgelines between two valleys).
        //
        // Instead of "gradient descent" with the full training set where we can take
        // perfect steps downhill, we're using mini batches here (called "stochastic
        // gradient descent") where we take steps that are mostly in the correct
        // direction downhill which is good enough to eventually get us to the minimum.
        var batch_index: u32 = 0;
        while (batch_index < shuffled_training_data_points.len / BATCH_SIZE) : (batch_index += 1) {
            const batch_start_index = batch_index * BATCH_SIZE;
            const batch_end_index = batch_start_index + BATCH_SIZE;
            const training_batch = shuffled_training_data_points[batch_start_index..batch_end_index];

            try neural_network_for_training.learn(
                training_batch,
                LEARN_RATE,
                MOMENTUM,
                allocator,
            );

            // Print out a progress update every so often
            if (batch_index % 5 == 0) {
                const current_timestamp_seconds = std.time.timestamp();
                const runtime_duration_seconds = current_timestamp_seconds - start_timestamp_seconds;

                const cost = try neural_network_for_testing.cost_many(
                    neural_network_data.testing_data_points,
                    allocator,
                );
                const accuracy = try neural_network_for_testing.getAccuracyAgainstTestingDataPoints(
                    neural_network_data.testing_data_points,
                    allocator,
                );
                std.log.debug("epoch {d: <3} batch {d: <3} {s: >12} -> cost {d}, " ++
                    "accuracy with {d} test points {d}", .{
                    current_epoch_index,
                    batch_index,
                    std.fmt.fmtDurationSigned(runtime_duration_seconds * std.time.ns_per_s),
                    cost,
                    neural_network_data.testing_data_points.len,
                    accuracy,
                });
            }
        }

        if (current_epoch_index % 100 == 0 and current_epoch_index > 0) {
            // Do a full cost break-down with all of the test points after each epoch
            const cost = try neural_network_for_testing.cost_many(neural_network_data.testing_data_points, allocator);
            const accuracy = try neural_network_for_testing.getAccuracyAgainstTestingDataPoints(
                neural_network_data.testing_data_points,
                allocator,
            );
            std.log.debug("epoch end {d: <3} {s: >18} -> cost {d}, accuracy with *ALL* test points {d}", .{
                current_epoch_index,
                "",
                cost,
                accuracy,
            });

            try save_load_utils.saveNeuralNetworkCheckpoint(
                neural_network_for_testing,
                checkpoint_file_name_prefix,
                current_epoch_index,
                allocator,
            );
        }
    }
}
