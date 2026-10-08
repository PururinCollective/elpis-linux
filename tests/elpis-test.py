#!/usr/bin/env python3
"""
Boot the Elpis ISO in QEMU and check what it does.

    tests/elpis-test.py [--iso PATH] [--update-iso PATH] [--key PATH] [SCENARIO...]

Scenarios (all by default, in this order):

    cd           ISO as a CD, no disk: RAM only, answers with DNSSEC (AD flag)
    disk         ISO written to a 2 GiB disk (BIOS): ELPIS-DATA made at first
                 start, a saved setting survives a reboot, safe mode skips it,
                 factory reset erases it
    uefi         the same disk started by UEFI firmware (OVMF)
    cd-data      ISO as a CD plus a blank disk: format-blank, save, restore
    foreign      a disk with partitions Elpis did not make is left alone
    copy         elpis-copy-to-disk from a CD start, then start from the copy
    update       signed update from a newer ISO, then a broken one that GRUB
                 falls back from (needs --update-iso and --key)

Needs qemu-system-x86_64, KVM, OVMF for "uefi", dig, and sfdisk.  Work files go
to tests/work/.  Every serial console is logged there as <scenario>-*.log.
"""

import argparse
import http.server
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
TOP = os.path.dirname(HERE)
WORK = os.path.join(HERE, "work")
OVMF_CODE = "/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS = "/usr/share/OVMF/OVMF_VARS_4M.fd"
HOST_TOOLS = os.path.join(TOP, "output", "host", "bin")

PROMPT = "__ELPIS_PROMPT__# "
RESULTS = []


class Failure(Exception):
    pass


def check(cond, what):
    RESULTS.append(("PASS" if cond else "FAIL", CURRENT, what))
    print(("  ok   " if cond else "  FAIL ") + what, flush=True)
    if not cond:
        raise Failure(what)


def note(what):
    print("  ..   " + what, flush=True)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class VM:
    def __init__(self, name, cdrom=None, disks=(), uefi=False, boot="c", mem=1024):
        self.name = name
        self.dns_port = free_port()
        self.sock = os.path.join(tempfile.mkdtemp(prefix="elpis-"), "serial")
        self.log = open(os.path.join(WORK, f"{CURRENT}-{name}.log"), "wb")
        self.buf = b""
        self.pos = 0
        self.lock = threading.Lock()
        cmd = ["qemu-system-x86_64", "-machine", "q35", "-enable-kvm", "-cpu", "host",
               "-m", str(mem), "-smp", "2", "-display", "none",
               "-chardev", f"socket,id=s0,path={self.sock},server=on,wait=on",
               "-serial", "chardev:s0", "-monitor", "none",
               "-netdev", "user,id=n0,"
               f"hostfwd=udp:127.0.0.1:{self.dns_port}-:53,"
               f"hostfwd=tcp:127.0.0.1:{self.dns_port}-:53",
               "-device", "virtio-net-pci,netdev=n0",
               "-object", "rng-random,filename=/dev/urandom,id=rng0",
               "-device", "virtio-rng-pci,rng=rng0"]
        if uefi:
            vars_copy = os.path.join(WORK, f"{CURRENT}-{name}-vars.fd")
            shutil.copy(OVMF_VARS, vars_copy)
            cmd += ["-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE}",
                    "-drive", f"if=pflash,format=raw,file={vars_copy}"]
        idx = 1
        if cdrom:
            cmd += ["-drive", f"file={cdrom},media=cdrom,readonly=on,if=none,id=cd0",
                    "-device", f"ide-cd,drive=cd0,bootindex={0 if boot == 'd' else 9}"]
        for i, d in enumerate(disks):
            cmd += ["-drive", f"file={d},format=raw,if=none,id=hd{i}",
                    "-device", f"virtio-blk-pci,drive=hd{i},bootindex={idx if boot == 'd' else i}"]
            idx += 1
        self.proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL,
                                     stdout=self.log, stderr=subprocess.STDOUT)
        for _ in range(100):
            try:
                self.conn = socket.socket(socket.AF_UNIX)
                self.conn.connect(self.sock)
                break
            except OSError:
                time.sleep(0.1)
        else:
            raise Failure("could not connect to the VM's serial port")
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        while True:
            try:
                data = self.conn.recv(4096)
            except OSError:
                return
            if not data:
                return
            self.log.write(data)
            self.log.flush()
            with self.lock:
                self.buf += data

    def expect(self, pattern, timeout=120):
        """Wait for PATTERN after what has been consumed so far; consume up to it."""
        rx = re.compile(pattern.encode() if isinstance(pattern, str) else pattern)
        end = time.time() + timeout
        while time.time() < end:
            with self.lock:
                m = rx.search(self.buf, self.pos)
                if m:
                    self.pos = m.end()
                    return m
            if self.proc.poll() is not None:
                raise Failure(f"VM exited while waiting for {pattern!r}")
            time.sleep(0.1)
        raise Failure(f"timed out waiting for {pattern!r}")

    def send(self, text):
        self.conn.sendall(text.encode() if isinstance(text, str) else text)

    def grub(self, entry=0, submenu_entry=None, timeout=120):
        """Choose a menu entry (0-based) in GRUB, over the serial console."""
        self.expect(r"GNU GRUB", timeout)
        self.expect(r"Elpis \S+", 30)
        time.sleep(0.5)
        self.send("\x1b[B" * entry if entry else "")
        time.sleep(0.3)
        self.send("\r")
        if submenu_entry is not None:
            self.expect(r"Erase all settings", 30)
            time.sleep(0.5)
            self.send("\x1b[B" * submenu_entry + "\r")

    def login(self, timeout=180):
        self.expect(r"login: ", timeout)
        self.send("root\n")
        time.sleep(1)
        # Split so the echoed command itself does not look like the prompt.
        self.send("export PS1='__ELPIS_''PROMPT__# '; stty -echo cols 250\n")
        self.expect(re.escape(PROMPT), 30)

    def run(self, command, timeout=120):
        """Run COMMAND in the logged-in shell; return (status, output)."""
        marker = f"__RC{int(time.time() * 1000) % 100000000}__"
        self.send(f"{command}; echo {marker}$?{marker}\n")
        m = self.expect(re.escape(marker) + rb"(\d+)" + re.escape(marker), timeout)
        with self.lock:
            text = self.buf[:m.start()]
        out = text[text.rfind(PROMPT.encode()) + len(PROMPT):].decode(errors="replace") \
            if PROMPT.encode() in text else text.decode(errors="replace")
        self.expect(re.escape(PROMPT), 30)
        return int(m.group(1)), out.strip()

    def out(self, command, timeout=120):
        return self.run(command, timeout)[1]

    def reboot(self):
        self.send("reboot\n")

    def stop(self):
        try:
            self.send("poweroff\n")
            self.proc.wait(30)
        except Exception:
            self.proc.kill()
            self.proc.wait()
        self.conn.close()
        self.log.close()


def dig(vm, name, rtype="A", extra=("+dnssec",), timeout=60):
    """Ask the VM's resolver from the host; returns dig's output."""
    end = time.time() + timeout
    out = ""
    while time.time() < end:
        r = subprocess.run(["dig", "@127.0.0.1", "-p", str(vm.dns_port), name, rtype,
                            "+time=5", "+tries=1", *extra],
                           capture_output=True, text=True)
        out = r.stdout
        if "status: NOERROR" in out or "status: NXDOMAIN" in out:
            return out
        time.sleep(3)
    return out


def state(vm):
    s = {}
    for line in vm.out("cat /run/elpis/state").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            s[k.strip()] = v.strip().strip("'")
    return s


def fresh_disk(path, iso=None, size="2G"):
    if os.path.exists(path):
        os.remove(path)
    if iso:
        shutil.copy(iso, path)
    subprocess.run(["truncate", "-s", size, path], check=True)
    return path


def sfdisk_dump(path):
    return subprocess.run(["sfdisk", "-d", path], capture_output=True, text=True).stdout


# ---- scenarios -------------------------------------------------------------

def t_cd(a):
    vm = VM("bios", cdrom=a.iso, boot="d")
    try:
        vm.grub(0)
        vm.login()
        s = state(vm)
        check(s.get("MODE") == "ram", "CD only: settings are in RAM")
        check("CD" in s.get("REASON", ""), f"the reason says so: {s.get('REASON')!r}")
        check(vm.run("pidof elpis")[0] == 0, "the resolver is running")
        out = dig(vm, "example.com")
        check(re.search(r"flags:[^;]* ad[ ;]", out) is not None, "example.com answers with the AD flag (DNSSEC)")
        out = dig(vm, "elpis.sakurako.oomuro", "TXT", extra=())
        build = re.search(r'"build=([^"]*)"', out)
        txt = " ".join(re.findall(r'"[^"]*"', out))
        note(f"identity probe: {txt}")
        check(build is not None and build.group(1) != "", f"the identity probe reports the build: {build.group(1) if build else None}")
        st, _ = vm.run("elpis-save")
        check(st == 3, "elpis-save refuses, with status 3, when RAM only")
    finally:
        vm.stop()


def t_disk(a):
    disk = fresh_disk(os.path.join(WORK, "disk.raw"), a.iso)
    before = sfdisk_dump(disk)
    vm = VM("first", disks=[disk])
    try:
        vm.grub(0)
        vm.login()
        s = state(vm)
        check(s.get("MODE") == "persistent" and s.get("CREATED") == "1",
              f"first start from a disk: ELPIS-DATA made ({s.get('DATA_DEV')})")
        check(s.get("DATA_DEV") == "/dev/vda3", "it is partition 3 of the boot disk")
        dump = vm.out("sfdisk -d /dev/vda")
        check(re.search(r"vda3 : start= *2097152,", dump) is not None, "it starts at 1 GiB")
        check(vm.run("pidof elpis")[0] == 0, "the resolver is running")
        vm.run("sed -i 's/^log-level: info/log-level: debug/' /etc/elpis/elpis.conf")
        vm.run("echo elpis-test > /etc/hostname")
        st, out = vm.run("elpis-save")
        check(st == 0, "elpis-save saves")
        vm.reboot()
        vm.grub(0)
        vm.login()
        s = state(vm)
        check(s.get("MODE") == "persistent" and s.get("CREATED") == "0", "second start: ELPIS-DATA found again")
        check(vm.out("grep '^log-level:' /etc/elpis/elpis.conf").startswith("log-level: debug"),
              "the saved elpis.conf change survived the reboot")
        check(vm.out("hostname") == "elpis-test", "so did the hostname")
        check(vm.out("cat /run/elpis/config-in-use") == "/etc/elpis/elpis.conf", "the resolver runs with the saved config")
        vm.reboot()
        vm.grub(2)        # safe mode
        vm.login()
        s = state(vm)
        check(s.get("SAFE") == "1", "safe mode starts")
        check(vm.out("grep '^log-level:' /etc/elpis/elpis.conf").startswith("log-level: info"),
              "safe mode does not restore saved settings")
        check(vm.run("test -f /data/config/etc/elpis/elpis.conf")[0] == 0, "but leaves them on ELPIS-DATA")
        vm.reboot()
        vm.grub(3, submenu_entry=0)   # factory reset
        vm.login()
        s = state(vm)
        check(s.get("RESET") == "1", "factory reset ran")
        check(vm.out("grep '^log-level:' /etc/elpis/elpis.conf").startswith("log-level: info"),
              "after the reset the settings are the defaults")
        check(vm.run("test -e /data/config/etc/elpis/elpis.conf")[0] != 0, "ELPIS-DATA was erased")
        vm.run("echo kept-for-uefi > /etc/hostname; elpis-save")
    finally:
        vm.stop()
    after = sfdisk_dump(disk)
    p1_before = [l for l in before.splitlines() if l.startswith(disk + "1") or l.startswith(disk + "2")]
    p1_after = [l for l in after.splitlines() if l.startswith(disk + "1") or l.startswith(disk + "2")]
    check(p1_before == p1_after, "p1 and p2 (the ISO) are unchanged on the host's view of the disk")


def t_uefi(a):
    disk = os.path.join(WORK, "disk.raw")
    if not os.path.exists(disk):
        raise Failure("run the disk scenario first")
    if not os.path.exists(OVMF_CODE):
        note("OVMF not installed: skipped")
        return
    vm = VM("ovmf", disks=[disk], uefi=True)
    try:
        vm.grub(0, timeout=180)
        vm.login()
        check(vm.run("test -d /sys/firmware/efi")[0] == 0, "started by UEFI firmware")
        s = state(vm)
        check(s.get("MODE") == "persistent", "ELPIS-DATA is used under UEFI too")
        check(vm.out("hostname") == "kept-for-uefi", "the setting saved under BIOS is restored")
    finally:
        vm.stop()
    vm = VM("ovmf-cd", cdrom=a.iso, uefi=True, boot="d")
    try:
        vm.grub(0, timeout=180)
        vm.login()
        check(vm.run("test -d /sys/firmware/efi")[0] == 0, "the ISO as a CD starts under UEFI")
    finally:
        vm.stop()


def t_cd_data(a):
    blank = fresh_disk(os.path.join(WORK, "blank.raw"), size="1G")
    vm = VM("first", cdrom=a.iso, disks=[blank], boot="d")
    try:
        vm.grub(0)
        vm.login()
        check(state(vm).get("MODE") == "ram", "CD plus a blank disk: RAM only until asked")
        st, out = vm.run("elpis-storage format-blank vda --yes")
        check(st == 0, "format-blank makes the blank disk ELPIS-DATA")
        check(state(vm).get("MODE") == "persistent", "and settings are kept there from then on")
        vm.run("echo from-cd > /etc/hostname; elpis-save")
        vm.reboot()
        vm.grub(0)
        vm.login()
        s = state(vm)
        check(s.get("MODE") == "persistent" and s.get("DATA_DEV") == "/dev/vda1", "next start from the CD finds it")
        check(vm.out("hostname") == "from-cd", "and restores the saved setting")
    finally:
        vm.stop()


def t_foreign(a):
    disk = fresh_disk(os.path.join(WORK, "foreign.raw"), a.iso)
    subprocess.run(["sfdisk", "--append", "--no-reread", "-q", "--wipe", "never", disk],
                   input="start=2097152, size=204800, type=7\n", text=True, check=True)
    before = sfdisk_dump(disk)
    other = fresh_disk(os.path.join(WORK, "other.raw"), size="512M")
    subprocess.run(["sfdisk", "-q", other], input="start=2048, type=83\n", text=True, check=True)
    other_before = sfdisk_dump(other)
    vm = VM("bios", disks=[disk, other])
    try:
        vm.grub(0)
        vm.login()
        s = state(vm)
        check(s.get("MODE") == "ram", "an ISO disk with a partition Elpis did not make: RAM only")
        check("did not make" in s.get("REASON", ""), f"the reason says so: {s.get('REASON')!r}")
        check(vm.run("pidof elpis")[0] == 0, "the resolver still runs")
    finally:
        vm.stop()
    check(sfdisk_dump(disk) == before, "the boot disk's partition table is unchanged")
    check(sfdisk_dump(other) == other_before, "the other disk is unchanged")


def t_copy(a):
    target = fresh_disk(os.path.join(WORK, "copy.raw"), size="2G")
    vm = VM("from-cd", cdrom=a.iso, disks=[target], boot="d")
    try:
        vm.grub(0)
        vm.login()
        vm.run("echo copied-host > /etc/hostname")
        st, out = vm.run("elpis-copy-to-disk --disk vda --keep-config --yes", timeout=300)
        note(out.splitlines()[-1] if out else "")
        check(st == 0, "elpis-copy-to-disk writes the ISO and ELPIS-DATA to vda")
    finally:
        vm.stop()
    vm = VM("from-copy", disks=[target])
    try:
        vm.grub(0)
        vm.login()
        s = state(vm)
        check(s.get("MODE") == "persistent" and s.get("DATA_DEV") == "/dev/vda3", "the copy starts on its own, with ELPIS-DATA")
        check(vm.out("hostname") == "copied-host", "and the settings were carried over")
    finally:
        vm.stop()


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def make_broken_iso(good_iso, key, out_iso):
    """The update ISO with a root filesystem that cannot start, re-signed."""
    xorriso = os.path.join(HOST_TOOLS, "xorriso")
    minisign = os.path.join(HOST_TOOLS, "minisign")
    tree = os.path.join(WORK, "broken-tree")
    shutil.rmtree(tree, ignore_errors=True)
    os.makedirs(tree)
    subprocess.run([xorriso, "-osirrox", "on", "-indev", good_iso, "-extract", "/", tree],
                   check=True, capture_output=True)
    subprocess.run(["chmod", "-R", "u+w", tree], check=True)
    with open(os.path.join(tree, "boot", "rootfs.cpio.xz"), "wb") as f:
        f.write(os.urandom(4096))
    rel = os.path.join(tree, "boot", "elpis-release")
    text = open(rel).read()
    text = re.sub(r"BUILD_ID=\d+", "BUILD_ID=2099010100000000", text)
    open(rel, "w").write(text)
    if os.path.exists(out_iso):
        os.remove(out_iso)
    subprocess.run([xorriso, "-as", "mkisofs", "-quiet", "-iso-level", "3", "-rational-rock",
                    "-volid", "ELPIS", "-o", out_iso, tree], check=True)
    for f in (out_iso + ".minisig",):
        if os.path.exists(f):
            os.remove(f)
    subprocess.run([minisign, "-S", "-s", key, "-m", out_iso], check=True,
                   stdin=subprocess.DEVNULL, capture_output=True)


def t_update(a):
    if not (a.update_iso and a.key):
        note("needs --update-iso and --key: skipped")
        return
    serve = os.path.join(WORK, "http")
    shutil.rmtree(serve, ignore_errors=True)
    os.makedirs(serve)
    for f in (a.update_iso, a.update_iso + ".minisig"):
        shutil.copy(f, serve)
    upd = os.path.basename(a.update_iso)
    shutil.copy(a.update_iso, os.path.join(serve, "tampered.iso"))
    shutil.copy(a.update_iso + ".minisig", os.path.join(serve, "tampered.iso.minisig"))
    with open(os.path.join(serve, "tampered.iso"), "ab") as f:
        f.write(b"x")
    make_broken_iso(a.update_iso, a.key, os.path.join(serve, "broken.iso"))

    port = free_port()
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port),
                                            lambda *x, **k: Quiet(*x, directory=serve, **k))
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    url = f"http://10.0.2.2:{port}"

    disk = fresh_disk(os.path.join(WORK, "update.raw"), a.iso)
    vm = VM("bios", disks=[disk])
    try:
        vm.grub(0)
        vm.login()
        base_ver = vm.out(". /etc/elpis-release; echo $VERSION-$BUILD_ID")
        st, out = vm.run(f"elpis-update --from-iso {url}/tampered.iso")
        check(st != 0 and "signature" in out, "a tampered update is refused")
        st, out = vm.run(f"elpis-update --from-iso {url}/{upd}", timeout=300)
        check(st == 0, "the signed update installs")
        slot = vm.out("sed -n 's/^next=//p' /data/grubenv")
        note(f"next = {slot}")
        vm.reboot()
        vm.grub(0)
        vm.login()
        now = vm.out(". /etc/elpis-release; echo $VERSION-$BUILD_ID")
        check(now == slot, f"the update starts: {now}")
        ok = False
        for _ in range(40):
            if vm.out("sed -n 's/^good=//p' /data/grubenv") == slot:
                ok = True
                break
            time.sleep(3)
        check(ok, "once it answers, it is marked good")
        check(vm.out("sed -n 's/^next=//p' /data/grubenv") == "", "and is no longer on trial")
        vm.reboot()
        vm.grub(0)
        vm.login()
        check(vm.out(". /etc/elpis-release; echo $VERSION-$BUILD_ID") == slot, "it keeps starting by default")

        st, out = vm.run(f"elpis-update --from-iso {url}/broken.iso", timeout=300)
        check(st == 0, "a broken (but signed) update installs")
        broken = vm.out("sed -n 's/^next=//p' /data/grubenv")
        vm.reboot()
        for n in (1, 2, 3):
            vm.grub(0)
            vm.expect(r"Kernel panic|end Kernel panic", 120)
            note(f"start {n} of the broken update panics; panic=10 restarts it")
        vm.grub(0)
        vm.login()
        now = vm.out(". /etc/elpis-release; echo $VERSION-$BUILD_ID")
        check(now == slot, f"after three failed starts GRUB is back on the good update: {now}")
        ok = False
        for _ in range(40):
            if vm.out("sed -n 's/^next=//p' /data/grubenv") == "":
                ok = True
                break
            time.sleep(3)
        check(ok, "and the broken update is no longer on trial")
        check(vm.run(f"test -e /data/system/{broken}/FAILED")[0] == 0, "it is marked as failed")
        st, _ = vm.run("elpis-update --revert")
        vm.reboot()
        vm.grub(0)
        vm.login()
        check(vm.out(". /etc/elpis-release; echo $VERSION-$BUILD_ID") == base_ver,
              "--revert goes back to the version on the medium")
    finally:
        vm.stop()
        httpd.shutdown()


SCENARIOS = {
    "cd": t_cd, "disk": t_disk, "uefi": t_uefi, "cd-data": t_cd_data,
    "foreign": t_foreign, "copy": t_copy, "update": t_update,
}
CURRENT = "setup"


def main():
    global CURRENT
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--iso")
    p.add_argument("--update-iso")
    p.add_argument("--key", help="minisign secret key that signed --update-iso")
    p.add_argument("scenario", nargs="*")
    a = p.parse_args()
    os.makedirs(WORK, exist_ok=True)
    if not a.iso:
        import glob
        isos = sorted(glob.glob(os.path.join(TOP, "output", "images", "elpis-*.iso")), key=os.path.getmtime)
        if not isos:
            sys.exit("no ISO: build one, or give --iso")
        a.iso = isos[-1]
    a.iso = os.path.abspath(a.iso)
    print(f"ISO: {a.iso}")
    for name in a.scenario or list(SCENARIOS):
        CURRENT = name
        print(f"== {name}", flush=True)
        try:
            SCENARIOS[name](a)
        except Failure as e:
            if not RESULTS or RESULTS[-1][0] == "PASS":
                RESULTS.append(("FAIL", name, str(e)))
                print(f"  FAIL {e}", flush=True)
    failed = [r for r in RESULTS if r[0] == "FAIL"]
    print(f"\n{len(RESULTS) - len(failed)} passed, {len(failed)} failed")
    for r in failed:
        print(f"  FAIL [{r[1]}] {r[2]}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
