const rtc = @import("libdatachannel");
const testing = @import("std").testing;

const PeerUserPointer = struct {};
const TrackUserPointer = struct {};

test "PeerConnection, DataChannel and Track isOpen/isClosed" {
    rtc.preload();
    defer rtc.cleanup();

    // NOTE: If more than one test calls this, it can eventually deadlock as its not thread-safe.
    rtc.initLogger(.none, null);

    var valid_peer_connection: rtc.PeerConnection(void) = try .create({}, .{});
    try testing.expect(valid_peer_connection.isInvalidOrDestroyed());
    valid_peer_connection.destroy();
    try testing.expect(!valid_peer_connection.isInvalidOrDestroyed());

    var invalid_peer_connection: rtc.PeerConnection(void) = @enumFromInt(661);
    try testing.expect(!invalid_peer_connection.isInvalidOrDestroyed());

    var invalid_data_channel: rtc.DataChannel(void) = @enumFromInt(662);
    try testing.expect(!invalid_data_channel.isOpen());
    try testing.expect(!invalid_data_channel.isClosed());

    var invalid_track: rtc.Track(void) = @enumFromInt(663);
    try testing.expect(!invalid_track.isOpen());
    try testing.expect(!invalid_track.isClosed());
}

test "PeerConnection void type promotion" {
    rtc.preload();
    defer rtc.cleanup();

    // Create PeerConnection with no user pointer (void)
    const vpc = try rtc.PeerConnection(void).create({}, .{});
    defer vpc.destroy();

    // Update user pointer to new type
    var peer: PeerUserPointer = .{};
    const pc = vpc.setUserPointer(PeerUserPointer, &peer);
    // pc.destroy(); // vpc.destroy() handles this logic

    // Create a new track (inherits PeerConnection user pointer)
    const MediaDescription: [:0]const u8 = "video 9 UDP/TLS/RTP/SAVPF\r\n" ++
        "a=mid:video\r\n" ++
        "a=sendonly\r\n";
    const track = try pc.addTrack(MediaDescription);
    defer track.destroy();

    // Update track to different user data type
    var track_data: TrackUserPointer = .{};
    _ = track.setUserPointer(TrackUserPointer, &track_data);
}

// NOTE(jae): 2026-03-29
// Zig currently has no way to test @compileError - https://github.com/ziglang/zig/issues/513
//
// test "PeerConnection disallow other type promotion" {
//     var peer: Peer = undefined;
//     const vpc = try rtc.PeerConnection(Peer).create(&peer, .{});
//     defer vpc.destroy() catch unreachable;
//
//     var peer_two: PeerTwo = undefined;
//     _ = vpc.setUserPointer(PeerTwo, &peer_two);
// }
