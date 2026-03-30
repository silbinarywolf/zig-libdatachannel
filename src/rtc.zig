//! Zig bindings for libdatachannel's C-bindings
//! https://github.com/paullouisageneau/libdatachannel/blob/master/DOC.md

const assert = @import("std").debug.assert;
const bigToNative = @import("std").mem.bigToNative;
const maxInt = @import("std").math.maxInt;
const nativeToBig = @import("std").mem.nativeToBig;
const panic = @import("std").debug.panic;
const process = @import("std").process;
const span = @import("std").mem.span;
const StaticStringMap = @import("std").StaticStringMap;
const writeStackTrace = @import("std").debug.writeStackTrace;
const builtin = @import("builtin");

const clib = @import("clibdatachannel");

const logrtc = @import("std").log.scoped(.libdatachannel);

// Import for error handling logic
/// From libdatachannel, IPv6 minimum guaranteed MTU
const DefaultMtu: u16 = 1280;

/// From libdatachannel
const DefaultMaxFragmentSize: u16 = DefaultMtu - 12 - 8 - 40;

/// Handle any kind of RTC error
pub const Error = InvalidOrRuntimeError || BufferError || BufferOrNotAvailableError;

/// Maps to errors returned by "wrap()" in the C-API
const InvalidOrRuntimeError = error{
    /// Invalid argument
    RtcInvalid,
    /// Runtime error
    RtcFailure,
};

/// Maps to errors used by any function that calls "copyAndReturn()" in the C-API
const BufferError = InvalidOrRuntimeError || error{
    BufferTooSmall, // Maps to RTC_ERR_TOO_SMALL, returned by C-API
};

/// Example of when RtcNotAvailable is thrown:
/// - rtcGetLocalDescription
/// - rtcGetRemoteDescription
/// - rtcGetLocalDescriptionType
const BufferOrNotAvailableError = BufferError || error{
    RtcNotAvailable,
};

/// defaultZigLogger can be used with "initLogger" to make libdatachannel use Zigs logger
pub fn defaultZigLogger(log_level: LogLevel, message: [:0]const u8) void {
    switch (log_level) {
        .none => unreachable,
        .fatal => logrtc.err("{s}", .{message}),
        .@"error" => logrtc.err("{s}", .{message}),
        .warning => logrtc.warn("{s}", .{message}),
        .info => logrtc.info("{s}", .{message}),
        .debug => logrtc.debug("{s}", .{message}),
        .verbose => logrtc.debug("{s}", .{message}),
    }
}

/// initLogger will set the log level and allow piping the log messages through a custom log callback.
///
/// To enable full logging with Zigs default logger
/// - rtc.initLogger(.verbose, rtc.defaultZigLogger);
pub inline fn initLogger(log_level: LogLevel, comptime log_callback: ?*const fn (LogLevel, [:0]const u8) void) void {
    return clib.rtcInitLogger(log_level.c(), if (log_callback) |cb| struct {
        fn callback(c_log_level: c_uint, c_message: [*c]const u8) callconv(.c) void {
            const msg: [:0]const u8 = if (c_message) |m| span(m) else return;
            return cb(.fromC(c_log_level), msg);
        }
    }.callback else null);
}

/// An optional call to rtcPreload preloads the global resources used by the library.
///
/// If it is not called, resources are lazy-loaded when they are required for the first time by a PeerConnection,
/// which for instance prevents from properly timing connection establishment (as the first one will take way more time).
/// The call blocks until preloading is finished. If resources are already loaded, the call has no effect.
pub inline fn preload() void {
    return clib.rtcPreload();
}

/// An optional call to rtcCleanup unloads the global resources used by the library. The call will block until unloading is done. If Peer Connections, Data Channels, Tracks, or WebSockets created through this API still exist, they will be destroyed. If resources are already unloaded, the call has no effect.
///
/// Warning: This function requires all Peer Connections, Data Channels, Tracks, and WebSockets to be destroyed before returning, meaning all callbacks must return before this function returns. Therefore, it must never be called from a callback.
pub inline fn cleanup() void {
    return clib.rtcCleanup();
}

pub const SdpType = enum(u8) {
    unspecified = 0,
    offer = 1,
    answer = 2,
    pranswer = 3,
    rollback = 4,

    const FromStringMap = StaticStringMap(SdpType).initComptime(.{
        .{ "offer", .offer },
        .{ "answer", .answer },
        .{ "pranswer", .pranswer },
        .{ "rollback", .rollback },
    });

    fn toCString(sdp_type: SdpType) [*c]const u8 {
        return switch (sdp_type) {
            .unspecified => null,
            .offer => "offer",
            .answer => "answer",
            .pranswer => "pranswer",
            .rollback => "rollback",
        };
    }

    pub fn fromString(typ: []const u8) SdpType {
        return FromStringMap.get(typ) orelse .unspecified;
    }
};

pub const LogLevel = enum(u4) {
    // From LibDataChannel: Don't change, it must match plog severity
    none = 0,
    fatal = 1,
    @"error" = 2,
    warning = 3,
    info = 4,
    debug = 5,
    verbose = 6,

    inline fn c(log_level: LogLevel) u8 {
        return @intFromEnum(log_level);
    }

    inline fn fromC(log_level: c_uint) LogLevel {
        return @enumFromInt(log_level);
    }

    comptime {
        assert(LogLevel.none.c() == clib.RTC_LOG_NONE);
        assert(LogLevel.fatal.c() == clib.RTC_LOG_FATAL);
        assert(LogLevel.@"error".c() == clib.RTC_LOG_ERROR);
        assert(LogLevel.warning.c() == clib.RTC_LOG_WARNING);
        assert(LogLevel.info.c() == clib.RTC_LOG_INFO);
        assert(LogLevel.debug.c() == clib.RTC_LOG_DEBUG);
        assert(LogLevel.verbose.c() == clib.RTC_LOG_VERBOSE);
    }
};

const Codec = enum(u8) {
    // video
    h264 = 0,
    vp8 = 1,
    vp9 = 2,
    h265 = 3,
    av1 = 4,

    // audio
    opus = 128,
    pcmu = 129,
    pcma = 130,
    aac = 131,
    g722 = 132,

    inline fn c(codec: Codec) u8 {
        return @intFromEnum(codec);
    }

    comptime {
        assert(Codec.h264.c() == clib.RTC_CODEC_H264);
        assert(Codec.vp8.c() == clib.RTC_CODEC_VP8);
        assert(Codec.vp9.c() == clib.RTC_CODEC_VP9);
        assert(Codec.h265.c() == clib.RTC_CODEC_H265);
        assert(Codec.av1.c() == clib.RTC_CODEC_AV1);

        assert(Codec.opus.c() == clib.RTC_CODEC_OPUS);
        assert(Codec.pcmu.c() == clib.RTC_CODEC_PCMU);
        assert(Codec.pcma.c() == clib.RTC_CODEC_PCMA);
        assert(Codec.aac.c() == clib.RTC_CODEC_AAC);
        assert(Codec.g722.c() == clib.RTC_CODEC_G722);
    }
};

const RtpHeaderVersionCCExtension = switch (builtin.cpu.arch.endian()) {
    // NOTE(jae): 2026-03-16
    // Used this C-struct definition as an example: https://stackoverflow.com/a/36808589
    .little => packed struct(u8) {
        csrc_count: u4,
        /// Indicates presence of an Extension Header between the header and payload data. The extension header is application or profile specific
        has_extension: u1,
        _padding: u1,
        /// Indicates the version of the protocol. Current version is 2
        version: u2,
    },
    .big => packed struct(u8) {
        /// Indicates the version of the protocol. Current version is 2
        version: u2,
        _padding: u1,
        /// Indicates presence of an Extension Header between the header and payload data. The extension header is application or profile specific
        has_extension: u1,
        csrc_count: u4,
    },
};

const RtpHeaderPayloadType = switch (builtin.cpu.arch.endian()) {
    .little => packed struct(u8) {
        payload_type: u7,
        /// Signaling used at the application level in a profile-specific manner. If it is set, it means that the current data has some special relevance for the application
        marker: u1,
    },
    .big => packed struct(u8) {
        /// Signaling used at the application level in a profile-specific manner. If it is set, it means that the current data has some special relevance for the application
        marker: u1,
        payload_type: u7,
    },
};

/// Maps to a standard RtpHeader but also to: 'libdatachannel/include/rtc/rtp.hpp'
/// https://en.wikipedia.org/wiki/Real-time_Transport_Protocol#Packet_header
///
/// This exists so that when forwarding rtp messages from one user to another via onTrackMessage callbacks
/// you can update the message data directly and set the SSRC.
///
/// For example, this is done in the following libdatachannel example: https://github.com/paullouisageneau/libdatachannel/blob/db9841d9e7cf0c5b1f09c09f42fa3ca4d3dcd14a/examples/media-sfu/main.cpp#L59
///   const header: *rtc.RtpHeader = @ptrCast(@alignCast(@constCast(message.ptr)));
///   header.setSsrc(42);
pub const RtpHeader = extern struct {
    version_cc_extension: RtpHeaderVersionCCExtension,
    payload_type_marker: RtpHeaderPayloadType,
    /// Use sequenceNumber() instead to read this value
    sequence_number_big_endian: u16,
    /// Use timestamp() instead to read this value
    timestamp_big_endian: u32,
    /// Use ssrc() instead to read this value and setSsrc to update this value
    ssrc_big_endian: u32,
    // The field after 'ssrc' is '[]csrc' (csrc_count * u32)

    /// Indicates the version of the protocol. Current version is 2
    pub inline fn version(header: *align(1) const RtpHeader) u2 {
        return header.version_cc_extension.version;
    }

    pub inline fn payloadType(header: *align(1) const RtpHeader) u7 {
        return header.payload_type_marker.payload_type;
    }

    pub inline fn sequenceNumber(header: *align(1) const RtpHeader) u16 {
        return bigToNative(u16, header.sequence_number_big_endian);
    }

    pub inline fn ssrc(header: *align(1) const RtpHeader) u32 {
        return bigToNative(u32, header.ssrc_big_endian);
    }

    pub inline fn setSsrc(header: *align(1) RtpHeader, new_ssrc: u32) void {
        header.ssrc_big_endian = nativeToBig(u32, new_ssrc);
    }

    pub inline fn timestamp(header: *align(1) const RtpHeader) u32 {
        return bigToNative(u32, header.timestamp_big_endian);
    }

    comptime {
        // TODO: This can be removed once .big endian is actually tested by a real person.
        assert(builtin.cpu.arch.endian() == .little);

        // RtpHeader should be 12-bytes exactly
        assert(@sizeOf(RtpHeader) == 12);
    }
};

pub const Direction = enum(u4) {
    unknown = 0,
    sendonly = 1,
    recvonly = 2,
    sendrecv = 3,
    inactive = 4,

    pub fn string(direction: Direction) []const u8 {
        return switch (direction) {
            .unknown => "unknown",
            .sendonly => "sendonly",
            .recvonly => "recvonly",
            .sendrecv => "sendrecv",
            .inactive => "inactive",
        };
    }

    inline fn c(direction: Direction) u8 {
        return @intFromEnum(direction);
    }

    inline fn fromC(direction: clib.rtcDirection) Direction {
        return @enumFromInt(direction);
    }

    comptime {
        assert(Direction.unknown.c() == clib.RTC_DIRECTION_UNKNOWN);
        assert(Direction.sendonly.c() == clib.RTC_DIRECTION_SENDONLY);
        assert(Direction.recvonly.c() == clib.RTC_DIRECTION_RECVONLY);
        assert(Direction.sendrecv.c() == clib.RTC_DIRECTION_SENDRECV);
        assert(Direction.inactive.c() == clib.RTC_DIRECTION_INACTIVE);
    }
};

pub const State = enum(u4) {
    new = clib.RTC_NEW,
    connecting = clib.RTC_CONNECTING,
    connected = clib.RTC_CONNECTED,
    disconnected = clib.RTC_DISCONNECTED,
    failed = clib.RTC_FAILED,
    closed = clib.RTC_CLOSED,

    inline fn fromC(state: clib.rtcState) State {
        return @enumFromInt(state);
    }
};

pub const IceState = enum(u3) {
    new = clib.RTC_ICE_NEW, // 0
    checking = clib.RTC_ICE_CHECKING,
    connected = clib.RTC_ICE_CONNECTED,
    completed = clib.RTC_ICE_COMPLETED,
    failed = clib.RTC_ICE_FAILED,
    disconnected = clib.RTC_ICE_DISCONNECTED,
    closed = clib.RTC_ICE_CLOSED,

    inline fn fromC(state: clib.rtcIceState) IceState {
        return @enumFromInt(state);
    }
};

/// https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/signalingState
pub const SignalingState = enum(u3) {
    /// There is no ongoing exchange of offer and answer underway. This may mean that the RTCPeerConnection
    /// object is new, in which case both the localDescription and remoteDescription are null;
    ///
    /// it may also mean that negotiation is complete and a connection has been established.
    stable = clib.RTC_SIGNALING_STABLE,
    /// The local peer has called RTCPeerConnection.setLocalDescription(), passing in SDP representing an offer
    have_local_offer = clib.RTC_SIGNALING_HAVE_LOCAL_OFFER,
    /// The remote peer has created an offer and used the signaling server to deliver it to the local peer, which has set the
    /// offer as the remote description by calling RTCPeerConnection.setRemoteDescription().
    have_remote_offer = clib.RTC_SIGNALING_HAVE_REMOTE_OFFER,
    /// The offer sent by the remote peer has been applied and an answer has been created (usually by calling RTCPeerConnection.createAnswer())
    /// and applied by calling RTCPeerConnection.setLocalDescription().
    have_local_pranswer = clib.RTC_SIGNALING_HAVE_LOCAL_PRANSWER,
    /// A provisional answer has been received and applied in response to an offer previously sent and established by calling setLocalDescription().
    have_remote_pranswer = clib.RTC_SIGNALING_HAVE_REMOTE_PRANSWER,

    inline fn fromC(state: clib.rtcSignalingState) SignalingState {
        return @enumFromInt(state);
    }
};

pub const GatheringState = enum(u2) {
    new = clib.RTC_GATHERING_NEW,
    in_progress = clib.RTC_GATHERING_INPROGRESS,
    complete = clib.RTC_GATHERING_COMPLETE,

    inline fn fromC(state: clib.rtcGatheringState) GatheringState {
        return @enumFromInt(state);
    }
};

/// Define how NAL units are separated in a H264/H265 sample
pub const NalUnitSeparator = enum(u4) {
    /// first 4 bytes are NAL unit length
    length = 0,
    /// 0x00, 0x00, 0x00, 0x01
    long_start_sequence = 1,
    /// 0x00, 0x00, 0x01
    short_start_sequence = 2,
    /// short_start_sequence (0x00, 0x00, 0x01) or long_start_sequence (0x00, 0x00, 0x00, 0x01)
    start_sequence = 3,

    inline fn c(nal_sep: NalUnitSeparator) u8 {
        return @intFromEnum(nal_sep);
    }

    comptime {
        assert(NalUnitSeparator.length.c() == clib.RTC_NAL_SEPARATOR_LENGTH);
        assert(NalUnitSeparator.long_start_sequence.c() == clib.RTC_NAL_SEPARATOR_LONG_START_SEQUENCE);
        assert(NalUnitSeparator.short_start_sequence.c() == clib.RTC_NAL_SEPARATOR_SHORT_START_SEQUENCE);
        assert(NalUnitSeparator.start_sequence.c() == clib.RTC_NAL_SEPARATOR_START_SEQUENCE);
    }
};

pub const CertificateType = enum(u4) {
    /// Defaults to: ECDSA
    default = 0,
    ecdsa = 1,
    rsa = 2,

    inline fn c(certificate_type: CertificateType) u8 {
        return @intFromEnum(certificate_type);
    }

    comptime {
        assert(CertificateType.default.c() == clib.RTC_CERTIFICATE_DEFAULT);
        assert(CertificateType.ecdsa.c() == clib.RTC_CERTIFICATE_ECDSA);
        assert(CertificateType.rsa.c() == clib.RTC_CERTIFICATE_RSA);
    }
};

pub const IceTransportPolicy = enum(u4) {
    all = 0,
    relay = 1,

    inline fn c(ice_transport_policy: IceTransportPolicy) u8 {
        return @intFromEnum(ice_transport_policy);
    }

    comptime {
        assert(IceTransportPolicy.all.c() == clib.RTC_TRANSPORT_POLICY_ALL);
        assert(IceTransportPolicy.relay.c() == clib.RTC_TRANSPORT_POLICY_RELAY);
    }
};

/// Define how OBUs are packetizied in a AV1 Sample
pub const ObuPacketization = enum(u4) {
    obu = 0,
    temporal_unit = 1,

    inline fn c(obu: ObuPacketization) u8 {
        return @intFromEnum(obu);
    }

    comptime {
        assert(ObuPacketization.obu.c() == clib.RTC_OBU_PACKETIZED_OBU);
        assert(ObuPacketization.temporal_unit.c() == clib.RTC_OBU_PACKETIZED_TEMPORAL_UNIT);
    }
};

pub const TrackInit = struct {
    direction: Direction,
    codec: Codec,
    payload_type: u8,
    /// positive 32-bit integer to uniquely identify a source
    /// https://developer.mozilla.org/en-US/docs/Web/API/RTCRemoteOutboundRtpStreamStats/ssrc
    ssrc: ?u32 = null,
    /// cname isn't required in libdatachannel but required for Chrome support
    /// eg. "video-send"
    cname: ?[:0]const u8 = null,
    msid: ?[:0]const u8 = null,
    /// track ID used in MSID
    track_id: ?[:0]const u8 = null,
    /// mid will default to 'video' or 'audio' if not set basd on the codec type
    ///
    /// This field represents the identifier that local and remote peers have agreed upon to uniquely identify the
    /// stream's pairing of sender and receiver.
    mid: ?[:0]const u8 = null,
    /// codec profile
    profile: ?[:0]const u8 = null,
};

pub const ClockRate = enum(u32) {
    /// PCMA, PCMU, G722
    @"8000" = 8000,
    /// OPUS, AAC
    ///
    /// Standard sampling rate used by professional digital video equipment, could reconstruct frequencies up to 22 kHz.
    @"48000" = 48000,
    /// Any Video - H264, H265, AV1, etc
    @"90000" = 90000,
    /// Support any other values libdatachannel does not currently handle
    _,

    pub const pcma: ClockRate = .@"8000";
    pub const pcmu: ClockRate = .@"8000";
    pub const g722: ClockRate = .@"8000";
    pub const opus: ClockRate = .@"48000";
    pub const aac: ClockRate = .@"48000";
    pub const video: ClockRate = .@"90000";

    pub inline fn fromValue(clock_rate: u32) ClockRate {
        return @enumFromInt(clock_rate);
    }

    pub fn c(cr: ClockRate) u32 {
        return @intFromEnum(cr);
    }
};

pub const PacketizerConfig = struct {
    ssrc: u32,
    cname: [:0]const u8,
    payload_type: u7,
    clock_rate: ClockRate,
    sequence_number: u16 = 0,
    timestamp: u32 = 0,

    // H264, H265, AV1
    max_fragment_size: u16 = 0, // Maximum fragment size, 0 means default

    // H264/H265 only
    nal_separator: NalUnitSeparator = .length, // NAL unit separator

    // AV1 only
    obu_packetization: ObuPacketization = .obu, // OBU packetization for AV1 samples

    // Playout Delay Extension
    playout_delay: PlayoutDelayConfig = .empty,

    // Color Space Extension
    color_space: ColorSpaceConfig = .empty,

    /// Convert to C
    fn c(config: PacketizerConfig) clib.rtcPacketizerInit {
        return .{
            .ssrc = config.ssrc,
            .cname = config.cname,
            .payloadType = config.payload_type,
            .clockRate = config.clock_rate.c(),
            .sequenceNumber = config.sequence_number,
            .timestamp = config.timestamp,
            // H264, H265, AV1
            .maxFragmentSize = config.max_fragment_size, // Defaults to RTC_DEFAULT_MAX_FRAGMENT_SIZE
            // H264, H265 only
            .nalSeparator = config.nal_separator.c(), // Defaults to RTC_NAL_SEPARATOR_LENGTH
            // AV1 only
            .obuPacketization = config.obu_packetization.c(), // OBU packetization for AV1 samples
            // Playout Delay Extension
            .playoutDelayId = config.playout_delay.id,
            .playoutDelayMin = config.playout_delay.min,
            .playoutDelayMax = config.playout_delay.max,
            // Color Space Extension
            .colorSpaceId = config.color_space.id,
            .colorChromaSitingHorz = config.color_space.chroma_siting_horizontal,
            .colorChromaSitingVert = config.color_space.chroma_siting_vertical,
            .colorRange = config.color_space.range,
            .colorPrimaries = config.color_space.primaries,
            .colorTransfer = config.color_space.transfer,
            .colorMatrix = config.color_space.matrix,
        };
    }
};

/// SDP Line Example: a=extmap:6/recvonly http://www.webrtc.org/experiments/rtp-hdrext/playout-delay
/// https://webrtc.googlesource.com/src/+/main/docs/native-code/rtp-hdrext/playout-delay/README.md
pub const PlayoutDelayConfig = struct {
    /// The negotiated extension id
    id: u8,

    // Minimum/maxiumum playout delay, in 10ms intervals. A value of 10 would equal a 100ms delay
    // - Interactive streaming (gaming, remote access) - (min delay = max delay = 0)
    //   - 0 ms: Certain gaming scenarios (likely without audio) where we will want to play the frame as soon as possible. Also, for remote desktop without audio where rendering a frame asap makes sense
    // - Interactive communication                     - (min delay = K1, max delay = K2)
    //   - 100/150/200 ms: These could be the max target latency for interactive streaming use cases depending on the actual application (gaming, remoting with audio, interactive scenarios)
    // - Movie playback                                - (min delay = max delay = K)
    //   - 400 ms: Application that want to ensure a network glitch has very little chance of causing a freeze can start with a minimum delay target that is high enough to deal with network issues.

    min: u12,
    max: u12,

    pub const empty: PlayoutDelayConfig = .{
        .id = 0,
        .min = 0,
        .max = 0,
    };
};

/// SDP Line Example: a=extmap:12 http://www.webrtc.org/experiments/rtp-hdrext/color-space
/// https://webrtc.googlesource.com/src/+/refs/heads/main/docs/native-code/rtp-hdrext/color-space/
pub const ColorSpaceConfig = struct {
    /// the negotiated ID of color space header extension
    id: u8,
    chroma_siting_horizontal: u8 = 0,
    chroma_siting_vertical: u8 = 0,
    range: u8 = 2, // full range
    primaries: u8 = 1, // BT.709-6
    transfer: u8 = 1, // BT.709-6
    matrix: u8 = 1, // BT.709-6

    pub const empty: ColorSpaceConfig = .{
        .id = 0,
        .chroma_siting_horizontal = 0,
        .chroma_siting_vertical = 0,
        .range = 0,
        .primaries = 0,
        .transfer = 0,
        .matrix = 0,
    };
};

pub const NackResponderConfig = struct {
    max_stored_packet_count: u32,

    /// Default size of 512 was taken from "libdatachannel/include/rtc/rtcpnackresponder.hpp"
    pub const DefaultMaxStoredPacketCount = 512;

    pub const default: NackResponderConfig = .{
        .max_stored_packet_count = DefaultMaxStoredPacketCount,
    };
};

pub fn OptionalTrack(comptime T: type) type {
    return enum(u32) {
        none = maxInt(u32),
        _,

        pub inline fn unwrap(ot: @This()) ?Track(T) {
            if (ot == .none) return null;
            return @enumFromInt(@intFromEnum(ot));
        }

        pub inline fn fromOptional(ot: ?Track(T)) @This() {
            return if (ot) |t| t.toOptional() else .none;
        }
    };
}

/// Track implicitly inherits PeerConnection 'setUserPointer'
pub fn Track(comptime T: type) type {
    return enum(u31) {
        _,

        /// Closes the track without removing it, unlike destroy()
        ///
        /// This does not block like destroy()
        pub inline fn close(tr: CTrack) InvalidOrRuntimeError!void {
            // NOTE(jae): 2026-03-15
            // rtcClose() = closes DataChannels, Tracks and WebSockets
            return try handleWrapError(clib.rtcClose(tr.c()));
        }

        /// Closes the track and removes it
        ///
        /// This function will block until all scheduled callbacks return
        /// (except the one this function might be called in) and no other callback will be called after it returns.
        pub inline fn destroy(tr: CTrack) InvalidOrRuntimeError!void {
            return try handleWrapError(clib.rtcDeleteTrack(tr.c()));
        }

        /// Set user pointer for track and change its user-pointer from the one it inherits from PeerConnection
        /// Returns newly typed Track.
        pub inline fn setUserPointer(pc: CTrack, comptime NT: type, userdata: *NT) Track(NT) {
            if (T == NT) @compileError("setUserPointer redundant call, setting to the type it already is");
            clib.rtcSetUserPointer(pc.c(), userdata);
            return @enumFromInt(@intFromEnum(pc));
        }

        /// Return media description for the video or audio track
        ///
        /// m=audio 9 UDP/TLS/RTP/SAVPF 109 9 0 8 101
        /// c=IN IP4 0.0.0.0
        /// a=mid:0
        /// a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level
        /// a=rtpmap:0 PCMU/8000
        /// a=rtpmap:8 PCMA/8000
        /// a=rtpmap:9 G722/8000/1
        /// a=rtpmap:101 telephone-event/8000
        /// a=fmtp:101 0-15
        /// a=rtpmap:109 opus/48000/2
        pub inline fn getDescription(tr: CTrack, buf: []u8) BufferError![:0]u8 {
            const size = try handleSizeWrapError(clib.rtcGetTrackDescription(tr.c(), buf.ptr, @intCast(buf.len)));
            return buf[0 .. size - 1 :0];
        }

        /// Get the identifier that local and remote peers have agreed upon to uniquely identify the
        /// stream's pairing of sender and receiver.
        pub inline fn getMid(tr: CTrack, buf: []u8) BufferError![:0]u8 {
            const size = try handleSizeWrapError(clib.rtcGetTrackMid(tr.c(), buf.ptr, @intCast(buf.len)));
            return buf[0 .. size - 1 :0];
        }

        pub inline fn getDirection(tr: CTrack) InvalidOrRuntimeError!Direction {
            var direction: clib.rtcDirection = undefined;
            try handleWrapError(clib.rtcGetTrackDirection(tr.c(), &direction));
            return .fromC(direction);
        }

        /// Request PLI (Picture-Loss-Indication) packet.
        ///
        /// This can be used to resolve lack of picture coming through the stream due to either
        /// packet loss or a new connection.
        pub fn requestKeyframe(tr: CTrack) InvalidOrRuntimeError!void {
            return try handleWrapError(clib.rtcRequestKeyframe(tr.c()));
        }

        pub inline fn isOpen(tr: CTrack) bool {
            return clib.rtcIsOpen(tr.c());
        }

        pub inline fn send(tr: CTrack, data: []const u8) InvalidOrRuntimeError!void {
            return try handleWrapError(clib.rtcSendMessage(tr.c(), data.ptr, @intCast(data.len)));
        }

        /// add RtcpReceivingSession media handler
        pub inline fn chainRtcpReceivingSession(tr: CTrack) InvalidOrRuntimeError!void {
            return handleWrapError(clib.rtcChainRtcpReceivingSession(tr.c()));
        }

        pub inline fn chainRtcpSrReporter(tr: CTrack) InvalidOrRuntimeError!void {
            return handleWrapError(clib.rtcChainRtcpSrReporter(tr.c()));
        }

        /// add RtcpNackResponder media handler
        /// ie. track.chainRtcpNackResponder(.default);
        pub inline fn chainRtcpNackResponder(tr: CTrack, init: NackResponderConfig) InvalidOrRuntimeError!void {
            return handleWrapError(clib.rtcChainRtcpNackResponder(tr.c(), init.max_stored_packet_count));
        }

        pub inline fn setH264Packetizer(tr: CTrack, config: PacketizerConfig) InvalidOrRuntimeError!void {
            const init = config.c();
            return handleWrapError(clib.rtcSetH264Packetizer(tr.c(), &init));
        }

        pub inline fn setH264Depacketizer(tr: CTrack, seperator: NalUnitSeparator) InvalidOrRuntimeError!void {
            return handleWrapError(clib.rtcSetH264Depacketizer(tr.c(), &.{
                .nalSeparator = seperator.c(),
            }));
        }

        pub inline fn toOptional(tr: CTrack) OptionalTrack(T) {
            return @enumFromInt(@intFromEnum(tr));
        }

        pub fn setOpenCallback(tr: CTrack, comptime callback: *const fn (track: CTrack, userdata: *T) anyerror!void) InvalidOrRuntimeError!void {
            const Container = struct {
                pub fn api_callback(_track_id: c_int, _userdata: ?*anyopaque) callconv(.c) void {
                    const self: CTrack = .fromC(_track_id);
                    const ud = toUserPointer(_userdata);
                    return callback(self, ud) catch |err|
                        handleErrorResult(self, err, ud);
                }
            };
            return handleWrapError(clib.rtcSetOpenCallback(tr.c(), Container.api_callback));
        }

        pub fn setClosedCallback(tr: CTrack, comptime callback: *const fn (track: CTrack, userdata: *T) anyerror!void) InvalidOrRuntimeError!void {
            const Container = struct {
                pub fn api_callback(_track_id: c_int, _userdata: ?*anyopaque) callconv(.c) void {
                    const self: CTrack = .fromC(_track_id);
                    const ud = toUserPointer(_userdata);
                    return callback(self, ud) catch |err|
                        handleErrorResult(self, err, ud);
                }
            };
            return handleWrapError(clib.rtcSetClosedCallback(tr.c(), Container.api_callback));
        }

        pub fn setErrorCallback(tr: CTrack, comptime callback: *const fn (track: CTrack, error_message: [:0]const u8, userdata: *T) void) InvalidOrRuntimeError!void {
            const Container = struct {
                pub fn api_callback(_track_id: c_int, _error: [*c]const u8, _userdata: ?*anyopaque) callconv(.c) void {
                    return callback(.fromC(_track_id), fromConstCString(_error), @ptrCast(@alignCast(_userdata)));
                }
            };
            return handleWrapError(clib.rtcSetErrorCallback(tr.c(), Container.api_callback));
        }

        pub fn setMessageCallback(tr: CTrack, comptime callback: *const fn (track: CTrack, message: []const u8, userdata: *T) anyerror!void) InvalidOrRuntimeError!void {
            const Container = struct {
                pub fn api_callback(_track_id: c_int, _message: [*c]const u8, size: c_int, _userdata: ?*anyopaque) callconv(.c) void {
                    const self: CTrack = .fromC(_track_id);
                    const ud = toUserPointer(_userdata);
                    const msg: []const u8 = if (size < 0)
                        // Negative size means null-terminated pointer
                        @as([:0]const u8, _message[0..@intCast(-size) :0])
                    else
                        @as([]const u8, _message[0..@intCast(size)]);
                    return callback(.fromC(_track_id), msg, ud) catch |err|
                        handleErrorResult(self, err, ud);
                }
            };
            return handleWrapError(clib.rtcSetMessageCallback(tr.c(), Container.api_callback));
        }

        inline fn c(tr: CTrack) u31 {
            return @intFromEnum(tr);
        }

        inline fn fromC(tr: c_int) CTrack {
            return @enumFromInt(tr);
        }

        inline fn toUserPointer(ptr: ?*anyopaque) *T {
            return @ptrCast(@alignCast(ptr.?));
        }

        fn handleErrorResult(tr: CTrack, err: anyerror, _: *T) void {
            // if (Options.error_handler) |error_handler| {
            //     return error_handler(pc, err, userdata);
            // }

            // Close the track on error for non-debug
            logrtc.err("unhandled error occurred with track({}): {s}", .{ tr, @errorName(err) });
            tr.close() catch {};
        }

        const CTrack = @This();
    };
}

pub const PeerConnectionConfig = struct {
    ice_servers: []const [*c]const u8 = &[0][*c]u8{},
    /// Requires "libnice" backend
    proxy_server: ?[:0]const u8 = null,
    /// Requires "libjuice" backend
    bind_address: ?[:0]const u8 = null,
    /// certificate type, either ".ecdsa" or ".rsa". (Default is .ecdsa)
    certificate_type: CertificateType = .default,
    /// ICE transport policy, if set to ".relay", the PeerConnection will emit only relayed candidates, ".all" is default.
    ice_transport_policy: IceTransportPolicy = .all,
    /// if true, generate TCP candidates for ICE, should set "port_range_begin" and "port_range_end"
    enable_ice_tcp: bool = false,
    port_range_begin: u16 = 1024, // Same default as "include/rtc/configuration.hpp"
    port_range_end: u16 = 65535, // Same default as "include/rtc/configuration.hpp"
    /// if true, connections are multiplexed on the same UDP port (should be combined with `portRangeBegin` and `portRangeEnd`, ignored with libnice as ICE backend)
    enable_ice_udp_mux: bool = false,
    /// if true, the user is responsible for calling `rtcSetLocalDescription` after creating a Data Channel and after setting the remote description
    disable_auto_negotiation: bool = false,
    /// if true, the connection allocates the SRTP media transport even if no tracks are present (necessary to add tracks during later renegotiation)
    force_media_transport: bool = false,
    /// manually set the Maximum Transfer Unit (MTU) for the connection (0 if automatic)
    /// - Cannot be lower than 576 (Min MTU for IPv4)
    /// - Setting MTU above 1500 might have issues
    mtu: u31 = 0,
    /// manually set the local maximum message size for Data Channels (0 if default)
    max_message_size: u31 = 0,
};

pub const IceUdpMux = struct {
    port_range_begin: u16,
    port_range_end: u16,
};

pub fn OptionalPeerConnection(comptime T: type) type {
    return enum(u32) {
        none = maxInt(u32),
        _,

        pub inline fn unwrap(ot: @This()) ?PeerConnection(T) {
            if (ot == .none) return null;
            return @enumFromInt(@intFromEnum(ot));
        }

        pub inline fn fromOptional(ot: ?PeerConnection(T)) @This() {
            return if (ot) |t| t.toOptional() else .none;
        }
    };
}

/// PeerConnection handle that calls the libdatachannel C-API
///
/// Not using 'setUserPointer' to create a peer connection:
/// - try rtc.PeerConnection(void).create({}, ...options...)
///
/// Using 'setUserPointer' to create a peer connection:
/// - try rtc.PeerConnection(CallbackUserPointer).create(user_pointer, ...options...)
pub fn PeerConnection(comptime T: type) type {
    return enum(u31) {
        _,

        fn handleErrorResult(pc: TPeerConnection, err: anyerror, _: *T) void {
            // TODO: Consider allowing custom global error handler
            // if (Options.error_handler) |error_handler| {
            //     return error_handler(@enumFromInt(pc.c()), err, userdata);
            // }

            // Close peer connection on error
            logrtc.err("unhandled error occurred with peer connection({}): {s}", .{ pc, @errorName(err) });
            pc.close() catch {};
        }

        const CreateType = if (T == void)
            void
        else
            *T;

        /// create
        pub fn create(userdata: CreateType, config: PeerConnectionConfig) InvalidOrRuntimeError!TPeerConnection {
            const pc = try createOpaque(config);
            errdefer pc.destroy() catch unreachable;
            return switch (T) {
                void => pc,
                else => pc.internalSetUserPointer(T, userdata),
            };
        }

        fn createOpaque(config: PeerConnectionConfig) InvalidOrRuntimeError!TPeerConnection {
            const pc_c = try handleIdWrapError(clib.rtcCreatePeerConnection(&.{
                // NOTE(jae): 2026-03-15
                // Use const-casting since the given C strings are read-from + copied immediately and to improve
                // how the API feels.
                .iceServers = if (config.ice_servers.len > 0) @constCast(config.ice_servers.ptr) else null,
                .iceServersCount = @intCast(config.ice_servers.len),
                .proxyServer = if (config.proxy_server) |v| v else null,
                .bindAddress = if (config.bind_address) |v| v else null,
                .certificateType = config.certificate_type.c(),
                .iceTransportPolicy = config.ice_transport_policy.c(),
                .enableIceTcp = config.enable_ice_tcp,
                .enableIceUdpMux = config.enable_ice_udp_mux,
                .disableAutoNegotiation = config.disable_auto_negotiation,
                .forceMediaTransport = config.force_media_transport,
                .portRangeBegin = config.port_range_begin,
                .portRangeEnd = config.port_range_end,
                .mtu = config.mtu,
                .maxMessageSize = config.max_message_size,
            }));
            return .fromC(pc_c);
        }

        /// Closes the peer connection without removing it, unlike destroy()
        ///
        /// Unlike destroy(), this will not block until all the scheduled callbacks return
        pub inline fn close(pc: TPeerConnection) InvalidOrRuntimeError!void {
            return try handleWrapError(clib.rtcClosePeerConnection(pc.c()));
        }

        /// Closes the peer connection and removes it
        ///
        /// This function will block until all scheduled callbacks return
        /// (except the one this function might be called in) and no other callback will be called after it returns.
        pub inline fn destroy(pc: TPeerConnection) InvalidOrRuntimeError!void {
            return try handleWrapError(clib.rtcDeletePeerConnection(pc.c()));
        }

        /// Set user pointer for PeerConnection(void) to give it a pointer-context.
        /// Returns newly typed PeerConnection.
        pub inline fn setUserPointer(pc: TPeerConnection, comptime NT: type, userdata: *NT) PeerConnection(NT) {
            if (T == NT) @compileError("setUserPointer redundant call, setting to the type it already is");
            if (T != void) @compileError("setUserPointer occurs on create() automatically for non-void PeerConnection");
            return pc.internalSetUserPointer(NT, userdata);
        }

        pub inline fn internalSetUserPointer(pc: TPeerConnection, comptime NT: type, userdata: *NT) PeerConnection(NT) {
            clib.rtcSetUserPointer(pc.c(), userdata);
            return @enumFromInt(@intFromEnum(pc));
        }

        /// Add a track via a media description sdp like:
        ///
        /// "video 9 UDP/TLS/RTP/SAVPF\r\n"
        /// "a=mid:video\r\n"
        /// "a=sendonly\r\n";
        pub inline fn addTrack(pc: TPeerConnection, media_description_sdp: [:0]const u8) InvalidOrRuntimeError!Track(T) {
            const track_c = try handleIdWrapError(clib.rtcAddTrack(pc.c(), media_description_sdp));
            return .fromC(track_c);
        }

        pub fn addTrackEx(pc: TPeerConnection, track_init: TrackInit) InvalidOrRuntimeError!Track(T) {
            const track_c = try handleIdWrapError(clib.rtcAddTrackEx(pc.c(), &.{
                .direction = track_init.direction.c(),
                .codec = track_init.codec.c(),
                .payloadType = track_init.payload_type,
                .ssrc = if (track_init.ssrc) |v| v else 0,
                .name = if (track_init.cname) |v| v else null,
                .mid = if (track_init.mid) |v| v else null,
                .msid = if (track_init.msid) |v| v else null,
                .trackId = if (track_init.track_id) |v| v else null,
                .profile = if (track_init.profile) |v| v else null,
            }));
            return .fromC(track_c);
        }

        /// Creates an SDP offer and puts the result in the given buffer
        ///
        /// Example:
        /// v=0
        /// o=rtc 2889486505 0 IN IP4 127.0.0.1
        /// s=-
        /// t=0 0
        /// a=group:BUNDLE video
        /// a=group:LS video
        /// a=msid-semantic:WMS *
        /// a=ice-options:ice2,trickle
        /// a=fingerprint:sha-256 1D:62:75:66:A8:9F:20:11:1C:99:00:33:89:99:65:CC:03:62:75:61:80:35:84:92:62:7B:1F:98:32:8B:DC:3A
        /// m=video 9 UDP/TLS/RTP/SAVPF
        /// c=IN IP4 0.0.0.0
        /// a=mid:video
        /// a=sendonly
        /// a=rtcp-mux
        /// a=setup:actpass
        /// a=ice-ufrag:hgsE
        /// a=ice-pwd:jnifz1bR9rKB8QkH6ZCb3P
        pub inline fn createOffer(pc: TPeerConnection, buf: []u8) BufferError![:0]u8 {
            const size = try handleSizeWrapError(clib.rtcCreateOffer(pc.c(), buf.ptr, @intCast(buf.len)));
            return buf[0 .. size - 1 :0];
        }

        /// Creates an SDP offer and returns its size
        ///
        /// Equivalent of calling "rtcCreateOffer(pc, NULL)"
        pub inline fn createOfferSize(pc: TPeerConnection) BufferError!u31 {
            const size = try handleSizeWrapError(clib.rtcCreateOffer(pc.c(), null, 0));
            return size;
        }

        pub inline fn getLocalDescription(pc: TPeerConnection, buf: []u8) BufferOrNotAvailableError![:0]u8 {
            const size = try handleSizeNotAvailableWrapError(clib.rtcGetLocalDescription(pc.c(), buf.ptr, @intCast(buf.len)));
            return buf[0 .. size - 1 :0];
        }

        /// Get the length of the local description (including null-terminating byte)
        /// See "getLocalDescription" to get the result and put it into a buffer.
        pub inline fn getLocalDescriptionSize(pc: TPeerConnection) BufferOrNotAvailableError!u31 {
            const size = try handleSizeNotAvailableWrapError(clib.rtcGetLocalDescription(pc.c(), null, 0));
            return size;
        }

        pub inline fn setRemoteDescription(pc: TPeerConnection, sdp: [:0]const u8, sdp_type: SdpType) InvalidOrRuntimeError!void {
            return try handleWrapError(clib.rtcSetRemoteDescription(pc.c(), sdp, sdp_type.toCString()));
        }

        /// Start the handshake by setting the local description.
        ///
        /// Using ".unspecified" is the equivalent to "rtcSetLocalDescription(pc, NULL)"
        pub inline fn setLocalDescription(pc: TPeerConnection, sdp_type: SdpType) InvalidOrRuntimeError!void {
            return try handleWrapError(clib.rtcSetLocalDescription(pc.c(), sdp_type.toCString()));
        }

        pub inline fn createAnswer(pc: TPeerConnection, buf: []u8) InvalidOrRuntimeError![:0]u8 {
            const size = try handleIdWrapError(clib.rtcCreateAnswer(pc.c(), buf.ptr, @intCast(buf.len)));
            return buf[0 .. size - 1 :0];
        }

        /// Creates an SDP answer and returns its size
        ///
        /// Equivalent of calling "rtcCreateAnswer(pc, NULL)"
        pub inline fn createAnswerSize(pc: TPeerConnection) InvalidOrRuntimeError!u31 {
            const size = try handleSizeWrapError(clib.rtcCreateAnswer(pc.c(), null, 0));
            return size;
        }

        pub fn addRemoteCandidate(pc: TPeerConnection, cand: [:0]const u8, mid: [:0]const u8) InvalidOrRuntimeError!void {
            return handleWrapError(clib.rtcAddRemoteCandidate(pc.c(), cand.ptr, mid.ptr));
        }

        pub fn isNegotiationNeeded(pc: TPeerConnection) bool {
            return clib.rtcIsNegotiationNeeded(pc.c());
        }

        pub fn setTrackCallback(pc: TPeerConnection, comptime callback: *const fn (TPeerConnection, Track(T), *T) anyerror!void) InvalidOrRuntimeError!void {
            const Container = struct {
                pub fn api_callback(_pc: c_int, _tr: c_int, _ptr: ?*anyopaque) callconv(.c) void {
                    const self: TPeerConnection = .fromC(_pc);
                    const ud = toUserPointer(_ptr);
                    return callback(self, .fromC(_tr), toUserPointer(_ptr)) catch |err|
                        handleErrorResult(self, err, ud);
                }
            };
            return handleWrapError(clib.rtcSetTrackCallback(pc.c(), Container.api_callback));
        }

        pub fn setLocalDescriptionCallback(pc: TPeerConnection, comptime callback: *const fn (pc: TPeerConnection, sdp: [:0]const u8, type: [:0]const u8, userdata: *T) anyerror!void) InvalidOrRuntimeError!void {
            const Container = struct {
                pub fn api_callback(_pc: c_int, _sdp: [*c]const u8, _typ: [*c]const u8, _ptr: ?*anyopaque) callconv(.c) void {
                    const self: TPeerConnection = .fromC(_pc);
                    const ud = toUserPointer(_ptr);
                    return callback(self, fromConstCString(_sdp), fromConstCString(_typ), ud) catch |err|
                        handleErrorResult(self, err, ud);
                }
            };
            return handleWrapError(clib.rtcSetLocalDescriptionCallback(pc.c(), Container.api_callback));
        }

        pub fn setLocalCandidateCallback(pc: TPeerConnection, comptime callback: *const fn (pc: TPeerConnection, candidate: [:0]const u8, mid: [:0]const u8, userdata: *T) anyerror!void) InvalidOrRuntimeError!void {
            const Container = struct {
                pub fn api_callback(_pc: c_int, _cand: [*c]const u8, _mid: [*c]const u8, _ptr: ?*anyopaque) callconv(.c) void {
                    const self: TPeerConnection = .fromC(_pc);
                    const ud = toUserPointer(_ptr);
                    return callback(self, fromConstCString(_cand), fromConstCString(_mid), ud) catch |err|
                        handleErrorResult(self, err, ud);
                }
            };
            return handleWrapError(clib.rtcSetLocalCandidateCallback(pc.c(), Container.api_callback));
        }

        pub fn setStateChangeCallback(pc: TPeerConnection, comptime callback: *const fn (TPeerConnection, State, *T) anyerror!void) InvalidOrRuntimeError!void {
            const Container = struct {
                pub fn api_callback(_pc: c_int, _state: clib.rtcState, _userdata: ?*anyopaque) callconv(.c) void {
                    const self: TPeerConnection = .fromC(_pc);
                    const ud = toUserPointer(_userdata);
                    return callback(self, .fromC(_state), ud) catch |err|
                        handleErrorResult(self, err, ud);
                }
            };
            return handleWrapError(clib.rtcSetStateChangeCallback(pc.c(), Container.api_callback));
        }

        pub fn setIceStateChangeCallback(pc: TPeerConnection, comptime callback: *const fn (PeerConnection, IceState, *T) anyerror!void) InvalidOrRuntimeError!void {
            const Container = struct {
                pub fn api_callback(_pc: c_int, _ice_state: clib.rtcIceState, _userdata: ?*anyopaque) callconv(.c) void {
                    const self: TPeerConnection = .fromC(_pc);
                    const ud = toUserPointer(_userdata);
                    return callback(self, .fromC(_ice_state), ud) catch |err|
                        handleErrorResult(self, err, ud);
                }
            };
            return handleWrapError(clib.rtcSetIceStateChangeCallback(pc.c(), Container.api_callback));
        }

        pub fn setGatheringStateChangeCallback(pc: TPeerConnection, comptime callback: *const fn (TPeerConnection, GatheringState, *T) anyerror!void) InvalidOrRuntimeError!void {
            const Container = struct {
                pub fn api_callback(_pc: c_int, _gather_state: clib.rtcGatheringState, _userdata: ?*anyopaque) callconv(.c) void {
                    const self: TPeerConnection = .fromC(_pc);
                    const ud = toUserPointer(_userdata);
                    return callback(.fromC(_pc), .fromC(_gather_state), toUserPointer(_userdata)) catch |err|
                        handleErrorResult(self, err, ud);
                }
            };
            return handleWrapError(clib.rtcSetGatheringStateChangeCallback(pc.c(), Container.api_callback));
        }

        pub fn setSignalingStateChangeCallback(pc: TPeerConnection, comptime callback: *const fn (TPeerConnection, SignalingState, *T) anyerror!void) InvalidOrRuntimeError!void {
            const Container = struct {
                pub fn api_callback(_pc: c_int, _signal_state: clib.rtcSignalingState, _userdata: ?*anyopaque) callconv(.c) void {
                    const self: TPeerConnection = .fromC(_pc);
                    const ud = toUserPointer(_userdata);
                    return callback(self, .fromC(_signal_state), ud) catch |err|
                        handleErrorResult(self, err, ud);
                }
            };
            return handleWrapError(clib.rtcSetSignalingStateChangeCallback(pc.c(), Container.api_callback));
        }

        pub inline fn toOptional(tr: TPeerConnection) OptionalPeerConnection(T) {
            return @enumFromInt(@intFromEnum(tr));
        }

        inline fn c(pc: TPeerConnection) u31 {
            return @intFromEnum(pc);
        }

        inline fn toUserPointer(ptr: ?*anyopaque) *T {
            return @ptrCast(@alignCast(ptr.?));
        }

        inline fn fromC(pc: i32) TPeerConnection {
            return @enumFromInt(pc);
        }

        const TPeerConnection = @This();
    };
}

inline fn fromConstCString(c_str: [*c]const u8) [:0]const u8 {
    return if (c_str == null) &[0:0]u8{} else span(c_str);
}

/// Returns a positive integer always and handles any negative values as error codes
fn handleIdWrapError(res: c_int) InvalidOrRuntimeError!u31 {
    if (res >= 0) return @intCast(res);

    switch (res) {
        -1 => return error.RtcInvalid, // RTC_ERR_INVALID
        -2 => return error.RtcFailure, // RTC_ERR_FAILURE
        -3 => unreachable, // RTC_ERR_NOT_AVAIL
        -4 => unreachable, // RTC_ERR_TOO_SMALL
        else => unreachable,
    }
}

/// Returns a buffer size
fn handleSizeWrapError(res: c_int) BufferError!u31 {
    if (res >= 0) return @intCast(res);

    return switch (res) {
        -1 => error.RtcInvalid, // RTC_ERR_INVALID
        -2 => error.RtcFailure, // RTC_ERR_FAILURE
        -3 => unreachable, // RTC_ERR_NOT_AVAIL
        -4 => error.BufferTooSmall, // RTC_ERR_TOO_SMALL
        else => unreachable,
    };
}

/// Returns a buffer size
fn handleSizeNotAvailableWrapError(res: c_int) BufferOrNotAvailableError!u31 {
    if (res >= 0) return @intCast(res);

    switch (res) {
        -1 => return error.RtcInvalid, // RTC_ERR_INVALID
        -2 => return error.RtcFailure, // RTC_ERR_FAILURE
        -3 => return error.RtcNotAvailable, // RTC_ERR_NOT_AVAIL
        -4 => return error.BufferTooSmall, // RTC_ERR_TOO_SMALL
        else => unreachable,
    }
}

/// Handle errors returned by C-API functions that only return errors via 'wrap()'
fn handleWrapError(res: c_int) InvalidOrRuntimeError!void {
    switch (res) {
        0 => return,
        -1 => return error.RtcInvalid, // RTC_ERR_INVALID
        -2 => return error.RtcFailure, // RTC_ERR_FAILURE
        -3 => unreachable, // RTC_ERR_NOT_AVAIL
        -4 => unreachable, // RTC_ERR_TOO_SMALL
        else => unreachable,
    }
}
