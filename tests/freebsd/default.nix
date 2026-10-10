# SPDX-FileCopyrightText: © 2026 Jeffrey C. Ollie <jeff@ocjtech.us>
# SPDX-License-Identifier: MIT

# The tests, cross-compiled for x86_64-freebsd and run in a FreeBSD virtual
# machine, so that the BSD backend is run somewhere rather than only compiled.
#
# The image is FreeBSD's own BASIC-CI build, which enables nuageinit, its
# cloud-init. Given a NoCloud drive labelled `cidata` whose `user-data` begins
# with `#!`, nuageinit runs that script once, on the first boot. The drive
# carries the test binary too, the script runs it and powers the machine off,
# and the verdict is read from the serial console. No network, no ssh, and
# nothing to log in to.
{
  lib,
  fetchurl,
  runCommand,
  stdenvNoCC,
  qemu_kvm,
  xorriso,
  xz,
  zig_0_17,
  src,
}:
let
  version = "15.1";

  # The published image is a 5 GiB raw disk; as a qcow2 it is the size of
  # what is actually on it, and it is this that the cache holds and every run
  # puts a throwaway overlay on top of.
  image =
    runCommand "freebsd-${version}-amd64-basic-ci.qcow2"
      {
        nativeBuildInputs = [
          qemu_kvm
          xz
        ];
        compressed = fetchurl {
          url = "https://download.freebsd.org/releases/CI-IMAGES/${version}-RELEASE/amd64/Latest/FreeBSD-${version}-RELEASE-amd64-BASIC-CI-ufs.raw.xz";
          hash = "sha256-kI5zXxi6GS6vSMJwO1SSJcm5bnTjeEvZJ4xxILQTmWI=";
        };
      }
      ''
        xz -dc $compressed > disk.raw
        qemu-img convert -f raw -O qcow2 disk.raw $out
      '';

  tests = stdenvNoCC.mkDerivation {
    name = "zig-serial-tests-x86_64-freebsd";
    inherit src;
    # For its setup hook, which gives Zig a writable cache directory.
    nativeBuildInputs = [ zig_0_17 ];
    buildPhase = ''
      runHook preBuild
      zig build test-exe -Dtarget=x86_64-freebsd --prefix $out
      runHook postBuild
    '';
    dontInstall = true;
  };
in
runCommand "zig-serial-freebsd-${version}"
  {
    nativeBuildInputs = [
      qemu_kvm
      xorriso
    ];
    requiredSystemFeatures = [ "kvm" ];
    passthru = { inherit image tests; };
  }
  ''
    mkdir cidata
    cp ${tests}/bin/serial-test cidata/serial-test
    cp ${./user-data} cidata/user-data
    chmod 0755 cidata/serial-test cidata/user-data
    printf 'instance-id: zig-serial\nlocal-hostname: zig-serial\n' > cidata/meta-data
    xorriso -as mkisofs -quiet -V cidata -J -r -o cidata.iso cidata

    # A fresh overlay every run, which is also what makes this the image's
    # first boot, the only one on which nuageinit acts.
    qemu-img create -q -f qcow2 -F qcow2 -b ${image} disk.qcow2

    # A machine that never powers off -- a panic, a hung test -- is stopped
    # here, and then fails for want of the line below.
    timeout 15m qemu-system-x86_64 \
      -machine q35,accel=kvm -cpu host -smp 2 -m 1024 \
      -nographic -nic none -no-reboot \
      -drive file=disk.qcow2,if=virtio \
      -drive file=cidata.iso,media=cdrom,readonly=on \
      < /dev/null | tee serial.log || true

    grep -q '^zig-serial-freebsd: exit 0' <(tr -d '\r' < serial.log)
    cp serial.log $out
  ''
