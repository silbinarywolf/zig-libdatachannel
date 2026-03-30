## libdatachannel - Zig Bindings for the C/C++ WebRTC Network Library

[![License: MPL 2.0](https://img.shields.io/badge/License-MPL_2.0-blue.svg)](https://www.mozilla.org/en-US/MPL/2.0/)

⚠️ This library does not currently contain bindings for DataChannels or Websockets, if you would like to improve/use this library please add a PR and a new test case to cover that functionality, for example if you add DataChannels, port [capi_connectivity.cpp](https://github.com/paullouisageneau/libdatachannel/blob/607ae54fae8cc442640761a52f00cc2951c48ffa/test/capi_connectivity.cpp) similar to how I've ported [capi_track here.cpp](test/capi_track.zig)

This library contains *incomplete* Zig bindings for [libdatachannel](https://github.com/paullouisageneau/libdatachannel) but at the very least it can be built using Zig 0.16.X.

For example usage, look at the test code here: [capi_track](test/capi_track.zig).
