"""Hardware smoke test through the debug shell (DESIGN.md section 19).

usage: smoke.py [--port P] [--ble] [-v]

Resets the board and checks what must hold whatever the bench wiring:
boot, protocol commands and their errors, a move and a jog + stop on both
channels (the position follows the pulse count), titrate (error sensor
without a pH input, else a titration that ends), the stack and heap
reserve, and no error or panic anywhere in the log. --ble also connects from
the PC over BlueZ (tools/btcmd.py with the system python3). -v prints the
serial log as it comes.

Flash first (idf.py -p PORT flash), run with the ESP-IDF Python. Exit
status 0 when every check passes.
"""
import argparse
import os
import re
import subprocess
import sys

from sercmd import Console

MOVE_STEPS = 121        # MOVE_STEPS in core/config.h
STACK_MIN = 512         # B left on our tasks' stacks
HEAP_MIN = 64 * 1024    # B of internal heap left at its lowest
OUR_TASKS = ("ctl", "sensor", "shell", "nimble_host")

failed = []


def check(ok, what):
    print(("PASS  " if ok else "FAIL  ") + what, flush=True)
    if not ok:
        failed.append(what)


def evt(body):
    """An event line (needs `log evt debug`) whose JSON starts with body."""
    return r'evt: \{"evt":' + body


def move(ch, d, kind="move"):
    return f'{{"cmd":"{kind}","ch":{ch},"dir":"{d}"}}'


class Bench:
    def __init__(self, con):
        self.con = con

    def axes(self, ch):
        out = self.con.cmd("axes", until=r"^ch2:")
        m = out and re.search(rf"^ch{ch}: limit (\d), homed (\d), pos (-?\d+), (\w+), pulses (\d+)$",
                              "\n".join(out), re.M)
        if not m:
            raise SystemExit("no answer to `axes`: is the debug shell built in?")
        return {"limit": m[1] == "1", "homed": m[2] == "1", "pos": int(m[3]), "status": m[4],
                "pulses": int(m[5])}

    def channel(self, ch):
        con = self.con
        a = self.axes(ch)
        if a["limit"]:
            # Switch input open (bare board: floating high): "out" is refused
            # and homes the axis, so "in" can be tested.
            r = con.cmd(move(ch, "out"), until=evt(rf'"error","code":"limit","ch":{ch}'))
            check(r is not None and self.axes(ch)["homed"], f"ch{ch}: out refused at the switch, now homed")
            d = "in"
        else:
            if not a["homed"]:
                r = con.cmd(move(ch, "in"), until=evt(rf'"error","code":"unhomed","ch":{ch}'))
                check(r is not None, f"ch{ch}: in refused while unhomed")
            d = "out"

        def expected(before, pulses):
            # One direction only, so no backlash; "out" stops counting at 0.
            return before + pulses if d == "in" else max(0, before - pulses)

        before = self.axes(ch)["pos"]
        r = con.cmd(move(ch, d), until=evt(r'"state","s":"idle"'), timeout=3)
        a = self.axes(ch)
        check(r is not None and a["status"] == "done" and a["pulses"] == MOVE_STEPS
              and a["pos"] == expected(before, MOVE_STEPS),
              f"ch{ch}: move {d}: {a['pulses']} pulses, pos {before} -> {a['pos']}")

        before = a["pos"]
        con.cmd(move(ch, d, "jog"), until=evt(r'"state","s":"moving"'))
        con.pump(0.4)
        running = self.axes(ch)["status"] == "running"
        r = con.cmd('{"cmd":"stop"}', until=evt(r'"state","s":"idle"'))
        a = self.axes(ch)
        check(running and r is not None and a["status"] == "halted" and a["pulses"] > 0
              and a["pos"] == expected(before, a["pulses"]),
              f"ch{ch}: jog {d} then stop: {a['pulses']} pulses, pos {before} -> {a['pos']}")

    def titrate(self):
        con = self.con
        since = con.send('{"cmd":"titrate","target":7}')
        i = con.wait(evt(r'("error","code":"sensor"|"state","s":"titrating")'), since)
        if i is None:
            check(False, "titrate: no answer")
        elif "sensor" in con.lines[i]:
            check(con.find(r"device: sensor fault") is not None, "titrate refused: sensor fault (no pH input)")
        else:
            con.pump(3)
            con.send('{"cmd":"stop"}')
            # It may also have ended by itself (an error, then idle).
            check(con.wait(evt(r'"state","s":"idle"'), i) is not None, "titrate: titrating, then idle")

    def resources(self):
        out = self.con.cmd("tasks", until=r"^internal heap")
        if out is None:
            check(False, "tasks: no answer")
            return
        free = {m[1]: int(m[2]) for m in (re.match(r"^(\S+)\s+\w\s+\d+\s+(\d+)$", ln) for ln in out) if m}
        ours = {t: free.get(t) for t in OUR_TASKS}
        check(all(v is not None and v >= STACK_MIN for v in ours.values()),
              "stack free: " + ", ".join(f"{t} {v}" for t, v in ours.items()) + f" B (>= {STACK_MIN})")
        heap_min = int(re.search(r"min (\d+) B", out[-1])[1])
        check(heap_min >= HEAP_MIN, f"internal heap min {heap_min} B (>= {HEAP_MIN})")

    def ble(self):
        con = self.con
        tool = os.path.join(os.path.dirname(os.path.abspath(__file__)), "btcmd.py")
        since = len(con.lines)
        try:
            out = subprocess.run(["/usr/bin/python3", tool, '{"cmd":"sync"}'], capture_output=True,
                                 text=True, timeout=40).stdout
        except subprocess.TimeoutExpired:
            out = ""
        con.wait(r"device: disconnected", since, timeout=5)
        got = out.count('<- {"evt":"state"') >= 2 and out.count('<- {"evt":"cal"') >= 2
        ph = re.search(r"ph events: (\d+)", out)
        check(got and con.find(r"ble: notifications on", since) is not None,
              f"BLE: subscribe and sync answered with state + cal, {ph[1] if ph else 0} ph events")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--port")
    ap.add_argument("--ble", action="store_true")
    ap.add_argument("-v", action="store_true", dest="verbose")
    args = ap.parse_args()

    con = Console(args.port, echo=args.verbose)
    bench = Bench(con)

    check(con.reset(), "boots")
    check(con.find(r"titrator firmware \S+, protocol v4") is not None, "version line, protocol v4")
    check(con.find(r"ble: advertising as Titrator-") is not None, "advertising")
    check(con.find(r"Found core dump") is None,
          "no core dump in flash (else: idf.py coredump-info, then erase it)")
    con.pump(3)  # past the first sensor fault decision (2-2.5 s)

    con.cmd("log evt debug")
    r = con.cmd('{"cmd":"sync"}', until=evt(r'"cal"'))
    check(r is not None and any('"state","s":"idle"' in ln for ln in r), "sync: state idle, cal")
    check(con.cmd('{"cmd":', until=evt(r'"error","code":"bad_cmd"')) is not None, "bad JSON: bad_cmd")
    check(con.cmd('{"cmd":"stop"}'.ljust(101), until=evt(r'"error","code":"bad_cmd","msg":"too long"'))
          is not None, "101 B: bad_cmd too long")
    check(con.cmd('{"cmd":"stop"}'.ljust(100), until=evt(r'"error"'), timeout=1) is None,
          "100 B: accepted")

    for ch in (1, 2):
        bench.channel(ch)
    bench.titrate()
    con.cmd("log evt info")
    if args.ble:
        bench.ble()
    bench.resources()

    errors = [ln for ln in con.lines if re.match(r"^E \(", ln) or re.search(r"Guru Meditation|abort\(\)|stack overflow", ln)]
    check(not errors, "no errors in the log" + "".join("\n      " + ln for ln in errors))
    for ln in (ln for ln in con.lines if re.match(r"^W \(", ln)):
        print("NOTE  " + ln)

    print(f"\nFAILED: {len(failed)} check(s)" if failed else "\nOK: all checks passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
