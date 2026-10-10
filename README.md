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
- **Exclusive by default.** On Linux, macOS and the BSDs an advisory `flock`
  and `TIOCEXCL` keep a second program off the port; on Windows a port is
  always exclusive.
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
  Its tests run on GitHub's Windows runners, which have no serial port, so
  they cover the conversion to and from the `DCB` and the refusal of what is
  not a port; the backend has not been run against hardware.
- **macOS, FreeBSD, NetBSD, OpenBSD and DragonFly.** One backend, on the libc
  `termios` all five inherit from 4.4BSD, so a program for these links libc;
  the module asks for it on its own. A `speed_t` there is the rate itself, so
  any rate is asked for by number. A macOS driver that refuses a rate through
  `tcsetattr` is asked again through `IOSSIOSPEED`, which takes two calls
  rather than one. There is no `CMSPAR`, so mark and space parity are refused.
  On macOS, open the `/dev/cu.*` node rather than the dial-in `/dev/tty.*`.
  This backend is compiled by `zig build check` for all five. Its tests run
  on FreeBSD in a virtual machine and on GitHub's macOS runners, both arm64
  and Intel (see below); on NetBSD, OpenBSD and DragonFly they have not yet
  been run.

## Testing

```console
$ nix develop -c zig build test --summary all
$ nix develop -c zig build check   # every other platform, compiled only
$ nix build .#checks.x86_64-linux.freebsd --print-build-logs
```

The last of these runs the tests on FreeBSD. It cross-compiles them for
x86_64-freebsd, boots FreeBSD's own BASIC-CI image under QEMU and KVM, and
hands the machine a NoCloud `cidata` drive holding the test binary and a
`user-data` script. nuageinit, FreeBSD's cloud-init, runs that script on the
first boot; it runs the tests and powers the machine off, and the check passes
if the serial console says they passed. It needs no network and nothing logs
in. The CI runs it on every push.

macOS and Windows are tested on GitHub, whose runners are native machines of
both: every push to the GitHub mirror runs `zig build test` on arm64 and Intel
macOS and on Windows, from `.github/workflows/test.yaml`.

`zig build test-exe -Dtarget=...` installs the test binary for any target as
`zig-out/bin/serial-test`, to be carried to a machine that can run it — a Mac,
say.

The tests use pseudo-terminals in place of a cable, on Linux and on macOS and
the BSDs alike. A pty cannot test everything, because it always reports eight
data bits and no parity whatever it is told. So the conversion between
`Settings` and each platform's `termios` is tested on its own, in memory, and
the pty tests cover what a pty does keep: the rate, the stop bits, flow
control, raw data in both directions, exclusivity, and the restoring of the
original settings on close.

## Where this came from

[zettacom](https://git.jcollie.dev/jeff/zettacom) has a serial layer of its
own, but most of it is ported from picocom and is GPL. zig-serial is a fresh
MIT implementation, written from the interfaces in the references below, so
that MIT programs — the [harrier](https://git.jcollie.dev/jeff/harrier)
terminal among them — can use it.

## Repository

The canonical repository is on my Forgejo instance, and Tangled and GitHub
carry mirrors of it:

```console
git clone https://git.jcollie.dev/jeff/zig-serial.git
```

- Forgejo: <https://git.jcollie.dev/jeff/zig-serial>
- Tangled: <https://tangled.org/jcollie.dev/zig-serial>
- GitHub: <https://github.com/jcollie/zig-serial>

CI for Linux and FreeBSD, and the published documentation, come from the
Forgejo repository; the GitHub mirror is there for its macOS and Windows
runners.

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
- Apple Inc. *ioss.h — IOKit serial ioctls* (IOSerialFamily). Apple Open
  Source. <https://github.com/apple-oss-distributions/IOSerialFamily/blob/main/IOSerialFamily.kmodproj/ioss.h>
- FreeBSD Project. *basic-ci.conf — the BASIC-CI virtual machine image
  configuration*. FreeBSD source tree, releng/15.1.
  <https://github.com/freebsd/freebsd-src/blob/releng/15.1/release/tools/basic-ci.conf>
- FreeBSD Project. *nuageinit(7) — limited cloud-init configuration*.
  FreeBSD manual pages. <https://man.freebsd.org/cgi/man.cgi?query=nuageinit&sektion=7>
- FreeBSD Project. *termios(4) — general terminal line discipline*. FreeBSD
  manual pages. <https://man.freebsd.org/cgi/man.cgi?query=termios&sektion=4>
- FreeBSD Project. *tty(4) — general terminal interface*. FreeBSD manual
  pages. <https://man.freebsd.org/cgi/man.cgi?query=tty&sektion=4>
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
