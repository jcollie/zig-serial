<!--
SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
SPDX-License-Identifier: MIT
-->

# zig-serial

Serial ports for Zig 0.17: open one, set its rate and framing, read and write
it, and drive its modem lines.

```zig
const serial = @import("serial");

var port = try serial.Port.open("/dev/ttyUSB0", .{ .baud = 9600 }, .{});
defer port.close();

_ = try port.write("AT\r");
var buf: [256]u8 = undefined;
const n = try port.read(&buf);
```

The API documentation is generated from the doc comments and published at
**<https://jeff.jcollie.page/zig-serial/>**.

## What a `Port` does

- **Raw mode.** Opening a port puts it into raw mode, so that what is written
  is what goes on the wire and what arrives is what is read: no echo, no line
  editing, no newline translation, no signals. Closing it puts back the
  settings the device had before.
- **Settings.** `Settings` holds the rate, data bits, parity (including mark
  and space), stop bits, flow control (RTS/CTS or XON/XOFF), hang-up-on-close
  and `CLOCAL`. `configure` applies all of them in one call, so the line never
  runs at a mix of the old configuration and the new.
- **What the driver actually chose.** `current` reads the settings back from
  the driver, which may differ from what was asked: a driver can round a rate
  it cannot divide down to.
- **Modem lines and line control.** `modem` reads the modem lines and `setLine`
  raises or lowers DTR and RTS. `sendBreak`, `drain` and `flush` do what their
  names say.
- **Exclusive by default.** On Linux an advisory `flock` and `TIOCEXCL` keep a
  second program off the port; on Windows a port is always exclusive.
- **Non-blocking by default.** `read` and `write` return `error.WouldBlock`
  rather than waiting, which is what an event loop polling `Port.handle`
  wants. Pass `.nonblocking = false` for a thread that does nothing but read.

## Platforms

- **Linux.** Built on raw system calls with no libc. It uses `termios2`
  (`TCGETS2`/`TCSETS2`) with `BOTHER`, so every rate is asked for by number and
  a rate like 31250 needs no special case. The asm-generic `termios2` layout is
  the only one written out: MIPS, PowerPC, SPARC and Alpha lay the structure
  out differently and are refused at compile time.
- **Windows.** Uses the `DCB` and `COMMTIMEOUTS` through kernel32, declared in
  the source rather than taken from a bindings package. Every rate, every
  parity, and one and a half stop bits are ordinary values. DTR and RTS cannot
  be read back on Windows, so `modem` reports them as this port last set them.
  This backend is compiled by `zig build check` but has not been run against
  hardware.
- **The BSDs and macOS** have no backend yet. They want one on their libc
  `termios`, with `IOSSIOSPEED` on macOS for arbitrary rates.

## Testing

```console
$ nix develop -c zig build test --summary all
$ nix develop -c zig build check   # Windows and aarch64-linux, compiled only
```

The tests use pseudo-terminals in place of a cable. A pty cannot test
everything, because it always reports eight data bits and no parity whatever it
is told. So the conversion between `Settings` and `termios2` is tested on its
own, in memory, and the pty tests cover what a pty does keep: the rate, the
stop bits, flow control, raw data in both directions, exclusivity, and the
restoring of the original settings on close.

## Where this came from

[zettacom](https://git.jcollie.dev/jeff/zettacom) has a serial layer of its
own, but most of it is ported from picocom and is GPL. zig-serial is a fresh
MIT implementation, written from the interfaces in the references below, so
that MIT programs — the [harrier](https://git.jcollie.dev/jeff/harrier)
terminal among them — can use it.

## Repository

The canonical repository is on my Forgejo instance, and Tangled carries a
mirror of it:

```console
git clone https://git.jcollie.dev/jeff/zig-serial.git
```

- Forgejo: <https://git.jcollie.dev/jeff/zig-serial>
- Tangled: <https://tangled.org/jcollie.dev/zig-serial>

CI and the published documentation come from the Forgejo repository.

## License

MIT; see [LICENSES/MIT.txt](LICENSES/MIT.txt). The project follows the
[REUSE](https://reuse.software/) specification, and `reuse lint` passes.

## References cited

- The Linux man-pages project. *flock(2) — apply or remove an advisory lock on
  an open file*. Linux manual pages. <https://man7.org/linux/man-pages/man2/flock.2.html>
- The Linux man-pages project. *ioctl_tty(2) — ioctls for terminals and serial
  lines*. Linux manual pages. <https://man7.org/linux/man-pages/man2/ioctl_tty.2.html>
- The Linux man-pages project. *pts(4) — pseudoterminal master and slave*.
  Linux manual pages. <https://man7.org/linux/man-pages/man4/pts.4.html>
- The Linux man-pages project. *termios(3) — get and set terminal attributes,
  line control, get and set baud rate*. Linux manual pages.
  <https://man7.org/linux/man-pages/man3/termios.3.html>
- Microsoft. *COMMTIMEOUTS structure (winbase.h)*. Microsoft Learn.
  <https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-commtimeouts>
- Microsoft. *DCB structure (winbase.h)*. Microsoft Learn.
  <https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-dcb>
- The Open Group. *The Open Group Base Specifications Issue 8, Chapter 11:
  General Terminal Interface*. IEEE Std 1003.1-2024.
  <https://pubs.opengroup.org/onlinepubs/9799919799/basedefs/V1_chap11.html>
- Free Software Foundation Europe. *REUSE Specification* (Version 3.3).
  <https://reuse.software/spec-3.3/>
- Zig Software Foundation. *The Zig programming language* [Computer software].
  <https://ziglang.org/>
