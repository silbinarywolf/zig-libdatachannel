//! Zig port of "libdatachannel/test/capi_connectivity.cpp"
const Allocator = @import("std").mem.Allocator;
const ArenaAllocator = @import("std").heap.ArenaAllocator;
const mem = @import("std").mem;
const testing = @import("std").testing;
const builtin = @import("builtin");

const rtc = @import("libdatachannel");

const log = @import("std").log.scoped(.capi_track);

const Peer = struct {
    state: rtc.State,
    gathering_state: rtc.GatheringState,
    ice_state: rtc.IceState,
    signalling_state: ?rtc.SignalingState,
    pc: rtc.PeerConnection(Peer),
    dc: rtc.OptionalDataChannel(Peer),
    connected: bool,
    got_message: bool,
    other_peer: ?*Peer,

    fn init(peer: *Peer, config: rtc.PeerConnectionConfig) !void {
        // Create peer connection
        const pc = try rtc.PeerConnection(Peer).create(peer, config);
        errdefer pc.destroy();
        peer.* = .{
            .state = .new,
            .gathering_state = .new,
            .ice_state = .new,
            .signalling_state = null,
            .pc = pc,
            .dc = .none,
            .connected = false,
            .got_message = false,
            .other_peer = null,
        };

        try pc.setDataChannelCallback(dataChannelCallback);
        try pc.setLocalDescriptionCallback(descriptionCallback);
        try pc.setLocalCandidateCallback(candidateCallback);
        try pc.setStateChangeCallback(stateChangeCallback);
        try pc.setGatheringStateChangeCallback(gatheringStateCallback);
        try pc.setIceStateChangeCallback(iceStateChangeCallback);
        try pc.setSignalingStateChangeCallback(signalingStateCallback);
    }

    fn deinit(peer: *Peer) void {
        if (peer.dc.unwrap()) |dc| dc.close();
        peer.pc.close();
    }
};

test "capi connectivity" {
    const gpa = testing.allocator;

    // SDP buffers can be much greater than 4096 bytes as used in the capi_connectivity.cpp file
    // I've observed up to 35000 bytes before, so lets make our SDP buffer large.
    const sdp_buf = try gpa.alloc(u8, 128000);
    defer gpa.free(sdp_buf);

    rtc.initLogger(.debug, rtc.defaultZigLogger);

    // Create peer 1
    var peer1: Peer = undefined;
    try peer1.init(.{
        // Custom MTU example
        .mtu = 1500,
        .port_range_begin = 7000,
        .port_range_end = 7009,
        // STUN server example
        // .ice_servers  = &.{
        //     "stun:stun.l.google.com:19302",
        // }
    });
    defer peer1.deinit();

    var peer2: Peer = undefined;
    try peer2.init(.{
        .port_range_begin = 7010,
        .port_range_end = 7019,
        // STUN server example
        // .ice_servers  = &.{
        //     "stun:stun.l.google.com:19302",
        // }
    });
    defer peer2.deinit();

    // Make peers aware of each other
    peer1.other_peer = &peer2;
    peer2.other_peer = &peer1;

    // Peer 1: Create data channel
    {
        const dc = try peer1.pc.createDataChannel("test", .{
            .protocol = "protocol",
            .unordered = true,
        });
        peer1.dc = dc.toOptional();
        try dc.setOpenCallback(dataChannelOpenCallback);
        try dc.setClosedCallback(dataChannelClosedCallback);
        try dc.setMessageCallback(messageCallback);
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
        if ((peer1.ice_state != .connected and peer1.ice_state != .completed) or
            (peer2.ice_state != .connected and peer2.ice_state != .completed))
        {
            return error.PeerConnectionIceStateIsNotConnected;
        }
        if (!peer1.connected or !peer2.connected) {
            return error.DataChannelNotConnected;
        }
        if (!peer1.got_message or !peer2.got_message) {
            return error.DataChannelMessageNotSentOrReceived;
        }
        if (attempts == 0) {
            return error.ExhaustedAttempts;
        }
    }

    log.info("Peer 1: Local Description SDP Type: {t}, SDP Data: {s}", .{
        try peer1.pc.getLocalDescriptionType(),
        try peer1.pc.getLocalDescription(sdp_buf),
    });
    log.info("Peer 1: Remote Description SDP Type: {t}, SDP Data: {s}", .{
        try peer1.pc.getRemoteDescriptionType(),
        try peer1.pc.getRemoteDescription(sdp_buf),
    });
    log.info("Peer 2: Local Description SDP Type: {t}, SDP Data: {s}", .{
        try peer2.pc.getLocalDescriptionType(),
        try peer2.pc.getLocalDescription(sdp_buf),
    });
    log.info("Peer 2: Remote Description SDP Type: {t}, SDP Data: {s}", .{
        try peer2.pc.getRemoteDescriptionType(),
        try peer2.pc.getRemoteDescription(sdp_buf),
    });

    // TODO(jae): 2026-04-24
    // Add bindings for these functions from capi_connectivity.cpp

    // if (rtcGetLocalAddress(peer1->pc, buffer, BUFFER_SIZE) < 0) {
    // fprintf(stderr, "rtcGetLocalAddress failed\n");
    // goto error;
    // }
    // printf("Local address 1: %s\n", buffer);

    // if (rtcGetRemoteAddress(peer1->pc, buffer, BUFFER_SIZE) < 0) {
    // fprintf(stderr, "rtcGetRemoteAddress failed\n");
    // goto error;
    // }
    // printf("Remote address 1: %s\n", buffer);

    // if (rtcGetLocalAddress(peer2->pc, buffer, BUFFER_SIZE) < 0) {
    // fprintf(stderr, "rtcGetLocalAddress failed\n");
    // goto error;
    // }
    // printf("Local address 2: %s\n", buffer);

    // if (rtcGetRemoteAddress(peer2->pc, buffer, BUFFER_SIZE) < 0) {
    // fprintf(stderr, "rtcGetRemoteAddress failed\n");
    // goto error;
    // }
    // printf("Remote address 2: %s\n", buffer);

    // if (rtcGetSelectedCandidatePair(peer1->pc, buffer, BUFFER_SIZE, buffer2, BUFFER_SIZE) < 0) {
    // fprintf(stderr, "rtcGetSelectedCandidatePair failed\n");
    // goto error;
    // }
    // printf("Local candidate 1:  %s\n", buffer);
    // printf("Remote candidate 1: %s\n", buffer2);

    // if (rtcGetSelectedCandidatePair(peer2->pc, buffer, BUFFER_SIZE, buffer2, BUFFER_SIZE) < 0) {
    // fprintf(stderr, "rtcGetSelectedCandidatePair failed\n");
    // goto error;
    // }
    // printf("Local candidate 2:  %s\n", buffer);
    // printf("Remote candidate 2: %s\n", buffer2);

    // if (rtcGetMaxDataChannelStream(peer1->pc) <= 0 || rtcGetMaxDataChannelStream(peer2->pc) <= 0) {
    // fprintf(stderr, "rtcGetMaxDataChannelStream failed\n");
    // goto error;
    // }

    // TODO(jae): 2026-04-24
    // Add bindings and testing for having no message callback set and receiving data manually
    {
        // const dc1 = peer1.dc.unwrap() orelse unreachable;
        // const dc2 = peer2.dc.unwrap() orelse unreachable;
        // dc2.removeMessageCallback();

        // try dc1.sendMessage("foo");
        if (builtin.zig_version.major == 0 and builtin.zig_version.minor <= 15) {
            // Deprecated path: Zig 0.15.X or lower
            @import("std").Thread.sleep(250 * 1000000);
        } else {
            try testing.io.sleep(.fromMilliseconds(250), .boot);
        }
        // size = 0;
        // if (rtcReceiveMessage(peer2->dc, NULL, &size) < 0 || size != testLen) {
        // fprintf(stderr, "rtcReceiveMessage failed to peek message size\n");
        // goto error;
        // }
        // if (rtcReceiveMessage(peer2->dc, buffer, &size) < 0 || size != testLen) {
        // fprintf(stderr, "rtcReceiveMessage failed to get the message\n");
        // goto error;
        // }
    }
}

fn descriptionCallback(pc: rtc.PeerConnection(Peer), sdp: [:0]const u8, sdp_type: [:0]const u8, peer: *Peer) !void {
    log.info("Description: {} - {s}", .{ pc, sdp });
    const other = peer.other_peer.?;
    try other.pc.setRemoteDescription(sdp, .fromString(sdp_type));
}

fn candidateCallback(pc: rtc.PeerConnection(Peer), candidate: [:0]const u8, mid: [:0]const u8, peer: *Peer) !void {
    log.info("Peer({}): Candidate: {s}, mid: {s}, other peer: {}", .{ pc, candidate, mid, peer.other_peer.?.pc });

    const other = peer.other_peer.?;
    try other.pc.addRemoteCandidate(candidate, mid);
}

fn stateChangeCallback(pc: rtc.PeerConnection(Peer), state: rtc.State, peer: *Peer) !void {
    peer.state = state;
    log.info("Peer({}): State: {}", .{ pc, state });
}

fn gatheringStateCallback(pc: rtc.PeerConnection(Peer), gathering_state: rtc.GatheringState, peer: *Peer) !void {
    peer.gathering_state = gathering_state;
    log.info("Peer({}): Gathering state: {}", .{ pc, gathering_state });
}

fn iceStateChangeCallback(pc: rtc.PeerConnection(Peer), ice_state: rtc.IceState, peer: *Peer) !void {
    peer.ice_state = ice_state;
    log.info("Peer({}): ICE state: {}", .{ pc, ice_state });
}

fn signalingStateCallback(pc: rtc.PeerConnection(Peer), signalling_state: rtc.SignalingState, peer: *Peer) !void {
    peer.signalling_state = signalling_state;
    log.info("Peer({}): Signaling state: {}", .{ pc, signalling_state });
}

fn dataChannelOpenCallback(dc: rtc.DataChannel(Peer), peer: *Peer) !void {
    log.info("Peer({}): DataChannel: {} - Open", .{ peer.pc, dc });
    peer.connected = true;

    // TODO: Add logic for testing messageCallback

    // if (!dc.isOpen()) {
    //     log.err("isOpen should be true, not false.");
    //     return error.DataChannelIsOpenFailed;
    // }
    // if (dc.isClosed()) {
    //     log.err("isClosed should be false, not true");
    //     return error.DataChannelIsClosedFailed;
    // }

    // const char *message = peer == peer1 ? "Hello from 1" : "Hello from 2";
    // rtcSendMessage(peer->dc, message, -1); // negative size indicates a null-terminated string
}

fn dataChannelClosedCallback(dc: rtc.DataChannel(Peer), peer: *Peer) !void {
    peer.connected = false;
    log.info("Peer({}): DataChannel: {} - Closed", .{ peer.pc, dc });
}

fn messageCallback(dc: rtc.DataChannel(Peer), kind: rtc.MessageType, data: []const u8, peer: *Peer) !void {
    peer.got_message = true;
    log.info("Peer({}): DataChannel: {} - message: {s} ({t})", .{ peer.pc, dc, data, kind });
}

fn dataChannelCallback(_: rtc.PeerConnection(Peer), dc: rtc.DataChannel(Peer), peer: *Peer) !void {
    // Peer *peer = (Peer *)ptr;

    var label_buf: [256]u8 = undefined;
    const label = try dc.getLabel(&label_buf);

    var protocol_buf: [256]u8 = undefined;
    const protocol = try dc.getProtocol(&protocol_buf);

    const reliability = try dc.getReliability();

    log.info("Peer({}): DataChannel: {} - Received with label \"{s}\" and protocol \"{s}\"", .{ peer.pc, dc, label, protocol });

    if (!mem.eql(u8, label, "test")) {
        log.err("Peer({}): DataChannel: {} - wrong DataChannel label", .{ peer.pc, dc });
        return error.UnexpectedDataChannelLabel;
    }
    if (!mem.eql(u8, protocol, "protocol")) {
        log.err("Peer({}): DataChannel: {} - wrong DataChannel protocol", .{ peer.pc, dc });
        return error.UnexpectedDataChannelProtocol;
    }
    if (reliability.unordered == false) {
        log.err("Peer({}): DataChannel: {} - wrong DataChannel reliability (unordered was true, expected false)", .{ peer.pc, dc });
        return error.UnexpectedDataChannelReliability;
    }

    try dc.setOpenCallback(dataChannelOpenCallback);
    try dc.setClosedCallback(dataChannelClosedCallback);
    try dc.setMessageCallback(messageCallback);

    peer.dc = dc.toOptional();
}
