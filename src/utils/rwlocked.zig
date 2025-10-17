const std = @import("std");

pub fn RwLocked(comptime T: type) type {
    return struct {
        lock: std.Thread.RwLock,
        locked_data: T,

        const Self = @This();

        pub const HeldReadLock = struct {
            value: *const T,
            rwlock: *std.Thread.RwLock,

            pub fn release(self: HeldReadLock) void {
                self.rwlock.unlockShared();
            }
        };

        pub const HeldWriteLock = struct {
            value: *T,
            rwlock: *std.Thread.RwLock,

            pub fn release(self: HeldWriteLock) void {
                self.rwlock.unlock();
            }
        };

        pub fn init(data: T) Self {
            return Self{
                .lock = std.Thread.RwLock.init(),
                .locked_data = data,
            };
        }

        pub fn deinit(self: *Self) void {
            self.lock.deinit();
        }

        pub fn acquireRead(self: *Self) HeldReadLock {
            self.rwlock.lockShared();
            return HeldReadLock{
                .value = &self.locked_data,
                .rwlock = &self.rwlock,
            };
        }

        pub fn acquireWrite(self: *Self) HeldWriteLock {
            self.rwlock.lock();
            return HeldWriteLock{
                .value = &self.locked_data,
                .rwlock = &self.rwlock,
            };
        }
    };
}
