#!/usr/bin/env python3
"""Measure the running app and whole-Mac battery state without changing either."""

import argparse
import ctypes
import datetime
import json
import pathlib
import plistlib
import subprocess
import time


class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64)
        for name in (
            "user_time", "system_time", "idle_wakeups", "interrupt_wakeups",
            "pageins", "wired_size", "resident_size", "footprint", "start", "exit",
            "child_user_time", "child_system_time", "child_idle_wakeups",
            "child_interrupt_wakeups", "child_pageins", "child_elapsed",
            "disk_read", "disk_written",
        )
    ]


def battery():
    raw = subprocess.check_output(["/usr/sbin/ioreg", "-a", "-r", "-c", "AppleSmartBattery"])
    records = plistlib.loads(raw)
    if not records:
        return {}
    return {key: records[0].get(key) for key in (
        "ExternalConnected", "IsCharging", "CurrentCapacity", "MaxCapacity",
        "AppleRawCurrentCapacity", "AppleRawMaxCapacity", "Voltage", "Amperage",
        "InstantAmperage", "Temperature",
    )}


def sample(lib, pid):
    usage = Usage()
    if lib.proc_pid_rusage(pid, 2, ctypes.byref(usage)) != 0:
        raise RuntimeError("The measured app exited or its counters are unavailable.")
    return {
        "at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "monotonic": time.monotonic(),
        "cpu_seconds": (usage.user_time + usage.system_time) / 1e9,
        "child_cpu_seconds": (usage.child_user_time + usage.child_system_time) / 1e9,
        "idle_wakeups": usage.idle_wakeups + usage.child_idle_wakeups,
        "rss_mib": usage.resident_size / 1048576,
        "footprint_mib": usage.footprint / 1048576,
        "battery": battery(),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--seconds", type=int, default=600)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if args.seconds < 1 or args.seconds > 3600:
        parser.error("--seconds must be between 1 and 3600")
    lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    lib.proc_pid_rusage.restype = ctypes.c_int
    args.output.parent.mkdir(parents=True, exist_ok=True)
    first = sample(lib, args.pid)
    samples = [first]
    print(json.dumps({"started": first["at"], "pid": args.pid, "battery": first["battery"]}), flush=True)
    while time.monotonic() - first["monotonic"] < args.seconds:
        time.sleep(min(5, max(0, args.seconds - (time.monotonic() - first["monotonic"]))))
        samples.append(sample(lib, args.pid))
        args.output.write_text(json.dumps({"samples": samples}, indent=2))
    last = samples[-1]
    elapsed = last["monotonic"] - first["monotonic"]
    cpu = last["cpu_seconds"] - first["cpu_seconds"]
    child_cpu = last["child_cpu_seconds"] - first["child_cpu_seconds"]
    result = {
        "elapsed_seconds": elapsed,
        "app_cpu_seconds": cpu,
        "terminated_helper_cpu_seconds": child_cpu,
        "average_cpu_percent_of_one_core": (cpu + child_cpu) / elapsed * 100,
        "idle_wakeups_per_second": (last["idle_wakeups"] - first["idle_wakeups"]) / elapsed,
        "peak_rss_mib": max(item["rss_mib"] for item in samples),
        "peak_footprint_mib": max(item["footprint_mib"] for item in samples),
        "battery_only_samples": sum(item["battery"].get("ExternalConnected") is False for item in samples),
        "sample_count": len(samples),
        "battery_start": first["battery"],
        "battery_end": last["battery"],
        "battery_scope": "Whole Mac; battery consumption cannot be attributed to this app alone.",
    }
    args.output.write_text(json.dumps({"summary": result, "samples": samples}, indent=2))
    print(json.dumps(result, indent=2), flush=True)


if __name__ == "__main__":
    main()
