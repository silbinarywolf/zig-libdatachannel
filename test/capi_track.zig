//! Zig port of "libdatachannel/test/capi_track.cpp"
const Allocator = @import("std").mem.Allocator;
const mem = @import("std").mem;
const testing = @import("std").testing;
const builtin = @import("builtin");

const rtc = @import("libdatachannel");

const log = @import("std").log.scoped(.capi_track);

const Peer = struct {
    state: rtc.State,
    gatheringState: rtc.GatheringState,
    pc: rtc.PeerConnection(Peer),
    tr: rtc.OptionalTrack(Peer),
    connected: bool,
    other_peer: ?*Peer,

    fn init(peer: *Peer, config: rtc.PeerConnectionConfig) !void {
        // Create peer connection
        const pc = try rtc.PeerConnection(Peer).create(peer, config);
        errdefer pc.destroy();
        peer.* = .{
            .state = .new,
            .gatheringState = .new,
            .pc = pc,
            .tr = .none,
            .connected = false,
            .other_peer = null,
        };

        try pc.setTrackCallback(trackCallback);
        try pc.setLocalDescriptionCallback(descriptionCallback);
        try pc.setLocalCandidateCallback(candidateCallback);
        try pc.setStateChangeCallback(stateChangeCallback);
        try pc.setGatheringStateChangeCallback(gatheringStateCallback);
    }

    fn deinit(peer: *Peer) void {
        if (peer.tr.unwrap()) |tr| tr.close();
        peer.pc.close();
    }
};

const MediaDescription: [:0]const u8 = "video 9 UDP/TLS/RTP/SAVPF\r\n" ++
    "a=mid:video\r\n" ++
    "a=sendonly\r\n";

test "capi track" {
    // Create peer 1
    var peer1: Peer = undefined;
    try peer1.init(.{
        .port_range_begin = 5000,
        .port_range_end = 5009,
        // STUN server example
        // .ice_servers  = &.{
        //     "stun:stun.l.google.com:19302",
        // }
    });
    defer peer1.deinit();

    var peer2: Peer = undefined;
    try peer2.init(.{
        .port_range_begin = 5010,
        .port_range_end = 5019,
        // STUN server example
        // .ice_servers  = &.{
        //     "stun:stun.l.google.com:19302",
        // }
    });
    defer peer2.deinit();

    // Make peers aware of each other
    peer1.other_peer = &peer2;
    peer2.other_peer = &peer1;

    // Peer 1: Create track
    {
        const tr = try peer1.pc.addTrack(MediaDescription);
        peer1.tr = tr.toOptional();
        try tr.setOpenCallback(trackOpenCallback);
        try tr.setClosedCallback(trackClosedCallback);
        var mid_buf: [256]u8 = undefined;
        const mid = try tr.getMid(&mid_buf);
        if (!mem.containsAtLeast(u8, mid, 1, "video")) {
            return error.MissingPeer1MidVideo;
        }
        const direction = try tr.getDirection();
        if (direction != .sendonly) {
            return error.InvalidPeer1DirectionExpectedSendOnly;
        }
    }

    // Test createOffer
    blk: {
        var buf: [4096]u8 = undefined;
        const offer = try peer1.pc.createOffer(&buf);
        if (offer.len == 0)
            return error.EmptyPeer1OfferSize;
        _ = peer1.pc.getLocalDescription(&buf) catch |err| switch (err) {
            error.RtcNotAvailable => {
                // Expected to get error.RtcNotAvailable
                break :blk;
            },
            else => {
                log.err("getLocalDescription should fail with RtcNotAvailable", .{});
                return error.Peer1ExpectedLocalDescriptionRtcNotAvailable;
            },
        };
        log.err("createOffer has set the local description, which is not expected behaviour", .{});
        return error.Peer1ExpectedLocalDescriptionFailure;
    }

    // Initiate the handshake
    try peer1.pc.setLocalDescription(.unspecified);

    // Get local description
    {
        var buf: [4096]u8 = undefined;
        const local_description = try peer1.pc.getLocalDescription(&buf);
        if (local_description.len == 0)
            return error.EmptyPeer1LocalDescription;
        const local_description_len = try peer1.pc.getLocalDescriptionSize();
        if (local_description_len == 0)
            return error.EmptyPeer1LocalDescription;
        if (local_description_len - 1 != local_description.len) {
            log.err("local description length mismatch: {} {}", .{ local_description.len, local_description_len });
            return error.InvalidPeer1LocalDescription;
        }
    }

    // Wait for connection
    {
        var attempts: u32 = 40;
        while (attempts > 0 and (!peer1.connected or !peer2.connected)) {
            attempts -= 1;

            if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15) {
                // Deprecated path: Zig 0.15.X or lower
                @import("std").Thread.sleep(250 * 1000000);
            } else {
                try testing.io.sleep(.fromMilliseconds(250), .boot);
            }
        }
        if (peer1.state != .connected or peer2.state != .connected) {
            return error.PeerConnectionIsNotConnected;
        }
        if (!peer1.connected or !peer2.connected) {
            return error.TrackNotConnected;
        }
        if (attempts == 0) {
            return error.ExhaustedAttempts;
        }
    }
}

fn descriptionCallback(pc: rtc.PeerConnection(Peer), sdp: [:0]const u8, sdp_type: [:0]const u8, peer: *Peer) !void {
    log.info("Description: {} - {s}", .{ pc, sdp });
    const other = peer.other_peer.?;
    try other.pc.setRemoteDescription(sdp, .fromString(sdp_type));
}

fn candidateCallback(pc: rtc.PeerConnection(Peer), candidate: [:0]const u8, mid: [:0]const u8, peer: *Peer) !void {
    log.info("Candidate: {} - {s}, mid: {s}, other peer: {}", .{ pc, candidate, mid, peer.other_peer.?.pc });
    const other = peer.other_peer.?;
    try other.pc.addRemoteCandidate(candidate, mid);
}

fn stateChangeCallback(pc: rtc.PeerConnection(Peer), state: rtc.State, peer: *Peer) !void {
    peer.state = state;
    log.info("State: {} - {}", .{ pc, state });
}

fn gatheringStateCallback(pc: rtc.PeerConnection(Peer), gathering_state: rtc.GatheringState, peer: *Peer) !void {
    peer.gatheringState = gathering_state;
    log.info("Gathering state: {} - {}", .{ pc, gathering_state });
}

fn trackOpenCallback(_: rtc.Track(Peer), peer: *Peer) !void {
    peer.connected = true;
    log.info("Track: {} - Open", .{peer.pc});
}

fn trackClosedCallback(_: rtc.Track(Peer), peer: *Peer) !void {
    peer.connected = false;
    log.info("Track: {} - Closed", .{peer.pc});
}

fn trackCallback(_: rtc.PeerConnection(Peer), tr: rtc.Track(Peer), peer: *Peer) !void {
    var mid_buf: [256]u8 = undefined;
    const mid = try tr.getMid(&mid_buf);
    if (!mem.eql(u8, mid, "video")) {
        log.err("Peer({}): Track: {} - invalid mid identifier: {s}", .{ peer.pc, tr, mid });
        return error.GetTrackMidFailed;
    }

    const direction = try tr.getDirection();
    if (direction != .recvonly) {
        log.err("Peer({}): Track: {} - invalid direction: {}", .{ peer.pc, tr, direction });
        return error.GetTrackDirectionFailed;
    }

    var track_description_buf: [1024]u8 = undefined;
    const track_description = try tr.getDescription(&track_description_buf);

    log.info("Peer({}): Track: {} - Received with media description: {s}", .{ peer.pc, tr, track_description });

    peer.tr = tr.toOptional();
    try tr.setOpenCallback(trackOpenCallback);
    try tr.setClosedCallback(trackClosedCallback);
}
