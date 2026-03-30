const std = @import("std");
const LazyPath = std.Build.LazyPath;
const builtin = @import("builtin");

const TlsOption = enum {
    emscripten,
    openssl,
    mbedtls,
    // gnutls, // NOTE: Not implemented
};

const LibDataChannelDep = struct {
    src: LazyPath,
    include: LazyPath,
};

const OpenSslDep = struct {
    libcrypto: *std.Build.Step.Compile,
    libssl: *std.Build.Step.Compile,
};

const MbedTlsDep = struct {
    path: LazyPath,
    include: LazyPath,
    macro_defines: []const []const u8,
};

const TlsDep = union(TlsOption) {
    emscripten: void,
    openssl: OpenSslDep,
    mbedtls: MbedTlsDep,
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const linkage: std.builtin.LinkMode = .static;

    const tls_option: TlsOption = if (target.result.os.tag == .emscripten)
        .emscripten
    else
        .mbedtls;

    const plog_path: LazyPath = b.dependency("plog", .{}).path("");
    const usrsctp_path: LazyPath = b.dependency("usrsctp", .{}).path("usrsctplib");
    const libjuice_path: LazyPath = b.dependency("libjuice", .{}).path("");
    const libsrtp_path: LazyPath = b.dependency("libsrtp", .{}).path("");
    const libdatachannel_path = b.dependency("libdatachannel_cpp", .{}).path("");

    const tls_dep: TlsDep = tlsdepblk: switch (tls_option) {
        .emscripten => break :tlsdepblk TlsDep{
            .emscripten = {},
        },
        .openssl => {
            // TODO: Add support for openssl
            const dep = b.lazyDependency("openssl", .{}) orelse return error.MissingDependency;
            const ssl_dep = dep.path("");
            _ = ssl_dep; // autofix

            std.debug.panic("TODO: Add support for openssl", .{});

            // const libcrypto = try build_openssl.libcrypto(b, ssl_dep, target, optimize);
            // const libssl = try build_openssl.libssl(b, ssl_dep, target, optimize);
            break :tlsdepblk TlsDep{
                .openssl = .{
                    .libcrypto = undefined,
                    .libssl = undefined,
                },
            };
        },
        .mbedtls => {
            const mbedtls_path = if (b.lazyDependency("mbedtls", .{})) |d| d.path("") else b.path("src");
            break :tlsdepblk TlsDep{
                .mbedtls = .{
                    .path = mbedtls_path,
                    .include = mbedtls_path.path(b, "include"),
                    .macro_defines = &[_][]const u8{
                        // "MBEDTLS_DEBUG_C",
                        // "MBEDTLS_SSL_PROTO_TLS1_2",
                        // "MBEDTLS_SSL_PROTO_TLS1_3",
                        "MBEDTLS_SSL_DTLS_SRTP",
                    },
                },
            };
        },
    };

    const root_macro_flags = [_]MacroBool{
        .{ .name = "RTC_ENABLE_WEBSOCKET", .value = false },
        .{ .name = "RTC_ENABLE_MEDIA", .value = true },
        .{ .name = "USE_MBEDTLS", .value = tls_option == .mbedtls },
        .{ .name = "USE_NICE", .value = false },
        .{ .name = "RTC_SYSTEM_SRTP", .value = false },
    };

    const libdatachannel_dep: LibDataChannelDep = .{
        .src = libdatachannel_path.path(b, "src"),
        .include = libdatachannel_path.path(b, "include"),
    };

    // Add module
    const libdatachannel_mod = modblk: {
        const mod = b.addModule("libdatachannel", .{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/rtc.zig"),
        });
        var c_translate = b.addTranslateC(.{
            // .target = if (target.result.os.tag == .emscripten)
            //     b.resolveTargetQuery(.{ .os_tag = .linux, .cpu_arch = .x86 })
            // else
            //     target,
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/rtc.c"),
        });
        for (root_macro_flags) |macro| {
            c_translate.defineCMacro(macro.name, macro.valueString());
        }
        c_translate.addIncludePath(libdatachannel_dep.include);
        const c_mod = c_translate.createModule();
        mod.addImport("clibdatachannel", c_mod);
        break :modblk mod;
    };

    // Create libdatachannel library
    const libdatachannel_lib = libblk: {
        const mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
        });
        mod.addCMacro("RTC_EXPORTS", "1");
        for (root_macro_flags) |macro| {
            mod.addCMacro(macro.name, macro.valueString());
        }
        switch (target.result.os.tag) {
            // libdatachannel_wasm
            .emscripten => {
                const wasm_cpp_flags: []const []const u8 = &[_][]const u8{
                    "-std=c++17",
                };
                const libdatachannel_wasm_path: LazyPath = if (b.lazyDependency("libdatachannel_wasm", .{})) |d|
                    d.path("")
                else
                    b.path("invalid_path");
                const libdatachannel_wasm_src = libdatachannel_wasm_path.path(b, "wasm/src");
                const libdatachannel_wasm_include = libdatachannel_wasm_path.path(b, "wasm/include");
                const libdatachannel_js_include = libdatachannel_wasm_path.path(b, "wasm/js");
                mod.addCSourceFiles(.{
                    .root = libdatachannel_wasm_src,
                    .files = &libdatachannel_wasm_src_files,
                    .flags = wasm_cpp_flags,
                });
                mod.addIncludePath(libdatachannel_wasm_src);
                mod.addIncludePath(libdatachannel_wasm_include.path(b, "rtc"));
                mod.addIncludePath(libdatachannel_wasm_include);

                // Expose JS-Library to be fed into Emscripten compiler
                // ie. SHELL:--js-library \"${CMAKE_CURRENT_SOURCE_DIR}/wasm/js/webrtc.js\"
                b.addNamedLazyPath("webrtc.js", libdatachannel_js_include.path(b, "webrtc.js"));
                b.addNamedLazyPath("websocket.js", libdatachannel_js_include.path(b, "websocket.js"));
            },
            // As per website, supported operating systems: GNU/Linux, Android, FreeBSD, Apple macOS and iOS
            // https://libdatachannel.org/
            else => {
                // From libdatachannel cmake, it has fPIC: "-std=c++17", "-pthread", "-fPIC","-Wall"
                mod.pic = true;
                // if (target.result.cpu.arch == .mipsel) {
                //     // Experimenting with PSP
                //     mod.addCMacro("sockaddr_in6", "sockaddr_in");
                // }
                if (target.result.os.tag == .windows) {
                    mod.addCMacro("WIN32_LEAN_AND_MEAN", "1");
                }

                const root_cpp_flags: []const []const u8 = &[_][]const u8{
                    "-std=c++17",
                    "-pthread",
                    // "-fPIC",
                    // "-Wall",
                };
                mod.addCSourceFiles(.{
                    .root = libdatachannel_dep.src,
                    .files = &libdatachannel_src_files,
                    .flags = root_cpp_flags,
                });
                mod.addCSourceFiles(.{
                    .root = libdatachannel_dep.src.path(b, "impl"),
                    .files = &libdatachannel_src_impl_files,
                    .flags = root_cpp_flags,
                });
                mod.addIncludePath(libdatachannel_dep.src);
                mod.addIncludePath(libdatachannel_dep.include.path(b, "rtc"));
                mod.addIncludePath(libdatachannel_dep.include);
                mod.addIncludePath(plog_path.path(b, "include"));
                mod.addIncludePath(usrsctp_path);
                if (linkage == .static) {
                    mod.addCMacro("JUICE_STATIC", "1");
                }
                mod.addIncludePath(libjuice_path.path(b, "include"));
                mod.addIncludePath(libsrtp_path.path(b, "include"));
                switch (tls_dep) {
                    .emscripten => {}, // No-op
                    .openssl => {
                        // @panic("TODO: Handle this");
                    },
                    .mbedtls => |mbedtls_dep| {
                        for (mbedtls_dep.macro_defines) |macro_name| {
                            mod.addCMacro(macro_name, "1");
                        }
                        mod.addIncludePath(mbedtls_dep.include);
                    },
                }
            },
        }
        const lib = b.addLibrary(.{
            .name = "libdatachannel",
            .linkage = linkage,
            .root_module = mod,
        });
        b.installArtifact(lib);
        break :libblk lib;
    };
    libdatachannel_mod.linkLibrary(libdatachannel_lib);

    // Create and link dependencies
    const libdatachannel_lib_mod = libdatachannel_lib.root_module;

    switch (tls_dep) {
        .emscripten => {
            // do nothing for emscripten
        },
        .openssl => |openssl| {
            libdatachannel_mod.linkLibrary(openssl.libcrypto);
            libdatachannel_mod.linkLibrary(openssl.libssl);
        },
        // mbedtls
        .mbedtls => |mbedtls| {
            const mod = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            if (target.result.os.tag == .windows) {
                mod.linkSystemLibrary("bcrypt", .{});
            }
            for (mbedtls.macro_defines) |macro_name| {
                mod.addCMacro(macro_name, "1");
            }
            // Add "library" path so generated files can find "common.h"
            mod.addIncludePath(mbedtls.path.path(b, "library"));

            // Generated files, these files come from running "make" against the mbedtls source repository
            //
            // NOTE(jae): 2026-03-16
            // Last updated against: v3.6.X
            {
                const mbedtls_generated_path = b.path("upstream/mbedtls-gen");
                mod.addCSourceFiles(.{
                    .root = mbedtls_generated_path.path(b, "library"),
                    .files = &mbedtls_generated_src_files,
                });
                mod.addIncludePath(mbedtls_generated_path.path(b, "library"));
            }

            // Source files
            {
                mod.addCSourceFiles(.{
                    .root = mbedtls.path.path(b, "library"),
                    .files = &mbedtls_src_files,
                });
                mod.addIncludePath(mbedtls.include);
            }
            const lib = b.addLibrary(.{
                .name = "mbedtls",
                .root_module = mod,
                .linkage = linkage,
            });
            libdatachannel_lib_mod.linkLibrary(lib);
        },
    }

    // usrsctp
    if (target.result.os.tag != .emscripten) {
        const macro_flags = [_]MacroBool{
            .{ .name = "INET", .value = true },
            .{ .name = "INET6", .value = true },
            // .{ .name = "HAVE_SA_LEN", .value = true },
            // .{ .name = "HAVE_SIN_LEN", .value = true },
            // Define this if your IPv6 has sin6_len in sockaddr_in6 struct.
            // .{ .name = "HAVE_SIN6_LEN", .value = false },
            // .{ .name = "HAVE_SCONN_LEN", .value = true },
        };
        const mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        if (target.result.os.tag == .linux or target.result.os.tag == .freestanding) {
            mod.addCMacro("_GNU_SOURCE", "1");
        }
        if (target.result.os.tag == .macos or target.result.os.tag == .ios) {
            mod.addCMacro("__APPLE_USE_RFC_2292", "1");
        }
        mod.addCMacro("__Userspace__", "1");
        mod.addCMacro("SCTP_SIMPLE_ALLOCATOR", "1");
        mod.addCMacro("SCTP_PROCESS_LEVEL_LOCKS", "1");
        switch (tls_dep) {
            .emscripten => {}, // do nothing
            .openssl => {
                mod.addCMacro("SCTP_USE_OPENSSL_SHA1", "1");
            },
            .mbedtls => {
                mod.addCMacro("SCTP_USE_MBEDTLS_SHA1", "1");
            },
        }
        for (macro_flags) |macro| {
            mod.addCMacro(macro.name, macro.valueString());
        }
        mod.addCSourceFiles(.{
            .root = usrsctp_path,
            .files = &.{ "user_environment.c", "user_mbuf.c", "user_recv_thread.c", "user_socket.c" },
            .flags = &.{"-std=c99"},
        });
        mod.addCSourceFiles(.{
            .root = usrsctp_path.path(b, "netinet"),
            .files = &usrsctplib_netinet_src_files,
            .flags = &.{"-std=c99"},
        });
        mod.addCSourceFiles(.{
            .root = usrsctp_path.path(b, "netinet6"),
            .files = &.{"sctp6_usrreq.c"},
            .flags = &.{"-std=c99"},
        });
        if (target.result.os.tag == .windows) {
            mod.linkSystemLibrary("ws2_32", .{});
            mod.linkSystemLibrary("iphlpapi", .{});
        }
        // Based on: https://github.com/sctplab/usrsctp/blob/master/usrsctplib/meson.build
        mod.addIncludePath(usrsctp_path);
        mod.addIncludePath(usrsctp_path.path(b, "netinet"));
        mod.addIncludePath(usrsctp_path.path(b, "netinet6"));
        const lib = b.addLibrary(.{
            .name = "usrsctp",
            .root_module = mod,
            .linkage = linkage,
            .version = .{
                .major = 2,
                .minor = 0,
                .patch = 0,
            },
        });
        libdatachannel_lib_mod.linkLibrary(lib);
    }

    // srtp
    if (target.result.os.tag != .emscripten) {
        const mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        mod.addCMacro("HAVE_CONFIG_H", "1");
        switch (tls_dep) {
            .emscripten => {}, // do nothing for emscripten
            .openssl => {
                // @panic("TODO: Fix me");
                mod.addCMacro("ENABLE_OPENSSL", "1");
                mod.addCSourceFiles(.{
                    .root = libsrtp_path.path(b, "crypto"),
                    .files = &.{
                        // CIPHERS_SOURCES_C
                        "cipher/aes_icm_ossl.c",
                        "cipher/aes_gcm_ossl.c",
                        // HASHES_SOURCES_C
                        "hash/hmac_ossl.c",
                    },
                    .flags = &.{"-std=c99"},
                });
            },
            .mbedtls => |mbedtls| {
                mod.addCMacro("ENABLE_MBEDTLS", "1");
                mod.addCSourceFiles(.{
                    .root = libsrtp_path.path(b, "crypto"),
                    .files = &.{
                        // CIPHERS_SOURCES_C
                        "cipher/aes_icm_mbedtls.c",
                        "cipher/aes_gcm_mbedtls.c",
                        // HASHES_SOURCES_C
                        "hash/hmac_mbedtls.c",
                    },
                    .flags = &.{"-std=c99"},
                });
                mod.addIncludePath(mbedtls.include);
            },
        }
        mod.addCSourceFiles(.{
            .root = libsrtp_path.path(b, "srtp"),
            .files = &.{"srtp.c"},
            .flags = &.{"-std=c99"},
        });
        mod.addCSourceFiles(.{
            .root = libsrtp_path.path(b, "crypto"),
            .files = &libsrtp_crypto_src_files,
            .flags = &.{"-std=c99"},
        });
        const config_header = b.addConfigHeader(.{
            .style = .{ .cmake = libsrtp_path.path(b, "config_in_cmake.h") },
            .include_path = "config.h",
        }, .{
            .PACKAGE_VERSION = "2.7.0",
            .PACKAGE_STRING = "libsrtp2 2.7.0",
            .ERR_REPORTING_FILE = "",
            .SIZEOF_UNSIGNED_LONG_CODE = b.fmt("#define SIZEOF_UNSIGNED_LONG {}", .{target.result.cTypeByteSize(.ulong)}),
            .SIZEOF_UNSIGNED_LONG_LONG_CODE = b.fmt("#define SIZEOF_UNSIGNED_LONG_LONG {}", .{target.result.cTypeByteSize(.ulonglong)}),
            .OPENSSL = tls_option == .openssl,
            .MBEDTLS = tls_option == .mbedtls,
            // Define this to use AES-GCM
            .GCM = if (tls_option == .openssl or tls_option == .mbedtls) true else null,
            .CPU_CISC = if (target.result.cpu.arch.isX86()) true else null,
            .HAVE_X86 = if (target.result.cpu.arch.isX86()) true else null,
            .HAVE_ARPA_INET_H = true,
            .ENABLE_DEBUG_LOGGING = if (optimize == .Debug) true else false,
            .WORDS_BIGENDIAN = if (target.result.cpu.arch.endian() == .big) true else null,
            .HAVE_BYTESWAP_H = if (target.result.cpu.arch.endian() == .big) true else null,
            .HAVE_INTTYPES_H = true,
            .HAVE_MACHINE_TYPES_H = null,
            .HAVE_NETINET_IN_H = if (target.result.os.tag != .windows) true else false,
            .HAVE_STDINT_H = true,
            .HAVE_STDLIB_H = true,
            .HAVE_SYS_INT_TYPES_H = null,
            .HAVE_SYS_SOCKET_H = true,
            .HAVE_SYS_TYPES_H = true,
            .HAVE_UNISTD_H = true,
            .HAVE_WINDOWS_H = if (target.result.os.tag == .windows) true else null,
            .HAVE_WINSOCK2_H = if (target.result.os.tag == .windows) true else null,
            .HAVE_UINT8_T = true,
            .HAVE_UINT16_T = true,
            .HAVE_UINT32_T = true,
            .HAVE_UINT64_T = true,
            .HAVE_INT32_T = true,
            .HAVE_INLINE = true,
        });
        mod.addIncludePath(libsrtp_path.path(b, "include"));
        mod.addIncludePath(libsrtp_path.path(b, "crypto/include"));
        mod.addConfigHeader(config_header);

        const lib = b.addLibrary(.{
            .name = "srtp2",
            .root_module = mod,
            .linkage = linkage,
        });
        libdatachannel_lib_mod.linkLibrary(lib);
    }

    // libjuice
    if (target.result.os.tag != .emscripten) {
        const mod = b.createModule(.{
            .target = target,
            // CFLAGS: -O2 in the makefile (ReleaseFast)
            .optimize = optimize,
            .link_libc = true,
            .pic = true,
            // load of misaligned address 0x16fb70be7 for type 'uint16_t' (aka 'unsigned short'), which requires 2 byte alignment
            // src/stun.c:449:33: 0x101809b13 in stun_write_value_mapped_address
            .sanitize_c = .off,
        });
        mod.addCSourceFiles(.{
            .root = libjuice_path.path(b, "src"),
            .files = &libjuice_src_files,
            // CFLAGS=-O2 -pthread -fPIC -fvisibility=hidden -Wno-address-of-packed-member
            .flags = &.{ "-pthread", "-fvisibility=hidden", "-Wno-address-of-packed-member" },
        });
        mod.addCMacro("USE_NETTLE", "0"); // Use Nettle in libjuice
        mod.addCMacro("JUICE_EXPORTS", "1");
        if (linkage == .static) {
            mod.addCMacro("JUICE_STATIC", "1");
        }
        mod.addIncludePath(libjuice_path.path(b, "include/juice"));
        const lib = b.addLibrary(.{
            .name = "libjuice",
            .root_module = mod,
            .linkage = linkage,
        });
        libdatachannel_lib_mod.linkLibrary(lib);
    }

    // Add testing
    {
        const test_mod = b.createModule(.{
            .root_source_file = b.path("test/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        test_mod.addImport("libdatachannel", libdatachannel_mod);
        const test_filters: []const []const u8 = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &[0][]const u8{};
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{
            .root_module = test_mod,
            .filters = test_filters,
        })).step);
    }
}

const MacroBool = struct {
    name: [:0]const u8,
    value: bool,

    pub inline fn valueString(macro: MacroBool) []const u8 {
        return if (macro.value) "1" else "0";
    }
};

/// ls | egrep '\.cpp$|\.c$'
const libdatachannel_src_impl_files = [_][]const u8{
    "certificate.cpp",
    "channel.cpp",
    "datachannel.cpp",
    "dtlssrtptransport.cpp",
    "dtlstransport.cpp",
    "http.cpp",
    "httpproxytransport.cpp",
    "icetransport.cpp",
    "iceudpmuxlistener.cpp",
    "init.cpp",
    "logcounter.cpp",
    "peerconnection.cpp",
    "pollinterrupter.cpp",
    "pollservice.cpp",
    "processor.cpp",
    "sctptransport.cpp",
    "sha.cpp",
    "tcpserver.cpp",
    "tcptransport.cpp",
    "threadpool.cpp",
    "tls.cpp",
    "tlstransport.cpp",
    "track.cpp",
    "transport.cpp",
    "utils.cpp",
    "verifiedtlstransport.cpp",
    "websocket.cpp",
    "websocketserver.cpp",
    "wshandshake.cpp",
    "wstransport.cpp",
};

const libdatachannel_src_files = [_][]const u8{
    "av1rtppacketizer.cpp",
    "candidate.cpp",
    "capi.cpp",
    "channel.cpp",
    "configuration.cpp",
    "datachannel.cpp",
    "dependencydescriptor.cpp",
    "description.cpp",
    "global.cpp",
    "h264rtpdepacketizer.cpp",
    "h264rtppacketizer.cpp",
    "h265nalunit.cpp",
    "h265rtpdepacketizer.cpp",
    "h265rtppacketizer.cpp",
    "iceudpmuxlistener.cpp",
    "mediahandler.cpp",
    "message.cpp",
    "nalunit.cpp",
    "pacinghandler.cpp",
    "peerconnection.cpp",
    "plihandler.cpp",
    "rembhandler.cpp",
    "rtcpnackresponder.cpp",
    "rtcpreceivingsession.cpp",
    "rtcpsrreporter.cpp",
    "rtp.cpp",
    "rtpdepacketizer.cpp",
    "rtppacketizationconfig.cpp",
    "rtppacketizer.cpp",
    "track.cpp",
    "video_layers_allocation.cpp",
    "vp8rtpdepacketizer.cpp",
    "vp8rtppacketizer.cpp",
    "websocket.cpp",
    "websocketserver.cpp",
};

/// Use https://github.com/paullouisageneau/datachannel-wasm
const libdatachannel_wasm_src_files = [_][]const u8{
    "candidate.cpp",
    "channel.cpp",
    "configuration.cpp",
    "description.cpp",
    "datachannel.cpp",
    "global.cpp",
    "peerconnection.cpp",
    "websocket.cpp",
};

/// These are generated by "make", and you can see they're .gitignore'd here:
/// https://github.com/Mbed-TLS/mbedtls/blob/v3.6.5/library/.gitignore#L5-L11
const mbedtls_generated_src_files = [_][]const u8{
    "error.c",
    "version_features.c",
    "ssl_debug_helpers_generated.c",
    "psa_crypto_driver_wrappers_no_static.c",
};

const mbedtls_src_files = [_][]const u8{
    "aes.c",
    "aesce.c",
    "aesni.c",
    "aria.c",
    "asn1parse.c",
    "asn1write.c",
    "base64.c",
    "bignum.c",
    "bignum_core.c",
    "bignum_mod.c",
    "bignum_mod_raw.c",
    "block_cipher.c",
    "camellia.c",
    "ccm.c",
    "chacha20.c",
    "chachapoly.c",
    "cipher.c",
    "cipher_wrap.c",
    "cmac.c",
    "constant_time.c",
    "ctr_drbg.c",
    "debug.c",
    "des.c",
    "dhm.c",
    "ecdh.c",
    "ecdsa.c",
    "ecjpake.c",
    "ecp.c",
    "ecp_curves.c",
    "ecp_curves_new.c",
    "entropy.c",
    "entropy_poll.c",
    "gcm.c",
    "hkdf.c",
    "hmac_drbg.c",
    "lmots.c",
    "lms.c",
    "md5.c",
    "md.c",
    "memory_buffer_alloc.c",
    "mps_reader.c",
    "mps_trace.c",
    "net_sockets.c",
    "nist_kw.c",
    "oid.c",
    "padlock.c",
    "pem.c",
    "pk.c",
    "pkcs12.c",
    "pkcs5.c",
    "pkcs7.c",
    "pk_ecc.c",
    "pkparse.c",
    "pk_wrap.c",
    "pkwrite.c",
    "platform.c",
    "platform_util.c",
    "poly1305.c",
    "psa_crypto_aead.c",
    "psa_crypto.c",
    "psa_crypto_cipher.c",
    "psa_crypto_client.c",
    "psa_crypto_ecp.c",
    "psa_crypto_ffdh.c",
    "psa_crypto_hash.c",
    "psa_crypto_mac.c",
    "psa_crypto_pake.c",
    "psa_crypto_rsa.c",
    "psa_crypto_se.c",
    "psa_crypto_slot_management.c",
    "psa_crypto_storage.c",
    "psa_its_file.c",
    "psa_util.c",
    "ripemd160.c",
    "rsa_alt_helpers.c",
    "rsa.c",
    "sha1.c",
    "sha256.c",
    "sha3.c",
    "sha512.c",
    "ssl_cache.c",
    "ssl_ciphersuites.c",
    "ssl_client.c",
    "ssl_cookie.c",
    "ssl_msg.c",
    "ssl_ticket.c",
    "ssl_tls12_client.c",
    "ssl_tls12_server.c",
    "ssl_tls13_client.c",
    "ssl_tls13_generic.c",
    "ssl_tls13_keys.c",
    "ssl_tls13_server.c",
    "ssl_tls.c",
    "threading.c",
    "timing.c",
    "version.c",
    "x509.c",
    "x509_create.c",
    "x509_crl.c",
    "x509_crt.c",
    "x509_csr.c",
    "x509write.c",
    "x509write_crt.c",
    "x509write_csr.c",
};

const usrsctplib_netinet_src_files = [_][]const u8{
    "sctp_asconf.c",
    "sctp_auth.c",
    "sctp_bsd_addr.c",
    "sctp_callout.c",
    "sctp_cc_functions.c",
    "sctp_crc32.c",
    "sctp_indata.c",
    "sctp_input.c",
    "sctp_output.c",
    "sctp_pcb.c",
    "sctp_peeloff.c",
    "sctp_sha1.c",
    "sctp_ss_functions.c",
    "sctp_sysctl.c",
    "sctp_timer.c",
    "sctp_userspace.c",
    "sctp_usrreq.c",
    "sctputil.c",
};

const libsrtp_crypto_src_files = [_][]const u8{
    // CIPHERS_SOURCES_C
    "cipher/cipher.c",
    "cipher/cipher_test_cases.c",
    "cipher/null_cipher.c",
    // HASHES_SOURCES_C
    "hash/auth.c",
    "hash/auth_test_cases.c",
    "hash/null_auth.c",
    // KERNEL_SOURCES_C
    "kernel/alloc.c",
    "kernel/crypto_kernel.c",
    "kernel/err.c",
    "kernel/key.c",
    // MATH_SOURCES_C
    "math/datatypes.c",
    // REPLAY_SOURCES_C
    "replay/rdb.c",
    "replay/rdbx.c",
};

const libjuice_src_files = [_][]const u8{
    "addr.c",
    "agent.c",
    "base64.c",
    "conn.c",
    "conn_mux.c",
    "conn_poll.c",
    "conn_thread.c",
    "const_time.c",
    "crc32.c",
    "hash.c",
    "hmac.c",
    "ice.c",
    "juice.c",
    "log.c",
    "random.c",
    "server.c",
    "stun.c",
    "tcp.c",
    "timestamp.c",
    "turn.c",
    "udp.c",
};
