const rtc = @import("libdatachannel");

const PeerUserPointer = struct {};
const TrackUserPointer = struct {};

const MediaDescription: [:0]const u8 = "video 9 UDP/TLS/RTP/SAVPF\r\n" ++
    "a=mid:video\r\n" ++
    "a=sendonly\r\n";

test "PeerConnection void type promotion" {
    // Create PeerConnection with no user pointer (void)
    const vpc = try rtc.PeerConnection(void).create({}, .{});
    defer vpc.destroy();

    // Update user pointer to new type
    var peer: PeerUserPointer = .{};
    const pc = vpc.setUserPointer(PeerUserPointer, &peer);

    // Create a new track (inherits PeerConnection user pointer)
    const track = try pc.addTrack(MediaDescription);

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
