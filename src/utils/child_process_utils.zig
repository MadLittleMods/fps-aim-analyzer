const std = @import("std");
const builtin = @import("builtin");
const assertions = @import("assertions.zig");
const assert = assertions.assert;
const string_utils = @import("string_utils.zig");

pub const ChildOutput = struct {
    child_process: *const std.ChildProcess,
    // Because the `std.ChildProcess.id` becomes `undefined` after calling `wait()`, we
    // need to store this separately to make sure we've cleaned up properly.
    child_process_id: std.ChildProcess.Id,
    stdout: *std.ArrayList(u8),
    stderr: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    /// The process must be started with `stdout_behavior` and `stderr_behavior` set to `.Pipe`
    /// ```
    /// child_process.stdout_behavior = .Pipe;
    /// child_process.stderr_behavior = .Pipe;
    /// ```
    fn init(child_process: *const std.ChildProcess, allocator: std.mem.Allocator) !ChildOutput {
        assert(
            child_process.stdout_behavior == .Pipe,
            "child_process.stdout_behavior must be set to .Pipe but saw {}",
            .{child_process.stdout_behavior},
        );
        assert(
            child_process.stderr_behavior == .Pipe,
            "child_process.stderr_behavior must be set to .Pipe {}",
            .{child_process.stderr_behavior},
        );

        var stdout = try allocator.create(std.ArrayList(u8));
        stdout.* = std.ArrayList(u8).init(allocator);

        var stderr = try allocator.create(std.ArrayList(u8));
        stderr.* = std.ArrayList(u8).init(allocator);

        return .{
            .child_process = child_process,
            .child_process_id = child_process.id,
            .stdout = stdout,
            .stderr = stderr,
            .allocator = allocator,
        };
    }

    fn deinit(self: @This()) void {
        // Make sure the process has exited by this point. Because of the quirky way
        // that `std.ChildProcess.collectOutput(...)` works, it treats `stdout` and
        // `stderr` as output parameters which also get overwritten once all of the
        // output has been collected (in most cases, that's when the process exits). We
        // don't want to deinit the `ChildOutput` and then have `stdout` and `stderr`
        // get replaced which will leak because we thought we already cleaned up.
        //
        // See https://github.com/ziglang/zig/issues/20952 for notes on how awkward this
        // is.
        const term = checkCurrentStatusOfProcess(self.child_process_id);
        assert(
            term != .Running,
            "Expected child process to be no longer running by the time we deinit the" ++
                "`ChildOutput` to avoid memory leaks of `stdout` and `stderr`",
            .{},
        );

        self.stdout.deinit();
        self.stderr.deinit();

        self.allocator.destroy(self.stdout);
        self.allocator.destroy(self.stderr);
    }

    /// Collect the output text from a child process (stdout and stderr).
    ///
    /// `stdout` and `stderr` are only filled once once all output has been collected
    /// (in most cases, that's when the process exits).
    fn collectOutputFromChildProcess(self: *@This()) void {
        self.child_process.collectOutput(
            self.stdout,
            self.stderr,
            std.math.maxInt(usize),
        ) catch |err| {
            // Add a placeholder in `stderr` that we failed to collect the logs. This is
            // the most obvious way I can think to communicate this to the user but
            // feels a bit indirect.
            const error_message = std.fmt.allocPrint(
                self.allocator,
                "<Failed to collect output from child process: {}>\n",
                .{err},
            ) catch |allocation_err| {
                // We will give up and just log if we're down to allocation errors
                std.log.err("ChildOutput: Failed to format error message: {} after encountering {}\n", .{ allocation_err, err });
                return;
            };
            defer self.allocator.free(error_message);

            self.stderr.appendSlice(error_message) catch |allocation_err| {
                // We will give up and just log if we're down to allocation errors
                std.log.err("ChildOutput: Failed to append to stderr: {} after encountering {}\n", .{ allocation_err, err });
            };
        };
    }
};

/// Print some debug logs of what the child process printed out (stdout and stderr).
pub fn printChildOutput(child_output: *const ChildOutput, allocator: std.mem.Allocator) !void {
    const stdout_separator_spacer = try string_utils.repeatString(
        "=",
        try string_utils.findLengthOfPrintedValue(child_output.stdout.items.len, "{d}", allocator),
        allocator,
    );
    defer allocator.free(stdout_separator_spacer);
    std.debug.print("================= stdout start ({d}) =================\n{s}\n================= stdout end {s}======================\n\n", .{
        child_output.stdout.items.len,
        child_output.stdout.items,
        stdout_separator_spacer,
    });

    const stderr_separator_spacer = try string_utils.repeatString(
        "=",
        try string_utils.findLengthOfPrintedValue(child_output.stderr.items.len, "{d}", allocator),
        allocator,
    );
    defer allocator.free(stderr_separator_spacer);
    std.debug.print("================= stderr start ({d}) =================\n{s}\n================= stderr end {s}======================\n\n", .{
        child_output.stderr.items.len,
        child_output.stderr.items,
        stderr_separator_spacer,
    });
}

pub const Term = union(enum) {
    Running: void,
    Exited: u8,
    Signal: u32,
    Stopped: u32,
    Unknown: u32,
    NotFound: void,
};

/// Check the current status of a process without blocking.
///
/// Good for checking if a process is still running, or not.
pub fn checkCurrentStatusOfProcess(pid: std.os.pid_t) Term {
    const term = waitpid(
        pid,
        // We specify `NOHANG` so we don't block and wait for a signal change. We
        // just want to check the state as it is now.
        std.os.W.NOHANG,
    );

    return term;
}

/// Modified version of `std.os.waitpid` so we can handle "still running" and "not
/// found" cases (more friendly to work with).
fn waitpid(pid: std.os.pid_t, flags: u32) Term {
    const Status = if (builtin.link_libc) c_int else u32;
    var status: Status = undefined;
    const coerced_flags = if (builtin.link_libc) @as(c_int, @intCast(flags)) else flags;
    while (true) {
        const rc = std.os.system.waitpid(pid, &status, coerced_flags);
        switch (std.os.errno(rc)) {
            // If `pid` is 0, the process is still running (no state change yet)
            .SUCCESS => {
                const wait_result = std.os.WaitPidResult{
                    .pid = @as(std.os.pid_t, @intCast(rc)),
                    .status = @as(u32, @bitCast(status)),
                };

                // If `pid` is 0, the process is still running (no state change yet)
                if (wait_result.pid == 0) {
                    return Term.Running;
                } else {
                    return statusToTerm(wait_result.status);
                }
            },
            .INTR => continue,
            // The process specified does not exist.
            .CHILD => return Term.NotFound,
            .INVAL => unreachable, // Invalid flags.
            else => unreachable,
        }
    }
}

// via`std.ChildProcess.statusToTerm`
fn statusToTerm(status: u32) Term {
    return if (std.os.W.IFEXITED(status))
        .{ .Exited = std.os.W.EXITSTATUS(status) }
    else if (std.os.W.IFSIGNALED(status))
        .{ .Signal = std.os.W.TERMSIG(status) }
    else if (std.os.W.IFSTOPPED(status))
        .{ .Stopped = std.os.W.STOPSIG(status) }
    else
        .{ .Unknown = status };
}

/// Wrapper around ChildProcess that can handle collecting logs and some utilities for
/// working with X11 applications.
pub const ChildProcessRunner = struct {
    description: []const u8,
    child_output: *ChildOutput,
    child_process: *std.ChildProcess,
    collect_logs_thread: std.Thread,
    allocator: std.mem.Allocator,

    pub fn init(
        description: []const u8,
        argv: []const []const u8,
        allocator: std.mem.Allocator,
    ) !@This() {
        var child_process = try allocator.create(std.ChildProcess);
        child_process.* = std.ChildProcess.init(argv, allocator);
        // The default behavior is `.Inherit` which will muddy up test runner `stdout`
        // and make the test runner hang, see
        // https://github.com/ziglang/zig/issues/15091
        //
        // We set `stdout` and `stderr` to `.Pipe` so we can see the output if the build
        // fails.
        child_process.stdin_behavior = .Ignore;
        child_process.stdout_behavior = .Pipe;
        child_process.stderr_behavior = .Pipe;

        // Start the test_window process.
        try child_process.spawn();

        // Start collecting logs
        var child_output = try allocator.create(ChildOutput);
        child_output.* = try ChildOutput.init(child_process, allocator);
        // We expect this thread to finish when it's done collecting logs (when the
        // process exits).
        const collect_logs_thread = try std.Thread.spawn(.{}, ChildOutput.collectOutputFromChildProcess, .{child_output});

        return .{
            .description = description,
            .child_output = child_output,
            .child_process = child_process,
            .collect_logs_thread = collect_logs_thread,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: @This()) void {
        // Kill the process when we're done
        _ = self.child_process.kill() catch |err| {
            std.debug.print("Failed to kill {s}: {}\n", .{ self.description, err });
        };
        self.allocator.destroy(self.child_process);

        // The thread should finish gracefully after the process exits. This makes sure
        // that the `ChildOutput.collectOutputFromChildProcess` finishes up replacing
        // `stdout` and `stderr` before we clean them up with the `ChildOutput.deinit`
        // below.
        self.collect_logs_thread.join();

        // Now that the process exited, the `child_output.sdout` and
        // `child_output.stderr` should have been replaced and we can clean up safely
        // (there is also some sanity check logic in `ChildOutput.deinit` to make sure).
        self.child_output.deinit();
        self.allocator.destroy(self.child_output);
    }

    pub fn waitForProcessToExitSuccessfully(self: *@This()) !void {
        const term = try self.child_process.wait();
        std.testing.expectEqual(std.ChildProcess.Term{ .Exited = 0 }, term) catch |err| {
            // Give some more context on the failure
            std.debug.print("{s} failed to exit and finish successfully\n", .{self.description});
            try printChildOutput(self.child_output, self.allocator);

            // Return the original assertion error
            return err;
        };
    }
};
