"""Talk to the titrator from the PC over BLE (BlueZ D-Bus), like the app does.

usage: btcmd.py [--mac MAC] [--gap S] <json> ...

Connects to the first device named Titrator-* (or MAC), subscribes to EVT,
writes each argument to CMD --gap seconds apart (default 1.5) and prints
every event except `ph`, which is only counted. "@N" sends {"cmd":"stop"}
padded with blanks to N bytes (length limit tests).

Needs dbus-python and PyGObject: run it with the system python3, not the
ESP-IDF one.
"""
import argparse
import time

import dbus
import dbus.mainloop.glib
from gi.repository import GLib

CMD = "f65c0002-8221-4068-aa47-28e41eec47fd"
EVT = "f65c0003-8221-4068-aa47-28e41eec47fd"
NAME_PREFIX = "Titrator-"

dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
bus = dbus.SystemBus()
objects = dbus.Interface(bus.get_object("org.bluez", "/"), "org.freedesktop.DBus.ObjectManager")


def find_device(mac):
    for path, ifaces in objects.GetManagedObjects().items():
        dev = ifaces.get("org.bluez.Device1")
        if dev and (str(dev["Address"]) == mac if mac else str(dev.get("Name", "")).startswith(NAME_PREFIX)):
            return path
    return None


def discover(mac, secs=10.0):
    """Path of the device, scanning for up to secs if BlueZ does not know it."""
    path = find_device(mac)
    if path:
        return path
    adapter = dbus.Interface(bus.get_object("org.bluez", "/org/bluez/hci0"), "org.bluez.Adapter1")
    adapter.SetDiscoveryFilter({"Transport": "le"})
    adapter.StartDiscovery()
    try:
        end = time.time() + secs
        while not path and time.time() < end:
            time.sleep(0.5)
            path = find_device(mac)
    finally:
        adapter.StopDiscovery()
    return path


def find_char(dev_path, uuid):
    for path, ifaces in objects.GetManagedObjects().items():
        c = ifaces.get("org.bluez.GattCharacteristic1")
        if c and str(c["UUID"]) == uuid and path.startswith(dev_path + "/"):
            return bus.get_object("org.bluez", path)
    raise SystemExit(f"characteristic {uuid} not found: not a titrator?")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("cmds", nargs="*")
    ap.add_argument("--mac")
    ap.add_argument("--gap", type=float, default=1.5)
    args = ap.parse_args()

    dev_path = discover(args.mac)
    if not dev_path:
        raise SystemExit("no titrator found")
    dev = bus.get_object("org.bluez", dev_path)
    dbus.Interface(dev, "org.bluez.Device1").Connect()
    props = dbus.Interface(dev, "org.freedesktop.DBus.Properties")
    for _ in range(40):
        if props.Get("org.bluez.Device1", "ServicesResolved"):
            break
        time.sleep(0.25)
    evt = dbus.Interface(find_char(dev_path, EVT), "org.bluez.GattCharacteristic1")
    cmd = dbus.Interface(find_char(dev_path, CMD), "org.bluez.GattCharacteristic1")

    t0 = time.time()
    ph = 0

    def on_change(iface, changed, invalidated):
        nonlocal ph
        if "Value" not in changed:
            return
        msg = bytes(changed["Value"]).decode(errors="replace")
        if '"evt":"ph"' in msg:
            ph += 1
        else:
            print(f"{time.time() - t0:6.2f}s  <- {msg}", flush=True)

    bus.add_signal_receiver(on_change, "PropertiesChanged", "org.freedesktop.DBus.Properties",
                            path=evt.object_path)
    evt.StartNotify()

    msgs = ['{"cmd":"stop"}'.ljust(int(a[1:])) if a.startswith("@") else a for a in args.cmds]
    loop = GLib.MainLoop()

    def step():
        if not msgs:
            GLib.timeout_add(int(args.gap * 1000), loop.quit)
            return False
        m = msgs.pop(0).encode()
        print(f"{time.time() - t0:6.2f}s  -> {m.decode()!r} ({len(m)} B)", flush=True)
        try:
            cmd.WriteValue(dbus.Array(m, signature="y"), {"type": "request"})
        except dbus.DBusException as e:
            print("   write failed:", e.get_dbus_message(), flush=True)
        return True

    GLib.timeout_add(int(args.gap * 1000), step)
    loop.run()
    evt.StopNotify()
    dbus.Interface(dev, "org.bluez.Device1").Disconnect()
    print("ph events:", ph)


if __name__ == "__main__":
    main()
