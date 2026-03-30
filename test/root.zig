//! Run tests

const testing = @import("std").testing;

const rtc = @import("libdatachannel");

comptime {
    _ = @import("capi_track.zig");
    _ = @import("zig_binding.zig");
}

test "run any comptime checks on each field, etc" {
    testing.refAllDecls(rtc);
}
