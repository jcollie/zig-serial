// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The backend for macOS and the BSDs — FreeBSD, NetBSD, OpenBSD and
//! DragonFly — on their libc `termios`.
//!
//! All five inherit 4.4BSD's terminal interface, so one file covers them,
//! and the few places they part company are switched on below. The useful
//! inheritance is that a `speed_t` *is* the rate: `B9600` is 9600, so any
//! rate can be written into `c_ospeed` by number and it is up to the driver
//! whether it can produce it. FreeBSD's `uart(4)` divides down to whatever
//! is asked; macOS's serial drivers refuse a rate outside the traditional
//! table through `tcsetattr`, and take one through the `IOSSIOSPEED` ioctl
//! instead, which `configure` falls back to.
//!
//! Three things differ from Linux in ways a caller can see:
//!
//!   * **No mark or space parity.** There is no `CMSPAR`, so those are
//!     refused as `error.UnsupportedSetting`, as one and a half stop bits
//!     are.
//!   * **On macOS, use `/dev/cu.*` rather than `/dev/tty.*`.** The `tty`
//!     node is the dial-in side, which waits for carrier before it lets
//!     anyone else in. A `Port` opens non-blocking, so it will not hang
//!     there, but the `cu` node is the one meant for calling out.
//!   * **A pseudo-terminal has modem lines, of a sort.** FreeBSD answers
//!     `TIOCMGET` on a pty with a fixed set of lines rather than refusing
//!     it, so `modem` working is no proof that a cable is attached.
//!
//! The structure and the constants are written out here rather than taken
//! from `std.c`, whose `speed_t` is an exhaustive enum with no room for a
//! rate like 31250, and whose `ioctl` takes its request as a signed `int`
//! where these systems want an `unsigned long`.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

const types = @import("types.zig");
const Settings = types.Settings;

pub const Handle = c.fd_t;

const os = builtin.target.os.tag;
const is_darwin = os.isDarwin();

comptime {
    switch (os) {
        .freebsd, .netbsd, .openbsd, .dragonfly => {},
        else => if (!is_darwin) @compileError("the BSD backend does not know " ++ @tagName(os)),
    }
}

/// `tcflag_t` and `speed_t`: an `unsigned long` on Darwin, an `unsigned int`
/// on the BSDs.
const Flag = if (is_darwin) c_ulong else c_uint;
const Speed = Flag;

/// `struct termios` from `<sys/termios.h>`, the same shape on all five.
const Termios = extern struct {
    iflag: Flag,
    oflag: Flag,
    cflag: Flag,
    lflag: Flag,
    cc: [20]u8,
    ispeed: Speed,
    ospeed: Speed,
};

// `c_iflag`
const IGNBRK: Flag = 0x1;
const BRKINT: Flag = 0x2;
const IGNPAR: Flag = 0x4;
const PARMRK: Flag = 0x8;
const INPCK: Flag = 0x10;
const ISTRIP: Flag = 0x20;
const INLCR: Flag = 0x40;
const IGNCR: Flag = 0x80;
const ICRNL: Flag = 0x100;
const IXON: Flag = 0x200;
const IXOFF: Flag = 0x400;
const IXANY: Flag = 0x800;
/// OpenBSD alone kept the upper-to-lower-case mapping.
const IUCLC: Flag = if (os == .openbsd) 0x1000 else 0;
const IMAXBEL: Flag = 0x2000;

// `c_oflag`
const OPOST: Flag = 0x1;

// `c_cflag`
const CSIZE: Flag = 0x300;
const CS5: Flag = 0x000;
const CS6: Flag = 0x100;
const CS7: Flag = 0x200;
const CS8: Flag = 0x300;
const CSTOPB: Flag = 0x400;
const CREAD: Flag = 0x800;
const PARENB: Flag = 0x1000;
const PARODD: Flag = 0x2000;
const HUPCL: Flag = 0x4000;
const CLOCAL: Flag = 0x8000;
/// Two bits on Darwin, FreeBSD and DragonFly, `CCTS_OFLOW | CRTS_IFLOW`,
/// which can be set apart; one bit on NetBSD and OpenBSD, where those two
/// names are both aliases for it.
const CRTSCTS: Flag = switch (os) {
    .netbsd, .openbsd => 0x10000,
    else => 0x30000,
};

// `c_lflag`
const ECHOE: Flag = 0x2;
const ECHOK: Flag = 0x4;
const ECHO: Flag = 0x8;
const ECHONL: Flag = 0x10;
const ISIG: Flag = 0x80;
const ICANON: Flag = 0x100;
const IEXTEN: Flag = 0x400;

// `c_cc` indices
const VSTART = 12;
const VSTOP = 13;
const VMIN = 16;
const VTIME = 17;

// `tcsetattr` actions and `tcflush` queues
const TCSANOW = 0;
const TCIFLUSH = 1;
const TCOFLUSH = 2;
const TCIOFLUSH = 3;

// `flock` operations
const LOCK_EX = 2;
const LOCK_NB = 4;

// The ioctls, from `<sys/ttycom.h>`, which every one of these encodes the
// same way.
const IOC_VOID: c_ulong = 0x20000000;
const IOC_OUT: c_ulong = 0x40000000;
const IOC_IN: c_ulong = 0x80000000;

fn ioc(inout: c_ulong, group: u8, num: u8, len: usize) c_ulong {
    return inout | ((@as(c_ulong, len) & 0x1fff) << 16) | (@as(c_ulong, group) << 8) | num;
}

const TIOCEXCL = ioc(IOC_VOID, 't', 13, 0);
const TIOCNXCL = ioc(IOC_VOID, 't', 14, 0);
const TIOCMGET = ioc(IOC_OUT, 't', 106, @sizeOf(c_int));
const TIOCMBIC = ioc(IOC_IN, 't', 107, @sizeOf(c_int));
const TIOCMBIS = ioc(IOC_IN, 't', 108, @sizeOf(c_int));
/// Darwin's `IOSSIOSPEED`, from `<IOKit/serial/ioss.h>`: set both rates to
/// the `speed_t` pointed at, whatever it is.
const IOSSIOSPEED = ioc(IOC_IN, 'T', 2, @sizeOf(Speed));

// `TIOCMGET` bits, the same as Linux's.
const TIOCM_DTR = 0x002;
const TIOCM_RTS = 0x004;
const TIOCM_CTS = 0x020;
const TIOCM_CAR = 0x040;
const TIOCM_RNG = 0x080;
const TIOCM_DSR = 0x100;

extern "c" fn ioctl(fd: Handle, request: c_ulong, ...) c_int;
extern "c" fn tcgetattr(fd: Handle, t: *Termios) c_int;
extern "c" fn tcsetattr(fd: Handle, action: c_int, t: *const Termios) c_int;
extern "c" fn tcdrain(fd: Handle) c_int;
extern "c" fn tcflush(fd: Handle, queue: c_int) c_int;
extern "c" fn tcsendbreak(fd: Handle, duration: c_int) c_int;

/// Writes `settings` and raw mode into `t`, leaving alone what neither
/// touches. Kept apart from the libc calls so that it can be tested without
/// a device, for the same reason as on Linux: a pseudo-terminal does not
/// keep everything it is told.
fn encode(t: *Termios, settings: Settings) types.ConfigureError!void {
    // Raw mode, as cfmakeraw(3) describes it.
    t.iflag &= ~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IUCLC | IMAXBEL);
    t.oflag &= ~OPOST;
    t.lflag &= ~(ECHO | ECHOE | ECHOK | ECHONL | ICANON | ISIG | IEXTEN);
    t.cflag |= CREAD;
    // A read returns as soon as there is one byte, and not before.
    t.cc[VMIN] = 1;
    t.cc[VTIME] = 0;

    // cfsetspeed(3) is an assignment on every one of these systems.
    t.ospeed = settings.baud;
    t.ispeed = settings.baud;

    t.cflag &= ~CSIZE;
    t.cflag |= switch (settings.data_bits) {
        .five => CS5,
        .six => CS6,
        .seven => CS7,
        .eight => CS8,
    };

    t.cflag &= ~(PARENB | PARODD);
    t.cflag |= switch (settings.parity) {
        .none => 0,
        .even => PARENB,
        .odd => PARENB | PARODD,
        .mark, .space => return error.UnsupportedSetting,
    };
    // As on Linux: check what arrives when there is a bit to check, and let
    // a character that fails read as NUL.
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

fn decode(t: Termios) Settings {
    const rtscts = t.cflag & CRTSCTS;
    const ixon = t.iflag & IXON != 0;
    const ixoff = t.iflag & IXOFF != 0;
    return .{
        .baud = std.math.cast(u32, t.ospeed) orelse std.math.maxInt(u32),
        .data_bits = switch (t.cflag & CSIZE) {
            CS5 => .five,
            CS6 => .six,
            CS7 => .seven,
            else => .eight,
        },
        .parity = if (t.cflag & PARENB == 0)
            .none
        else if (t.cflag & PARODD != 0)
            .odd
        else
            .even,
        .stop_bits = if (t.cflag & CSTOPB != 0) .two else .one,
        // Only one of Darwin's two hardware flow bits — CTS gating output
        // without RTS gating input, say — is a combination this library
        // does not name.
        .flow = if (rtscts == 0 and !ixon and !ixoff)
            .none
        else if (rtscts == CRTSCTS and !ixon and !ixoff)
            .rts_cts
        else if (rtscts == 0 and ixon and ixoff)
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
    original: Termios,
    exclusive: bool,

    pub fn open(path: []const u8, settings: Settings, options: types.OpenOptions) types.OpenError!Port {
        var path_buf: [c.PATH_MAX]u8 = undefined;
        if (path.len >= path_buf.len) return error.NameTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        // Non-blocking even when the caller wants blocking I/O, for the same
        // reason as on Linux: without CLOCAL an open waits for carrier, and
        // that is the dial-in `/dev/tty.*` node's whole purpose on macOS.
        const fd = c.open(@ptrCast(&path_buf), .{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
            .NONBLOCK = true,
            .CLOEXEC = true,
        });
        switch (c.errno(fd)) {
            .SUCCESS => {},
            .NOENT, .NXIO, .NODEV => return error.FileNotFound,
            .ACCES, .PERM, .ROFS => return error.AccessDenied,
            .BUSY => return error.Busy,
            .ISDIR => return error.NotASerialPort,
            .NAMETOOLONG => return error.NameTooLong,
            .MFILE, .NFILE, .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
        errdefer _ = c.close(fd);

        var original: Termios = undefined;
        switch (c.errno(tcgetattr(fd, &original))) {
            .SUCCESS => {},
            .NOTTY, .INVAL, .OPNOTSUPP => return error.NotASerialPort,
            .IO => return error.InputOutput,
            else => return error.Unexpected,
        }

        if (options.exclusive) {
            // As on Linux: the advisory lock for anything that asks, and
            // TIOCEXCL for everything else short of root.
            switch (c.errno(c.flock(fd, LOCK_EX | LOCK_NB))) {
                .SUCCESS => {},
                .AGAIN => return error.Busy,
                else => return error.Unexpected,
            }
            _ = ioctl(fd, TIOCEXCL);
        }

        var port: Port = .{ .handle = fd, .original = original, .exclusive = options.exclusive };
        try port.configure(settings);

        if (!options.nonblocking) {
            const flags = c.fcntl(fd, c.F.GETFL);
            if (c.errno(flags) != .SUCCESS) return error.Unexpected;
            var o: c.O = @bitCast(@as(u32, @bitCast(flags)));
            o.NONBLOCK = false;
            if (c.errno(c.fcntl(fd, c.F.SETFL, @as(c_int, @bitCast(o)))) != .SUCCESS)
                return error.Unexpected;
        }

        return port;
    }

    /// Puts the device's original settings back and closes it.
    ///
    /// `TCSANOW` rather than the draining `TCSADRAIN`, for the reason given
    /// on Linux: a drain that waits on a far end that is not there never
    /// finishes.
    pub fn close(port: *Port) void {
        _ = tcsetattr(port.handle, TCSANOW, &port.original);
        if (port.exclusive) _ = ioctl(port.handle, TIOCNXCL);
        _ = c.close(port.handle);
        port.* = undefined;
    }

    /// Applies `settings`, along with raw mode, in one `tcsetattr`, so the
    /// line never runs at a mixture of the old configuration and the new.
    ///
    /// On macOS, a rate the driver refuses through `tcsetattr` is tried
    /// again through `IOSSIOSPEED`. That takes two calls: everything else is
    /// applied first at the rate the port already had, and then the rate.
    pub fn configure(port: *Port, settings: Settings) types.ConfigureError!void {
        var t = try port.get();
        const old_ispeed = t.ispeed;
        const old_ospeed = t.ospeed;
        try encode(&t, settings);
        switch (c.errno(tcsetattr(port.handle, TCSANOW, &t))) {
            .SUCCESS => return,
            .INVAL => if (!is_darwin) return error.UnsupportedBaud,
            .IO => return error.InputOutput,
            else => return error.Unexpected,
        }

        t.ispeed = old_ispeed;
        t.ospeed = old_ospeed;
        switch (c.errno(tcsetattr(port.handle, TCSANOW, &t))) {
            .SUCCESS => {},
            // The rate was not what it objected to after all.
            .INVAL => return error.UnsupportedSetting,
            .IO => return error.InputOutput,
            else => return error.Unexpected,
        }
        var speed: Speed = settings.baud;
        switch (c.errno(ioctl(port.handle, IOSSIOSPEED, &speed))) {
            .SUCCESS => {},
            .INVAL, .NOTTY => return error.UnsupportedBaud,
            .IO => return error.InputOutput,
            else => return error.Unexpected,
        }
    }

    /// The settings as the driver reports them, which is not necessarily what
    /// was asked for: a driver may round a rate, and is free to ignore what
    /// it does not support.
    pub fn current(port: *Port) types.ConfigureError!Settings {
        return decode(try port.get());
    }

    fn get(port: *Port) types.ConfigureError!Termios {
        var t: Termios = undefined;
        return switch (c.errno(tcgetattr(port.handle, &t))) {
            .SUCCESS => t,
            .IO => error.InputOutput,
            else => error.Unexpected,
        };
    }

    pub fn read(port: *Port, buf: []u8) types.ReadError!usize {
        while (true) {
            const rc = c.read(port.handle, buf.ptr, buf.len);
            return switch (c.errno(rc)) {
                .SUCCESS => @intCast(rc),
                .INTR => continue,
                .AGAIN => error.WouldBlock,
                .IO => error.InputOutput,
                else => error.Unexpected,
            };
        }
    }

    pub fn write(port: *Port, bytes: []const u8) types.WriteError!usize {
        while (true) {
            const rc = c.write(port.handle, bytes.ptr, bytes.len);
            return switch (c.errno(rc)) {
                .SUCCESS => @intCast(rc),
                .INTR => continue,
                .AGAIN => error.WouldBlock,
                .IO => error.InputOutput,
                else => error.Unexpected,
            };
        }
    }

    /// Waits until everything written has left the driver's buffer, which
    /// is not quite the same as having left the UART.
    pub fn drain(port: *Port) types.WriteError!void {
        while (true) {
            return switch (c.errno(tcdrain(port.handle))) {
                .SUCCESS => {},
                .INTR => continue,
                .IO => error.InputOutput,
                else => error.Unexpected,
            };
        }
    }

    pub fn flush(port: *Port, queue: types.Queue) types.ConfigureError!void {
        const arg: c_int = switch (queue) {
            .input => TCIFLUSH,
            .output => TCOFLUSH,
            .both => TCIOFLUSH,
        };
        return switch (c.errno(tcflush(port.handle, arg))) {
            .SUCCESS => {},
            .IO => error.InputOutput,
            else => error.Unexpected,
        };
    }

    /// Holds the line at space for about four tenths of a second, which is
    /// what these systems' `tcsendbreak` does whatever duration it is given.
    pub fn sendBreak(port: *Port) types.WriteError!void {
        return switch (c.errno(tcsendbreak(port.handle, 0))) {
            .SUCCESS => {},
            .IO => error.InputOutput,
            else => error.Unexpected,
        };
    }

    pub fn modem(port: *Port) types.LineError!types.Modem {
        var bits: c_int = 0;
        return switch (c.errno(ioctl(port.handle, TIOCMGET, &bits))) {
            .SUCCESS => .{
                .dtr = bits & TIOCM_DTR != 0,
                .rts = bits & TIOCM_RTS != 0,
                .cts = bits & TIOCM_CTS != 0,
                .dsr = bits & TIOCM_DSR != 0,
                .dcd = bits & TIOCM_CAR != 0,
                .ri = bits & TIOCM_RNG != 0,
            },
            .NOTTY, .INVAL, .OPNOTSUPP => error.Unsupported,
            .IO => error.InputOutput,
            else => error.Unexpected,
        };
    }

    pub fn setLine(port: *Port, line: types.Line, on: bool) types.LineError!void {
        const bits: c_int = switch (line) {
            .dtr => TIOCM_DTR,
            .rts => TIOCM_RTS,
        };
        return switch (c.errno(ioctl(port.handle, if (on) TIOCMBIS else TIOCMBIC, &bits))) {
            .SUCCESS => {},
            .NOTTY, .INVAL, .OPNOTSUPP => error.Unsupported,
            .IO => error.InputOutput,
            else => error.Unexpected,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests, against a pseudo-terminal, as on Linux.
// ---------------------------------------------------------------------------

const testing = std.testing;

extern "c" fn posix_openpt(oflag: c_int) c_int;
extern "c" fn grantpt(fd: Handle) c_int;
extern "c" fn unlockpt(fd: Handle) c_int;
extern "c" fn ptsname(fd: Handle) ?[*:0]const u8;

const PtyPair = struct {
    master: Handle,
    path_buf: [64]u8,
    path_len: usize,

    fn open() !PtyPair {
        const flags: c.O = .{ .ACCMODE = .RDWR, .NOCTTY = true };
        const master = posix_openpt(@bitCast(flags));
        if (master < 0) return error.SkipZigTest;
        errdefer _ = c.close(master);
        if (grantpt(master) != 0 or unlockpt(master) != 0) return error.SkipZigTest;
        const name = std.mem.span(ptsname(master) orelse return error.SkipZigTest);
        var pair: PtyPair = .{ .master = master, .path_buf = undefined, .path_len = name.len };
        if (name.len > pair.path_buf.len) return error.SkipZigTest;
        @memcpy(pair.path_buf[0..name.len], name);
        return pair;
    }

    fn path(pair: *const PtyPair) []const u8 {
        return pair.path_buf[0..pair.path_len];
    }

    fn close(pair: *PtyPair) void {
        _ = c.close(pair.master);
    }
};

test "every setting survives encoding and decoding" {
    const cases = [_]Settings{
        .{},
        .{ .baud = 9600, .data_bits = .seven, .parity = .even, .stop_bits = .two },
        .{ .baud = 300, .data_bits = .five, .parity = .odd, .flow = .rts_cts, .hang_up_on_close = false },
        .{ .baud = 31250, .data_bits = .six, .flow = .xon_xoff, .local = false },
        .{ .baud = 4_000_000 },
    };
    for (cases) |want| {
        var t = std.mem.zeroes(Termios);
        try encode(&t, want);
        try testing.expectEqual(want, decode(t));
        // Raw: nothing that would edit, echo or translate.
        try testing.expectEqual(@as(Flag, 0), t.lflag & (ICANON | ECHO | ISIG | IEXTEN));
        try testing.expectEqual(@as(Flag, 0), t.oflag & OPOST);
        try testing.expectEqual(@as(Flag, 0), t.iflag & (ICRNL | INLCR | IGNCR | ISTRIP));
        try testing.expectEqual(@as(u8, 1), t.cc[VMIN]);
    }
}

test "what cannot be expressed is refused" {
    var t = std.mem.zeroes(Termios);
    try testing.expectError(error.UnsupportedSetting, encode(&t, .{ .stop_bits = .one_and_half }));
    try testing.expectError(error.UnsupportedSetting, encode(&t, .{ .parity = .mark }));
    try testing.expectError(error.UnsupportedSetting, encode(&t, .{ .parity = .space }));
    try testing.expectError(error.UnsupportedSetting, encode(&t, .{ .flow = .other }));
}

test "half of a two-bit CRTSCTS is a combination with no name" {
    if (CRTSCTS == 0x10000) return error.SkipZigTest;
    var t = std.mem.zeroes(Termios);
    try encode(&t, .{});
    t.cflag |= 0x10000; // CCTS_OFLOW alone
    try testing.expectEqual(types.Flow.other, decode(t).flow);
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

test "bytes cross in both directions untranslated" {
    var pair = try PtyPair.open();
    defer pair.close();

    var port = try Port.open(pair.path(), .{}, .{ .nonblocking = false });
    defer port.close();

    // A CR, an LF and a ^C: each of which a cooked tty would act on.
    const out = "a\rb\nc\x03";
    try testing.expectEqual(out.len, try port.write(out));
    var buf: [16]u8 = undefined;
    const n = c.read(pair.master, &buf, buf.len);
    try testing.expect(n > 0);
    try testing.expectEqualStrings(out, buf[0..@intCast(n)]);

    const in = "x\ry\x04";
    _ = c.write(pair.master, in, in.len);
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

    // Read through a second descriptor on the slave, held open throughout,
    // rather than through the master: FreeBSD's master reports a `c_cflag`
    // of zero until the slave has first been opened.
    var path_buf: [64:0]u8 = @splat(0);
    @memcpy(path_buf[0..pair.path().len], pair.path());
    const held = c.open(&path_buf, .{ .ACCMODE = .RDWR, .NOCTTY = true, .NONBLOCK = true });
    try testing.expect(held >= 0);
    defer _ = c.close(held);

    var before: Termios = undefined;
    try testing.expectEqual(@as(c_int, 0), tcgetattr(held, &before));

    var port = try Port.open(pair.path(), .{ .baud = 1200, .parity = .odd }, .{});
    port.close();

    var after: Termios = undefined;
    try testing.expectEqual(@as(c_int, 0), tcgetattr(held, &after));
    try testing.expectEqual(before.cflag, after.cflag);
    try testing.expectEqual(before.lflag, after.lflag);
    try testing.expectEqual(before.ospeed, after.ospeed);
}

test "what is not a terminal is refused" {
    try testing.expectError(error.NotASerialPort, Port.open("/dev/null", .{}, .{}));
    try testing.expectError(error.FileNotFound, Port.open("/dev/does-not-exist", .{}, .{}));
}

test "a pty's modem lines either answer or say they are not there" {
    var pair = try PtyPair.open();
    defer pair.close();

    var port = try Port.open(pair.path(), .{}, .{});
    defer port.close();
    _ = port.modem() catch |err| try testing.expectEqual(error.Unsupported, err);
    port.setLine(.dtr, false) catch |err| try testing.expectEqual(error.Unsupported, err);
}
