// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The Linux backend, on raw system calls and `termios2`.
//!
//! `termios2` is the kernel's own form of the terminal attributes, reached
//! with `TCGETS2` and `TCSETS2`. The difference from the `termios` libc
//! exposes is two fields, `c_ispeed` and `c_ospeed`, that hold a rate as a
//! plain number: with `BOTHER` in place of a `Bnnn` code in `c_cflag`, the
//! driver is asked for exactly that rate. Every rate goes that way here,
//! standard or not, so there is one path rather than a table and a fallback.
//!
//! The layout of `termios2` and the values of its flags differ on MIPS,
//! PowerPC, SPARC and Alpha. What is written here is the asm-generic layout
//! that everything else uses, and the other four are refused at compile time
//! rather than handed a structure the kernel would misread.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const types = @import("types.zig");
const Settings = types.Settings;

pub const Handle = linux.fd_t;

comptime {
    switch (builtin.target.cpu.arch) {
        .x86,
        .x86_64,
        .arm,
        .armeb,
        .thumb,
        .thumbeb,
        .aarch64,
        .aarch64_be,
        .riscv32,
        .riscv64,
        .loongarch32,
        .loongarch64,
        => {},
        else => @compileError("zig-serial does not know the termios2 layout for " ++
            @tagName(builtin.target.cpu.arch)),
    }
}

/// `struct termios2` from `asm-generic/termbits.h`. The speed fields are
/// plain integers here rather than `std.os.linux.speed_t`, whose exhaustive
/// enum has no room for a rate like 31250.
const Termios2 = extern struct {
    iflag: u32,
    oflag: u32,
    cflag: u32,
    lflag: u32,
    line: u8,
    cc: [19]u8,
    ispeed: u32,
    ospeed: u32,
};

comptime {
    // The ioctl numbers encode the structure's size; this is the one they
    // were computed with.
    std.debug.assert(@sizeOf(Termios2) == @sizeOf(linux.termios2));
}

// `c_iflag`
const IGNBRK: u32 = 0o1;
const BRKINT: u32 = 0o2;
const IGNPAR: u32 = 0o4;
const PARMRK: u32 = 0o10;
const INPCK: u32 = 0o20;
const ISTRIP: u32 = 0o40;
const INLCR: u32 = 0o100;
const IGNCR: u32 = 0o200;
const ICRNL: u32 = 0o400;
const IUCLC: u32 = 0o1000;
const IXON: u32 = 0o2000;
const IXANY: u32 = 0o4000;
const IXOFF: u32 = 0o10000;
const IMAXBEL: u32 = 0o20000;

// `c_oflag`
const OPOST: u32 = 0o1;

// `c_cflag`
const CBAUD: u32 = 0o10017;
const BOTHER: u32 = 0o10000;
const CSIZE: u32 = 0o60;
const CS5: u32 = 0o0;
const CS6: u32 = 0o20;
const CS7: u32 = 0o40;
const CS8: u32 = 0o60;
const CSTOPB: u32 = 0o100;
const CREAD: u32 = 0o200;
const PARENB: u32 = 0o400;
const PARODD: u32 = 0o1000;
const HUPCL: u32 = 0o2000;
const CLOCAL: u32 = 0o4000;
/// The input rate's code, `CBAUD` shifted up by `IBSHIFT`. Zero means "the
/// same as the output rate".
const CIBAUD: u32 = CBAUD << 16;
const CMSPAR: u32 = 0o10000000000;
const CRTSCTS: u32 = 0o20000000000;

// `c_lflag`
const ISIG: u32 = 0o1;
const ICANON: u32 = 0o2;
const ECHO: u32 = 0o10;
const ECHOE: u32 = 0o20;
const ECHOK: u32 = 0o40;
const ECHONL: u32 = 0o100;
const IEXTEN: u32 = 0o100000;

// `c_cc` indices
const VTIME = 5;
const VMIN = 6;
const VSTART = 8;
const VSTOP = 9;

// `flock` operations
const LOCK_EX = 2;
const LOCK_NB = 4;

// `TIOCMGET` bits. std has these only for MIPS.
const TIOCM_DTR = 0x002;
const TIOCM_RTS = 0x004;
const TIOCM_CTS = 0x020;
const TIOCM_CAR = 0x040;
const TIOCM_RNG = 0x080;
const TIOCM_DSR = 0x100;

// `TCFLSH` arguments
const TCIFLUSH = 0;
const TCOFLUSH = 1;
const TCIOFLUSH = 2;

/// Writes `settings` and raw mode into `t`, leaving alone what neither
/// touches. Kept apart from the ioctl so that it can be tested without a
/// device: a pseudo-terminal forces eight bits and no parity whatever it is
/// told, so half of this cannot be checked through one.
fn encode(t: *Termios2, settings: Settings) types.ConfigureError!void {
    // Raw mode, as cfmakeraw(3) describes it.
    t.iflag &= ~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IUCLC | IMAXBEL);
    t.oflag &= ~OPOST;
    t.lflag &= ~(ECHO | ECHOE | ECHOK | ECHONL | ICANON | ISIG | IEXTEN);
    t.cflag |= CREAD;
    // A read returns as soon as there is one byte, and not before.
    t.cc[VMIN] = 1;
    t.cc[VTIME] = 0;

    t.cflag &= ~(CBAUD | CIBAUD);
    t.cflag |= BOTHER;
    t.ospeed = settings.baud;
    t.ispeed = settings.baud;

    t.cflag &= ~CSIZE;
    t.cflag |= switch (settings.data_bits) {
        .five => CS5,
        .six => CS6,
        .seven => CS7,
        .eight => CS8,
    };

    t.cflag &= ~(PARENB | PARODD | CMSPAR);
    t.cflag |= switch (settings.parity) {
        .none => 0,
        .even => PARENB,
        .odd => PARENB | PARODD,
        .mark => PARENB | PARODD | CMSPAR,
        .space => PARENB | CMSPAR,
    };
    // Check what arrives when there is a bit to check. A character that
    // fails reads as NUL, which is what a terminal wants; PARMRK's
    // three-byte escapes are for programs that parse the stream.
    if (settings.parity == .none) {
        t.iflag &= ~(INPCK | IGNPAR);
    } else {
        t.iflag |= INPCK;
        t.iflag &= ~IGNPAR;
    }

    switch (settings.stop_bits) {
        .one => t.cflag &= ~CSTOPB,
        .two => t.cflag |= CSTOPB,
        .one_and_half => return error.UnsupportedSetting,
    }

    t.cflag &= ~CRTSCTS;
    t.iflag &= ~(IXON | IXOFF | IXANY);
    switch (settings.flow) {
        .none => {},
        .rts_cts => t.cflag |= CRTSCTS,
        .xon_xoff => {
            t.iflag |= IXON | IXOFF;
            t.cc[VSTART] = 0x11;
            t.cc[VSTOP] = 0x13;
        },
        .other => return error.UnsupportedSetting,
    }

    if (settings.hang_up_on_close) t.cflag |= HUPCL else t.cflag &= ~HUPCL;
    if (settings.local) t.cflag |= CLOCAL else t.cflag &= ~CLOCAL;
}

fn decode(t: Termios2) Settings {
    const rtscts = t.cflag & CRTSCTS != 0;
    const ixon = t.iflag & IXON != 0;
    const ixoff = t.iflag & IXOFF != 0;
    return .{
        .baud = t.ospeed,
        .data_bits = switch (t.cflag & CSIZE) {
            CS5 => .five,
            CS6 => .six,
            CS7 => .seven,
            else => .eight,
        },
        .parity = if (t.cflag & PARENB == 0)
            .none
        else if (t.cflag & CMSPAR != 0)
            (if (t.cflag & PARODD != 0) .mark else .space)
        else if (t.cflag & PARODD != 0)
            .odd
        else
            .even,
        .stop_bits = if (t.cflag & CSTOPB != 0) .two else .one,
        .flow = if (!rtscts and !ixon and !ixoff)
            .none
        else if (rtscts and !ixon and !ixoff)
            .rts_cts
        else if (!rtscts and ixon and ixoff)
            .xon_xoff
        else
            .other,
        .hang_up_on_close = t.cflag & HUPCL != 0,
        .local = t.cflag & CLOCAL != 0,
    };
}

pub const Port = struct {
    handle: Handle,
    /// The attributes the device had when it was opened, put back by
    /// `close`.
    original: Termios2,
    exclusive: bool,

    pub fn open(path: []const u8, settings: Settings, options: types.OpenOptions) types.OpenError!Port {
        var path_buf: [linux.PATH_MAX]u8 = undefined;
        if (path.len >= path_buf.len) return error.NameTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        // Non-blocking even when the caller wants blocking I/O, because
        // without CLOCAL an open waits for carrier, and the settings that
        // would set CLOCAL cannot be applied until the open returns. The flag
        // comes off again below.
        const rc = linux.open(@ptrCast(&path_buf), .{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
            .NONBLOCK = true,
            .CLOEXEC = true,
        }, 0);
        const fd: Handle = switch (linux.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .NOENT, .NXIO, .NODEV => return error.FileNotFound,
            .ACCES, .PERM, .ROFS => return error.AccessDenied,
            .BUSY => return error.Busy,
            .ISDIR => return error.NotASerialPort,
            .NAMETOOLONG => return error.NameTooLong,
            .MFILE, .NFILE, .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        };
        errdefer _ = linux.close(fd);

        var original: Termios2 = undefined;
        switch (linux.errno(linux.ioctl(fd, linux.T.CGETS2, @intFromPtr(&original)))) {
            .SUCCESS => {},
            .NOTTY, .INVAL => return error.NotASerialPort,
            .IO => return error.InputOutput,
            else => return error.Unexpected,
        }

        if (options.exclusive) {
            // The advisory lock is what another copy of this library — or
            // anything else that asks politely — will see. TIOCEXCL is what
            // stops everything else, root aside.
            switch (linux.errno(linux.flock(fd, LOCK_EX | LOCK_NB))) {
                .SUCCESS => {},
                .AGAIN => return error.Busy,
                else => return error.Unexpected,
            }
            _ = linux.ioctl(fd, linux.T.IOCEXCL, 0);
        }

        var port: Port = .{ .handle = fd, .original = original, .exclusive = options.exclusive };
        try port.configure(settings);

        if (!options.nonblocking) {
            const flags = linux.fcntl(fd, linux.F.GETFL, 0);
            if (linux.errno(flags) != .SUCCESS) return error.Unexpected;
            var o: linux.O = @bitCast(@as(u32, @truncate(flags)));
            o.NONBLOCK = false;
            if (linux.errno(linux.fcntl(fd, linux.F.SETFL, @as(u32, @bitCast(o)))) != .SUCCESS)
                return error.Unexpected;
        }

        return port;
    }

    /// Puts the device's original settings back and closes it.
    ///
    /// `TCSETS2` rather than the draining `TCSETSW2`: with hardware flow
    /// control and nobody at the far end, a drain never finishes, and a close
    /// that hangs is worse than one that discards a few unsent bytes.
    pub fn close(port: *Port) void {
        _ = linux.ioctl(port.handle, linux.T.CSETS2, @intFromPtr(&port.original));
        if (port.exclusive) _ = linux.ioctl(port.handle, linux.T.IOCNXCL, 0);
        _ = linux.close(port.handle);
        port.* = undefined;
    }

    /// Applies `settings`, along with raw mode, in one `TCSETS2`, so the line
    /// never runs at a mixture of the old configuration and the new.
    pub fn configure(port: *Port, settings: Settings) types.ConfigureError!void {
        var t = try port.get();
        try encode(&t, settings);
        switch (linux.errno(linux.ioctl(port.handle, linux.T.CSETS2, @intFromPtr(&t)))) {
            .SUCCESS => {},
            .INVAL => return error.UnsupportedBaud,
            .IO => return error.InputOutput,
            else => return error.Unexpected,
        }
    }

    /// The settings as the driver reports them, which is not necessarily what
    /// was asked for: a driver may round a rate to the nearest it can divide
    /// down to, and is free to ignore what it does not support. A
    /// pseudo-terminal, for one, always reports eight bits and no parity.
    pub fn current(port: *Port) types.ConfigureError!Settings {
        return decode(try port.get());
    }

    fn get(port: *Port) types.ConfigureError!Termios2 {
        var t: Termios2 = undefined;
        return switch (linux.errno(linux.ioctl(port.handle, linux.T.CGETS2, @intFromPtr(&t)))) {
            .SUCCESS => t,
            .IO => error.InputOutput,
            else => error.Unexpected,
        };
    }

    pub fn read(port: *Port, buf: []u8) types.ReadError!usize {
        while (true) {
            const rc = linux.read(port.handle, buf.ptr, buf.len);
            return switch (linux.errno(rc)) {
                .SUCCESS => rc,
                .INTR => continue,
                .AGAIN => error.WouldBlock,
                .IO => error.InputOutput,
                else => error.Unexpected,
            };
        }
    }

    pub fn write(port: *Port, bytes: []const u8) types.WriteError!usize {
        while (true) {
            const rc = linux.write(port.handle, bytes.ptr, bytes.len);
            return switch (linux.errno(rc)) {
                .SUCCESS => rc,
                .INTR => continue,
                .AGAIN => error.WouldBlock,
                .IO => error.InputOutput,
                else => error.Unexpected,
            };
        }
    }

    /// Waits until everything written has left the driver's buffer.
    ///
    /// That is not the same as having left the UART: the last character or
    /// two may still be shifting out of the hardware FIFO when this returns.
    pub fn drain(port: *Port) types.WriteError!void {
        // TCSBRK with a non-zero argument is tcdrain(3).
        while (true) {
            return switch (linux.errno(linux.ioctl(port.handle, linux.T.CSBRK, 1))) {
                .SUCCESS => {},
                .INTR => continue,
                .IO => error.InputOutput,
                else => error.Unexpected,
            };
        }
    }

    pub fn flush(port: *Port, queue: types.Queue) types.ConfigureError!void {
        const arg: usize = switch (queue) {
            .input => TCIFLUSH,
            .output => TCOFLUSH,
            .both => TCIOFLUSH,
        };
        return switch (linux.errno(linux.ioctl(port.handle, linux.T.CFLSH, arg))) {
            .SUCCESS => {},
            .IO => error.InputOutput,
            else => error.Unexpected,
        };
    }

    /// Holds the line at space for between a quarter and half a second.
    pub fn sendBreak(port: *Port) types.WriteError!void {
        // TCSBRK with a zero argument is tcsendbreak(fd, 0).
        return switch (linux.errno(linux.ioctl(port.handle, linux.T.CSBRK, 0))) {
            .SUCCESS => {},
            .IO => error.InputOutput,
            else => error.Unexpected,
        };
    }

    pub fn modem(port: *Port) types.LineError!types.Modem {
        var bits: c_int = 0;
        return switch (linux.errno(linux.ioctl(port.handle, linux.T.IOCMGET, @intFromPtr(&bits)))) {
            .SUCCESS => .{
                .dtr = bits & TIOCM_DTR != 0,
                .rts = bits & TIOCM_RTS != 0,
                .cts = bits & TIOCM_CTS != 0,
                .dsr = bits & TIOCM_DSR != 0,
                .dcd = bits & TIOCM_CAR != 0,
                .ri = bits & TIOCM_RNG != 0,
            },
            .NOTTY, .INVAL => error.Unsupported,
            .IO => error.InputOutput,
            else => error.Unexpected,
        };
    }

    pub fn setLine(port: *Port, line: types.Line, on: bool) types.LineError!void {
        const bits: c_int = switch (line) {
            .dtr => TIOCM_DTR,
            .rts => TIOCM_RTS,
        };
        const request: u32 = if (on) linux.T.IOCMBIS else linux.T.IOCMBIC;
        return switch (linux.errno(linux.ioctl(port.handle, request, @intFromPtr(&bits)))) {
            .SUCCESS => {},
            .NOTTY, .INVAL => error.Unsupported,
            .IO => error.InputOutput,
            else => error.Unexpected,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests, against a pseudo-terminal: the far side of a pty pair stands in for
// whatever would be at the other end of the cable.
// ---------------------------------------------------------------------------

const testing = std.testing;

const PtyPair = struct {
    master: Handle,
    path_buf: [32]u8,
    path_len: usize,

    fn open() !PtyPair {
        const rc = linux.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0);
        if (linux.errno(rc) != .SUCCESS) return error.SkipZigTest;
        const master: Handle = @intCast(rc);
        errdefer _ = linux.close(master);
        var unlock: c_int = 0;
        if (linux.errno(linux.ioctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock))) != .SUCCESS)
            return error.SkipZigTest;
        var n: c_uint = 0;
        if (linux.errno(linux.ioctl(master, linux.T.IOCGPTN, @intFromPtr(&n))) != .SUCCESS)
            return error.SkipZigTest;
        var pair: PtyPair = .{ .master = master, .path_buf = undefined, .path_len = 0 };
        pair.path_len = (try std.mem.print(&pair.path_buf, "/dev/pts/{d}", .{n})).len;
        return pair;
    }

    fn path(pair: *const PtyPair) []const u8 {
        return pair.path_buf[0..pair.path_len];
    }

    fn close(pair: *PtyPair) void {
        _ = linux.close(pair.master);
    }
};

test "every setting survives encoding and decoding" {
    const cases = [_]Settings{
        .{},
        .{ .baud = 9600, .data_bits = .seven, .parity = .even, .stop_bits = .two },
        .{ .baud = 300, .data_bits = .five, .parity = .odd, .flow = .rts_cts, .hang_up_on_close = false },
        .{ .baud = 31250, .data_bits = .six, .parity = .mark, .flow = .xon_xoff, .local = false },
        .{ .baud = 4_000_000, .parity = .space },
    };
    for (cases) |want| {
        var t = std.mem.zeroes(Termios2);
        try encode(&t, want);
        try testing.expectEqual(want, decode(t));
        // Raw: nothing that would edit, echo or translate.
        try testing.expectEqual(@as(u32, 0), t.lflag & (ICANON | ECHO | ISIG | IEXTEN));
        try testing.expectEqual(@as(u32, 0), t.oflag & OPOST);
        try testing.expectEqual(@as(u32, 0), t.iflag & (ICRNL | INLCR | IGNCR | ISTRIP));
        try testing.expectEqual(BOTHER, t.cflag & CBAUD);
        try testing.expectEqual(@as(u8, 1), t.cc[VMIN]);
    }
}

test "what cannot be expressed is refused" {
    var t = std.mem.zeroes(Termios2);
    try testing.expectError(error.UnsupportedSetting, encode(&t, .{ .stop_bits = .one_and_half }));
    try testing.expectError(error.UnsupportedSetting, encode(&t, .{ .flow = .other }));
}

test "a setting a pty keeps survives a round trip through the driver" {
    var pair = try PtyPair.open();
    defer pair.close();

    var port = try Port.open(pair.path(), .{
        .baud = 9600,
        .stop_bits = .two,
        .flow = .rts_cts,
        .hang_up_on_close = false,
    }, .{});
    defer port.close();

    const got = try port.current();
    try testing.expectEqual(@as(u32, 9600), got.baud);
    try testing.expectEqual(types.StopBits.two, got.stop_bits);
    try testing.expectEqual(types.Flow.rts_cts, got.flow);
    try testing.expect(!got.hang_up_on_close);
    try testing.expect(got.local);

    try port.configure(.{ .flow = .xon_xoff });
    try testing.expectEqual(types.Flow.xon_xoff, (try port.current()).flow);
}

test "a rate with no Bnnn code is asked for by number" {
    var pair = try PtyPair.open();
    defer pair.close();

    var port = try Port.open(pair.path(), .{ .baud = 31250 }, .{});
    defer port.close();
    try testing.expectEqual(@as(u32, 31250), (try port.current()).baud);
}

test "bytes cross in both directions untranslated" {
    var pair = try PtyPair.open();
    defer pair.close();

    var port = try Port.open(pair.path(), .{}, .{ .nonblocking = false });
    defer port.close();

    // A CR, an LF and a ^C: each of which a cooked tty would act on.
    const out = "a\rb\nc\x03";
    try testing.expectEqual(out.len, try port.write(out));
    var buf: [16]u8 = undefined;
    const n = linux.read(pair.master, &buf, buf.len);
    try testing.expectEqualStrings(out, buf[0..n]);

    const in = "x\ry\x04";
    _ = linux.write(pair.master, in, in.len);
    try testing.expectEqualStrings(in, buf[0..try port.read(&buf)]);
}

test "a non-blocking read with nothing waiting says so" {
    var pair = try PtyPair.open();
    defer pair.close();

    var port = try Port.open(pair.path(), .{}, .{});
    defer port.close();
    var buf: [4]u8 = undefined;
    try testing.expectError(error.WouldBlock, port.read(&buf));
}

test "an exclusive port refuses a second opener" {
    var pair = try PtyPair.open();
    defer pair.close();

    var port = try Port.open(pair.path(), .{}, .{});
    defer port.close();
    try testing.expectError(error.Busy, Port.open(pair.path(), .{}, .{}));
}

test "the original settings come back on close" {
    var pair = try PtyPair.open();
    defer pair.close();

    var before: Termios2 = undefined;
    _ = linux.ioctl(pair.master, linux.T.CGETS2, @intFromPtr(&before));

    var port = try Port.open(pair.path(), .{ .baud = 1200, .parity = .odd }, .{});
    port.close();

    var after: Termios2 = undefined;
    _ = linux.ioctl(pair.master, linux.T.CGETS2, @intFromPtr(&after));
    try testing.expectEqual(before.cflag, after.cflag);
    try testing.expectEqual(before.lflag, after.lflag);
    try testing.expectEqual(before.ospeed, after.ospeed);
}

test "what is not a terminal is refused" {
    try testing.expectError(error.NotASerialPort, Port.open("/dev/null", .{}, .{}));
    try testing.expectError(error.FileNotFound, Port.open("/dev/does-not-exist", .{}, .{}));
}

test "a pty has no modem lines" {
    var pair = try PtyPair.open();
    defer pair.close();

    var port = try Port.open(pair.path(), .{}, .{});
    defer port.close();
    try testing.expectError(error.Unsupported, port.modem());
    try testing.expectError(error.Unsupported, port.setLine(.dtr, false));
}
