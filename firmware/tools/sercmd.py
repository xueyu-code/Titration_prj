"""Serial console of the titrator: send debug shell lines, print the log.

usage: sercmd.py [--port P] [--reset] [--gap S] [--tail S] [line ...]

Opening the port does not reset the board; --reset does and waits for the
boot. Each line is sent with CR, --gap seconds apart (default 1), and the
output is printed (seconds since start) until --tail seconds after the last
one (default 1.5). Without lines it only listens: `--tail 600` follows the log.

Needs pyserial: run it with the ESP-IDF Python (`python` after export.sh).
Also a module, see Console; tools/smoke.py uses it.
"""
import argparse
import glob
import re
import time

import serial

BAUD = 115200
BOOTED = r"main_task: Returned from app_main"


def default_port():
    """The DevKitC's USB-UART bridge (CH343), else /dev/ttyACM0."""
    ports = sorted(glob.glob("/dev/serial/by-id/usb-1a86_*"))
    return ports[0] if ports else "/dev/ttyACM0"


class Console:
    """Line-based access to the console UART. Every line read is kept in
    `lines` (without the line end), so callers can search what came."""

    def __init__(self, port=None, echo=True):
        self.serial = serial.Serial()
        self.serial.port, self.serial.baudrate, self.serial.timeout = port or default_port(), BAUD, 0.05
        # open() asserts DTR and RTS together, which the auto-reset circuit
        # ignores. Release RTS (EN) first: DTR low with RTS still high would
        # pull EN low and reset the board.
        self.serial.open()
        self.serial.rts = False
        self.serial.dtr = False
        self.echo = echo
        self.lines = []
        self._t0 = time.time()
        self._buf = b""

    def pump(self, secs):
        """Reads for secs seconds."""
        end = time.time() + secs
        while time.time() < end:
            self._read()

    def _read(self):
        self._buf += self.serial.read(4096)
        while b"\n" in self._buf:
            raw, self._buf = self._buf.split(b"\n", 1)
            line = raw.decode(errors="replace").rstrip()
            self.lines.append(line)
            if self.echo:
                print(f"{time.time() - self._t0:7.2f} {line}", flush=True)

    def find(self, pattern, since=0):
        """Index of the first line from since on that matches, or None."""
        rx = re.compile(pattern)
        for i in range(since, len(self.lines)):
            if rx.search(self.lines[i]):
                return i
        return None

    def wait(self, pattern, since=0, timeout=2.0):
        """Reads until a line from since on matches: its index, or None."""
        end = time.time() + timeout
        while True:
            i = self.find(pattern, since)
            if i is not None or time.time() >= end:
                return i
            self._read()

    def reset(self, timeout=5.0):
        """Resets the board through RTS (EN); True once it has booted."""
        since = len(self.lines)
        self.serial.rts = True
        time.sleep(0.1)
        self.serial.rts = False
        return self.wait(BOOTED, since, timeout) is not None

    def send(self, line):
        """Sends one line; returns the index its output starts at."""
        since = len(self.lines)
        self.serial.write(line.encode() + b"\r")
        return since

    def cmd(self, line, until=None, timeout=2.0):
        """Sends line and returns the lines after its echo: up to the first
        one matching until (None if it does not come within timeout), or what
        came within 0.3 s when until is None."""
        since = self.send(line)
        echo = self.wait("^" + re.escape(("> " + line).rstrip()) + "$", since, timeout)
        if echo is None:
            return None
        if until is None:
            self.pump(0.3)
            return self.lines[echo + 1:]
        end = self.wait(until, echo + 1, timeout)
        return None if end is None else self.lines[echo + 1:end + 1]


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("lines", nargs="*")
    ap.add_argument("--port")
    ap.add_argument("--reset", action="store_true")
    ap.add_argument("--gap", type=float, default=1.0)
    ap.add_argument("--tail", type=float, default=1.5)
    args = ap.parse_args()

    con = Console(args.port)
    if args.reset:
        con.reset()
    for line in args.lines:
        con.send(line)
        con.pump(args.gap)
    con.pump(args.tail)


if __name__ == "__main__":
    main()
