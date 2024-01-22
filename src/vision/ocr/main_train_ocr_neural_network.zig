const std = @import("std");
const neural_networks = @import("zig-neural-networks");
const mnist_data_point_utils = @import("utils/mnist_data_point_utils.zig");
const CustomNoiseLayer = @import("CustomNoiseLayer.zig");

const mnist_main = @import("main.zig");

// Set the logging levels
pub const std_options = struct {
    pub const log_level = .debug;

    pub const log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .zig_neural_networks, .level = .debug },
    };
};

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

    // Getting the training/testing data ready
    // =======================================
    //
    const parsed_mnist_data = try mnist_data_point_utils.getMnistDataPoints(allocator, .{});
    defer parsed_mnist_data.deinit();
    const mnist_data = parsed_mnist_data.value;

    // Neural network
    // =======================================
    //
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
    var dense_layer1 = try neural_networks.DenseLayer.init(784, 100, allocator);
    var activation_layer1 = try neural_networks.ActivationLayer.init(neural_networks.ActivationFunction{
        .elu = .{},
    });
    var dense_layer2 = try neural_networks.DenseLayer.init(100, @typeInfo(mnist_data_point_utils.DigitLabel).Enum.fields.len, allocator);
    var activation_layer2 = try neural_networks.ActivationLayer.init(neural_networks.ActivationFunction{
        .soft_max = .{},
    });

    var base_layers = [_]neural_networks.Layer{
        dense_layer1.layer(),
        activation_layer1.layer(),
        dense_layer2.layer(),
        activation_layer2.layer(),
    };
    var training_layers = [_]neural_networks.Layer{
        // The CustomNoiseLayer should only be used during training to reduce overfitting.
        // It doesn't make sense to run during testing because we don't want to skew our
        // inputs at all.
        custom_noise_layer.layer(),
    } ++ base_layers;
    defer for (&training_layers) |*layer| {
        layer.deinit(allocator);
    };

    var neural_network_for_training = try neural_networks.NeuralNetwork.initFromLayers(
        &training_layers,
        neural_networks.CostFunction{ .cross_entropy = .{} },
    );
    defer neural_network_for_training.deinit(allocator);

    var neural_network_for_testing = try neural_networks.NeuralNetwork.initFromLayers(
        &base_layers,
        neural_networks.CostFunction{ .cross_entropy = .{} },
    );
    defer neural_network_for_testing.deinit(allocator);

    try train(
        &neural_network_for_training,
        &neural_network_for_testing,
        mnist_data,
        0,
        allocator,
    );
}

/// Runs the training loop so the neural network can learn, and prints out progress
/// updates as it goes.
pub fn train(
    neural_network_for_training: *neural_networks.NeuralNetwork,
    neural_network_for_testing: *neural_networks.NeuralNetwork,
    mnist_data: mnist_data_point_utils.NeuralNetworkData,
    starting_epoch_index: u32,
    allocator: std.mem.Allocator,
) !void {
    const start_timestamp_seconds = std.time.timestamp();

    var current_epoch_index: usize = starting_epoch_index;
    while (true) : (current_epoch_index += 1) {
        // We assume the data is already shuffled so we skip shuffling on the first
        // epoch. Using a pre-shuffled dataset also gives us nice reproducible results
        // during the first epoch when trying to debug things  (like gradient checking).
        var shuffled_training_data_points = mnist_data.training_data_points;
        if (current_epoch_index > 0) {
            // Shuffle the data after each epoch
            shuffled_training_data_points = try neural_networks.shuffleData(
                mnist_data.training_data_points,
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
                    mnist_data.testing_data_points[0..NUM_OF_IMAGES_TO_QUICK_TEST_ON],
                    allocator,
                );
                const accuracy = try neural_network_for_testing.getAccuracyAgainstTestingDataPoints(
                    mnist_data.testing_data_points[0..NUM_OF_IMAGES_TO_QUICK_TEST_ON],
                    allocator,
                );
                std.log.debug("epoch {d: <3} batch {d: <3} {s: >12} -> cost {d}, " ++
                    "accuracy with {d} test points {d}", .{
                    current_epoch_index,
                    batch_index,
                    std.fmt.fmtDurationSigned(runtime_duration_seconds * std.time.ns_per_s),
                    cost,
                    NUM_OF_IMAGES_TO_QUICK_TEST_ON,
                    accuracy,
                });
            }
        }

        // Do a full cost break-down with all of the test points after each epoch
        const cost = try neural_network_for_testing.cost_many(mnist_data.testing_data_points, allocator);
        const accuracy = try neural_network_for_testing.getAccuracyAgainstTestingDataPoints(
            mnist_data.testing_data_points,
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
            current_epoch_index,
            allocator,
        );
    }
}
