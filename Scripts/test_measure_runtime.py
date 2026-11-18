import ctypes
import os
from pathlib import Path
import resource
import runpy
import subprocess
import sys
import time
import unittest
from unittest.mock import patch


class CPUTimeTest(unittest.TestCase):
    def test_mach_counters_match_process_and_child_cpu_clocks(self):
        meter = runpy.run_path(str(Path(__file__).with_name("measure-runtime.py")))
        sample = meter["sample"]
        lib = ctypes.CDLL("/usr/lib/libproc.dylib")
        tick = meter["seconds_per_tick"]()
        with patch.dict(sample.__globals__, battery=lambda: {}):
            before = sample(lib, os.getpid(), tick)
            start = time.process_time()
            while time.process_time() - start < 0.08:
                pass
            child_before = resource.getrusage(resource.RUSAGE_CHILDREN)
            workload = """import time
start = time.process_time()
while time.process_time() - start < 0.08:
    pass
"""
            subprocess.run([sys.executable, "-c", workload], check=True)
            child_after = resource.getrusage(resource.RUSAGE_CHILDREN)
            elapsed = time.process_time() - start
            after = sample(lib, os.getpid(), tick)
        child_cpu = child_after.ru_utime + child_after.ru_stime - child_before.ru_utime - child_before.ru_stime
        self.assertAlmostEqual(after["cpu_seconds"] - before["cpu_seconds"], elapsed, delta=0.02)
        self.assertAlmostEqual(after["child_cpu_seconds"] - before["child_cpu_seconds"], child_cpu, delta=0.02)


if __name__ == "__main__":
    unittest.main()
