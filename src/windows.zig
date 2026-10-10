// SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
// SPDX-License-Identifier: MIT

//! The Windows backend, on the `DCB`.
//!
//! There is no `termios` and no line discipline here. A port's framing is a
//! `DCB`, read and written whole with `GetCommState` and `SetCommState`, so
//! raw mode amounts to switching off the few substitutions a `DCB` can make.
//! Three things differ from Linux in ways a caller can see:
//!
//!   * **Any rate and every parity are ordinary values**, and one and a half
//!     stop bits can be asked for.
//!   * **What a read does when the line is quiet is a property of the port**,
//!     set with `COMMTIMEOUTS`, not of the call. `nonblocking` picks between
//!     "return what has arrived, possibly nothing" and "wait for at least one
//!     byte".
//!   * **DTR and RTS cannot be read back.** `GetCommModemStatus` reports the
//!     four inputs only, so `modem` reports the outputs as this port last set
//!     them.
//!
//! The kernel32 declarations are written out below rather than taken from a
//! binding package: there are fifteen of them.

const std = @import("std");
const windows = std.os.windows;

const types = @import("types.zig");
const Settings = types.Settings;

pub const Handle = windows.HANDLE;

const BOOL = windows.BOOL;
const DWORD = u32;
const WORD = u16;
const BYTE = u8;

const Dcb = extern struct {
    DCBlength: DWORD = @sizeOf(Dcb),
    BaudRate: DWORD = 0,
    flags: Flags = .{},
    wReserved: WORD = 0,
    XonLim: WORD = 0,
    XoffLim: WORD = 0,
    ByteSize: BYTE = 0,
    Parity: BYTE = 0,
    StopBits: BYTE = 0,
    XonChar: u8 = 0,
    XoffChar: u8 = 0,
    ErrorChar: u8 = 0,
    EofChar: u8 = 0,
    EvtChar: u8 = 0,
    wReserved1: WORD = 0,
};

comptime {
    std.debug.assert(@sizeOf(Dcb) == 28);
}

/// The `DCB`'s bitfield, in the order the Windows SDK declares it.
const Flags = packed struct(DWORD) {
    fBinary: bool = false,
    fParity: bool = false,
    fOutxCtsFlow: bool = false,
    fOutxDsrFlow: bool = false,
    fDtrControl: u2 = 0,
    fDsrSensitivity: bool = false,
    fTXContinueOnXoff: bool = false,
    fOutX: bool = false,
    fInX: bool = false,
    fErrorChar: bool = false,
    fNull: bool = false,
    fRtsControl: u2 = 0,
    fAbortOnError: bool = false,
    fDummy2: u17 = 0,
};

const DTR_CONTROL_DISABLE = 0;
const DTR_CONTROL_ENABLE = 1;
const RTS_CONTROL_ENABLE = 1;
const RTS_CONTROL_HANDSHAKE = 2;

const NOPARITY = 0;
const ODDPARITY = 1;
const EVENPARITY = 2;
const MARKPARITY = 3;
const SPACEPARITY = 4;

const ONESTOPBIT = 0;
const ONE5STOPBITS = 1;
const TWOSTOPBITS = 2;

const CommTimeouts = extern struct {
    ReadIntervalTimeout: DWORD,
    ReadTotalTimeoutMultiplier: DWORD,
    ReadTotalTimeoutConstant: DWORD,
    WriteTotalTimeoutMultiplier: DWORD,
    WriteTotalTimeoutConstant: DWORD,
};

const MAXDWORD = std.math.maxInt(DWORD);

const PURGE_TXCLEAR = 0x4;
const PURGE_RXCLEAR = 0x8;

const SETRTS = 3;
const CLRRTS = 4;
const SETDTR = 5;
const CLRDTR = 6;

const MS_CTS_ON = 0x10;
const MS_DSR_ON = 0x20;
const MS_RING_ON = 0x40;
const MS_RLSD_ON = 0x80;

const GENERIC_READ = 0x80000000;
const GENERIC_WRITE = 0x40000000;
const OPEN_EXISTING = 3;
const INVALID_HANDLE_VALUE: Handle = @ptrFromInt(std.math.maxInt(usize));

const ERROR_FILE_NOT_FOUND = 2;
const ERROR_PATH_NOT_FOUND = 3;
const ERROR_ACCESS_DENIED = 5;
const ERROR_SHARING_VIOLATION = 32;
const ERROR_INVALID_PARAMETER = 87;
const ERROR_INVALID_NAME = 123;

extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?Handle,
) callconv(.winapi) Handle;
extern "kernel32" fn CloseHandle(hObject: Handle) callconv(.winapi) BOOL;
extern "kernel32" fn ReadFile(hFile: Handle, lpBuffer: [*]u8, nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(hFile: Handle, lpBuffer: [*]const u8, nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: ?*DWORD, lpOverlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn FlushFileBuffers(hFile: Handle) callconv(.winapi) BOOL;
extern "kernel32" fn GetCommState(hFile: Handle, lpDCB: *Dcb) callconv(.winapi) BOOL;
extern "kernel32" fn SetCommState(hFile: Handle, lpDCB: *const Dcb) callconv(.winapi) BOOL;
extern "kernel32" fn GetCommTimeouts(hFile: Handle, lpCommTimeouts: *CommTimeouts) callconv(.winapi) BOOL;
extern "kernel32" fn SetCommTimeouts(hFile: Handle, lpCommTimeouts: *const CommTimeouts) callconv(.winapi) BOOL;
extern "kernel32" fn PurgeComm(hFile: Handle, dwFlags: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn SetCommBreak(hFile: Handle) callconv(.winapi) BOOL;
extern "kernel32" fn ClearCommBreak(hFile: Handle) callconv(.winapi) BOOL;
extern "kernel32" fn EscapeCommFunction(hFile: Handle, dwFunc: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetCommModemStatus(hFile: Handle, lpModemStat: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;

fn ok(b: BOOL) bool {
    return @backingInt(b) != 0;
}

pub const Port = struct {
    handle: Handle,
    original_dcb: Dcb,
    original_timeouts: CommTimeouts,
    /// See the module documentation: the outputs cannot be read back.
    dtr: bool = true,
    rts: bool = true,

    /// `path` is a device name, `COM3`, or a full `\\.\COM10`; the `\\.\`
    /// prefix is added when it is missing, since without it `COM10` and above
    /// do not open.
    pub fn open(path: []const u8, settings: Settings, options: types.OpenOptions) types.OpenError!Port {
        const prefix = "\\\\.\\";
        var name_buf: [260]u16 = undefined;
        var len: usize = 0;
        if (!std.mem.startsWith(u8, path, prefix)) {
            for (prefix) |c| {
                name_buf[len] = c;
                len += 1;
            }
        }
        if (len + path.len >= name_buf.len) return error.NameTooLong;
        len += std.unicode.utf8ToUtf16Le(name_buf[len .. name_buf.len - 1], path) catch return error.FileNotFound;
        name_buf[len] = 0;

        // A serial port cannot be shared, whatever is asked, so `exclusive`
        // has nothing to add.
        const handle = CreateFileW(@ptrCast(&name_buf), GENERIC_READ | GENERIC_WRITE, 0, null, OPEN_EXISTING, 0, null);
        if (handle == INVALID_HANDLE_VALUE) return switch (GetLastError()) {
            ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND => error.FileNotFound,
            ERROR_ACCESS_DENIED, ERROR_SHARING_VIOLATION => error.Busy,
            ERROR_INVALID_NAME => error.FileNotFound,
            else => error.Unexpected,
        };
        errdefer _ = CloseHandle(handle);

        var port: Port = .{ .handle = handle, .original_dcb = .{}, .original_timeouts = undefined };
        if (!ok(GetCommState(handle, &port.original_dcb))) return error.NotASerialPort;
        if (!ok(GetCommTimeouts(handle, &port.original_timeouts))) return error.NotASerialPort;

        // Return what has arrived, at once, possibly nothing — or wait for the
        // first byte and then return what has arrived. These are the two
        // documented COMMTIMEOUTS recipes; all zeros, which looks like the
        // second, instead waits until the whole buffer is full.
        const timeouts: CommTimeouts = if (options.nonblocking)
            .{ .ReadIntervalTimeout = MAXDWORD, .ReadTotalTimeoutMultiplier = 0, .ReadTotalTimeoutConstant = 0, .WriteTotalTimeoutMultiplier = 0, .WriteTotalTimeoutConstant = 0 }
        else
            .{ .ReadIntervalTimeout = MAXDWORD, .ReadTotalTimeoutMultiplier = MAXDWORD, .ReadTotalTimeoutConstant = MAXDWORD - 1, .WriteTotalTimeoutMultiplier = 0, .WriteTotalTimeoutConstant = 0 };
        if (!ok(SetCommTimeouts(handle, &timeouts))) return error.Unexpected;

        try port.configure(settings);
        return port;
    }

    pub fn close(port: *Port) void {
        _ = SetCommState(port.handle, &port.original_dcb);
        _ = SetCommTimeouts(port.handle, &port.original_timeouts);
        _ = CloseHandle(port.handle);
        port.* = undefined;
    }

    pub fn configure(port: *Port, settings: Settings) types.ConfigureError!void {
        var dcb: Dcb = .{};
        if (!ok(GetCommState(port.handle, &dcb))) return error.InputOutput;

        dcb.BaudRate = settings.baud;
        dcb.ByteSize = @backingInt(settings.data_bits);
        dcb.Parity = switch (settings.parity) {
            .none => NOPARITY,
            .even => EVENPARITY,
            .odd => ODDPARITY,
            .mark => MARKPARITY,
            .space => SPACEPARITY,
        };
        dcb.StopBits = switch (settings.stop_bits) {
            .one => ONESTOPBIT,
            .one_and_half => ONE5STOPBITS,
            .two => TWOSTOPBITS,
        };

        var f = dcb.flags;
        // Win32 accepts no other value.
        f.fBinary = true;
        f.fParity = settings.parity != .none;
        // No substitutions, no dropped NULs, and no stopping dead on a
        // framing error until somebody calls ClearCommError.
        f.fErrorChar = false;
        f.fNull = false;
        f.fAbortOnError = false;
        f.fDsrSensitivity = false;
        f.fOutxDsrFlow = false;
        f.fTXContinueOnXoff = false;
        f.fDtrControl = if (port.dtr) DTR_CONTROL_ENABLE else DTR_CONTROL_DISABLE;
        switch (settings.flow) {
            .none => {
                f.fOutxCtsFlow = false;
                f.fOutX = false;
                f.fInX = false;
                f.fRtsControl = if (port.rts) RTS_CONTROL_ENABLE else 0;
            },
            .rts_cts => {
                f.fOutxCtsFlow = true;
                f.fOutX = false;
                f.fInX = false;
                f.fRtsControl = RTS_CONTROL_HANDSHAKE;
            },
            .xon_xoff => {
                f.fOutxCtsFlow = false;
                f.fOutX = true;
                f.fInX = true;
                f.fRtsControl = if (port.rts) RTS_CONTROL_ENABLE else 0;
                dcb.XonChar = 0x11;
                dcb.XoffChar = 0x13;
            },
            .other => return error.UnsupportedSetting,
        }
        dcb.flags = f;
        dcb.ErrorChar = 0;
        dcb.EofChar = 0;
        dcb.EvtChar = 0;

        if (!ok(SetCommState(port.handle, &dcb))) return switch (GetLastError()) {
            ERROR_INVALID_PARAMETER => error.UnsupportedBaud,
            else => error.Unexpected,
        };
    }

    pub fn current(port: *Port) types.ConfigureError!Settings {
        var dcb: Dcb = .{};
        if (!ok(GetCommState(port.handle, &dcb))) return error.InputOutput;
        const f = dcb.flags;
        const rtscts = f.fOutxCtsFlow and f.fRtsControl == RTS_CONTROL_HANDSHAKE;
        const xonxoff = f.fOutX and f.fInX;
        return .{
            .baud = dcb.BaudRate,
            .data_bits = switch (dcb.ByteSize) {
                5 => .five,
                6 => .six,
                7 => .seven,
                else => .eight,
            },
            .parity = switch (dcb.Parity) {
                ODDPARITY => .odd,
                EVENPARITY => .even,
                MARKPARITY => .mark,
                SPACEPARITY => .space,
                else => .none,
            },
            .stop_bits = switch (dcb.StopBits) {
                ONE5STOPBITS => .one_and_half,
                TWOSTOPBITS => .two,
                else => .one,
            },
            .flow = if (f.fOutxDsrFlow)
                .other
            else if (rtscts and !f.fOutX and !f.fInX)
                .rts_cts
            else if (xonxoff and !f.fOutxCtsFlow)
                .xon_xoff
            else if (!f.fOutxCtsFlow and !f.fOutX and !f.fInX)
                .none
            else
                .other,
            // Windows lowers DTR on close whatever is asked, and a port is
            // never waiting on carrier.
            .hang_up_on_close = true,
            .local = true,
        };
    }

    pub fn read(port: *Port, buf: []u8) types.ReadError!usize {
        var n: DWORD = 0;
        const len: DWORD = @intCast(@min(buf.len, MAXDWORD));
        if (!ok(ReadFile(port.handle, buf.ptr, len, &n, null))) return error.InputOutput;
        // A timeout reads as success with nothing read; there is no end of
        // file on a serial port to confuse it with.
        if (n == 0 and buf.len != 0) return error.WouldBlock;
        return n;
    }

    pub fn write(port: *Port, bytes: []const u8) types.WriteError!usize {
        var n: DWORD = 0;
        const len: DWORD = @intCast(@min(bytes.len, MAXDWORD));
        if (!ok(WriteFile(port.handle, bytes.ptr, len, &n, null))) return error.InputOutput;
        return n;
    }

    pub fn drain(port: *Port) types.WriteError!void {
        if (!ok(FlushFileBuffers(port.handle))) return error.InputOutput;
    }

    pub fn flush(port: *Port, queue: types.Queue) types.ConfigureError!void {
        const flags: DWORD = switch (queue) {
            .input => PURGE_RXCLEAR,
            .output => PURGE_TXCLEAR,
            .both => PURGE_RXCLEAR | PURGE_TXCLEAR,
        };
        if (!ok(PurgeComm(port.handle, flags))) return error.InputOutput;
    }

    /// Win32 has no timed break, only a start and a stop; a quarter of a
    /// second between them matches what Linux sends.
    pub fn sendBreak(port: *Port) types.WriteError!void {
        if (!ok(SetCommBreak(port.handle))) return error.InputOutput;
        Sleep(250);
        if (!ok(ClearCommBreak(port.handle))) return error.InputOutput;
    }

    pub fn modem(port: *Port) types.LineError!types.Modem {
        var status: DWORD = 0;
        if (!ok(GetCommModemStatus(port.handle, &status))) return error.Unsupported;
        return .{
            .dtr = port.dtr,
            .rts = port.rts,
            .cts = status & MS_CTS_ON != 0,
            .dsr = status & MS_DSR_ON != 0,
            .dcd = status & MS_RLSD_ON != 0,
            .ri = status & MS_RING_ON != 0,
        };
    }

    pub fn setLine(port: *Port, line: types.Line, on: bool) types.LineError!void {
        const func: DWORD = switch (line) {
            .dtr => if (on) SETDTR else CLRDTR,
            .rts => if (on) SETRTS else CLRRTS,
        };
        if (!ok(EscapeCommFunction(port.handle, func))) return error.Unsupported;
        switch (line) {
            .dtr => port.dtr = on,
            .rts => port.rts = on,
        }
    }
};
