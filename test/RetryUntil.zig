//! RetryUntil

const Io = @import("std").Io;
const testing = @import("std").testing;
const builtin = @import("builtin");

io: Io,
failed_attempts: u32,

pub const Options = struct {};

pub const CheckError = Io.Cancelable || error{ExhaustedAttempts};

pub fn init(io: Io, _: Options) RetryWait {
    return .{
        .io = io,
        .failed_attempts = 40,
    };
}

/// Run in a while loop
///
/// ie. while (try retryer.check(peer1.gathering_state != .complete and peer1.signalling_state != .have_local_offer))
pub fn check(self: *RetryWait, success_condition: bool) CheckError!bool {
    if (success_condition) {
        return false;
    }
    self.failed_attempts -= 1;

    if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15) {
        // Deprecated path: Zig 0.15.X or lower
        @import("std").Thread.sleep(250 * 1000000);
    } else {
        try self.io.sleep(.fromMilliseconds(250), .boot);
    }

    if (self.failed_attempts == 0) {
        return error.ExhaustedAttempts;
    }
    return true;
}

const RetryWait = @This();
