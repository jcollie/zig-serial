// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The types every backend shares, kept apart from `root.zig` so that a
//! backend can name them without importing the file that imports it.

const std = @import("std");

/// How the port frames a character on the line.
///
/// The defaults are 115200 8N1 with no flow control, which is what nearly
/// every piece of equipment built in the last twenty years expects out of the
/// box.
pub const Settings = struct {
    /// Bits per second. Any rate may be asked for; whether the UART can
    /// produce it is between the driver and the hardware, and
    /// `Port.current` reports what the driver actually chose.
    baud: u32 = 115200,
    data_bits: DataBits = .eight,
    parity: Parity = .none,
    stop_bits: StopBits = .one,
    flow: Flow = .none,
    /// Lower DTR (and RTS) when the port is closed, which is what tells a
    /// modem to hang up. POSIX's `HUPCL`.
    hang_up_on_close: bool = true,
    /// Ignore the modem status lines: do not wait for carrier when opening,
    /// and do not hang up when it drops. POSIX's `CLOCAL`. Almost always
    /// wanted, since a USB adapter or a bare three-wire connection never
    /// asserts carrier at all.
    local: bool = true,
};

pub const DataBits = enum(u4) {
    five = 5,
    six = 6,
    seven = 7,
    eight = 8,
};

pub const Parity = enum {
    none,
    even,
    odd,
    /// The parity bit is always one.
    mark,
    /// The parity bit is always zero.
    space,
};

pub const StopBits = enum {
    one,
    /// Only meaningful with five data bits, and only Windows can ask for it;
    /// Linux refuses it as `error.UnsupportedSetting`.
    one_and_half,
    two,
};

pub const Flow = enum {
    none,
    /// Hardware flow control on the RTS and CTS lines.
    rts_cts,
    /// Software flow control with XON (`^Q`) and XOFF (`^S`) in the data.
    xon_xoff,
    /// What `Port.current` reports for a combination this library does not
    /// name — XON without XOFF, say, or DSR flow control — left on the port by
    /// some other program. It cannot be asked for.
    other,
};

/// The state of the modem control lines.
pub const Modem = packed struct {
    /// Data Terminal Ready, an output.
    dtr: bool = false,
    /// Request To Send, an output.
    rts: bool = false,
    /// Clear To Send, an input.
    cts: bool = false,
    /// Data Set Ready, an input.
    dsr: bool = false,
    /// Data Carrier Detect, an input.
    dcd: bool = false,
    /// Ring Indicator, an input.
    ri: bool = false,

    pub fn format(self: Modem, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("DTR:{d} RTS:{d} CTS:{d} DSR:{d} DCD:{d} RI:{d}", .{
            @intFromBool(self.dtr), @intFromBool(self.rts), @intFromBool(self.cts),
            @intFromBool(self.dsr), @intFromBool(self.dcd), @intFromBool(self.ri),
        });
    }
};

/// The two modem lines this end drives.
pub const Line = enum { dtr, rts };

/// Which of the driver's buffers `Port.flush` discards.
pub const Queue = enum {
    /// Received and not yet read.
    input,
    /// Written and not yet sent.
    output,
    both,
};

pub const OpenOptions = struct {
    /// Refuse the port if another process has it open through this library,
    /// and keep any other process from opening it afterwards. On Linux that
    /// is an advisory `flock` plus `TIOCEXCL`; a Windows serial port is
    /// always exclusive, so this changes nothing there.
    exclusive: bool = true,
    /// Return `error.WouldBlock` from `read` and `write` rather than waiting.
    /// What an event loop wants; a thread that does nothing but read wants
    /// `false`.
    nonblocking: bool = true,
};

pub const OpenError = error{
    FileNotFound,
    AccessDenied,
    /// Another process holds the port.
    Busy,
    /// The path names something that is not a serial port — a regular file,
    /// a directory, `/dev/null`.
    NotASerialPort,
    NameTooLong,
    SystemResources,
} || ConfigureError;

pub const ConfigureError = error{
    /// The driver refused the rate outright.
    UnsupportedBaud,
    /// The platform cannot express the setting at all: one and a half stop
    /// bits on Linux, or `Flow.other` anywhere.
    UnsupportedSetting,
    /// The device went away.
    InputOutput,
    Unexpected,
};

pub const ReadError = error{
    /// Nothing is waiting, and the port was opened non-blocking.
    WouldBlock,
    /// The device went away — typically a USB adapter unplugged.
    InputOutput,
    Unexpected,
};

pub const WriteError = error{
    /// The driver's output buffer is full, and the port was opened
    /// non-blocking.
    WouldBlock,
    InputOutput,
    Unexpected,
};

pub const LineError = error{
    /// The device has no modem lines to report or drive. A pseudo-terminal
    /// is the usual case.
    Unsupported,
    InputOutput,
    Unexpected,
};
