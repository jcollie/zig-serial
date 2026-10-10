// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! Serial ports for Zig: open one, set its rate and framing, read and write
//! it, and drive its modem lines.
//!
//! ```zig
//! var port = try serial.Port.open("/dev/ttyUSB0", .{ .baud = 9600 }, .{});
//! defer port.close();
//! _ = try port.write("AT\r");
//! ```
//!
//! A `Port` puts the device into raw mode — no echo, no line editing, no
//! newline translation, no signals — so that what is written is what goes on
//! the wire and what arrives is what is read. `close` puts back the settings
//! the device had before.
//!
//! The backend is chosen at compile time. Linux talks to the kernel directly
//! through `termios2`, which is what makes any baud rate expressible, and
//! needs no libc. Windows uses the `DCB` through kernel32.

const builtin = @import("builtin");

const types = @import("types.zig");

pub const Settings = types.Settings;
pub const DataBits = types.DataBits;
pub const Parity = types.Parity;
pub const StopBits = types.StopBits;
pub const Flow = types.Flow;
pub const Modem = types.Modem;
pub const Line = types.Line;
pub const Queue = types.Queue;
pub const OpenOptions = types.OpenOptions;
pub const OpenError = types.OpenError;
pub const ConfigureError = types.ConfigureError;
pub const ReadError = types.ReadError;
pub const WriteError = types.WriteError;
pub const LineError = types.LineError;

const backend = switch (builtin.target.os.tag) {
    .linux => @import("linux.zig"),
    .windows => @import("windows.zig"),
    else => @compileError(
        "zig-serial has no backend for " ++ @tagName(builtin.target.os.tag) ++
            " yet: the BSDs and macOS want one on their libc termios, with" ++
            " IOSSIOSPEED for arbitrary rates on macOS",
    ),
};

/// A file descriptor on Linux, a `HANDLE` on Windows: whatever the platform
/// waits on. An event loop polls `Port.handle` for readability.
pub const Handle = backend.Handle;

/// An open serial port. See the module documentation.
///
/// The methods every backend provides:
///
/// ```
/// fn open(path: []const u8, Settings, OpenOptions) OpenError!Port
/// fn close(*Port) void
/// fn configure(*Port, Settings) ConfigureError!void
/// fn current(*Port) ConfigureError!Settings  // as the driver has them
/// fn read(*Port, []u8) ReadError!usize        // 0 means the far end hung up
/// fn write(*Port, []const u8) WriteError!usize
/// fn drain(*Port) WriteError!void
/// fn flush(*Port, Queue) ConfigureError!void
/// fn sendBreak(*Port) WriteError!void
/// fn modem(*Port) LineError!Modem
/// fn setLine(*Port, Line, bool) LineError!void
/// ```
pub const Port = backend.Port;

comptime {
    for (.{
        "open",  "close", "configure", "current", "read",    "write",
        "drain", "flush", "sendBreak", "modem",   "setLine",
    }) |name| {
        if (!@hasDecl(Port, name)) @compileError("the serial backend has no Port." ++ name);
    }
}

test {
    _ = types;
    _ = backend;
    // So that a cross-compiled test binary analyzes the whole backend, even
    // where none of its tests can run.
    @import("std").testing.refAllDecls(Port);
}
