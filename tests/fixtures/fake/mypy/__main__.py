"""Stand-in mypy. STUB_MYPY_OUTPUT: a file of JSON lines to print;
STUB_MYPY_EXIT: the exit code (default 1 with an error, else 0);
STUB_MYPY_STDERR: text for stderr."""
import json
import os
import sys

from _stubrecord import record

argv = sys.argv[1:]
record("mypy", argv)
if "--version" in argv:
    print("mypy 2.4.0 (compiled: yes)")
    sys.exit(0)
if os.environ.get("STUB_MYPY_STDERR"):
    print(os.environ["STUB_MYPY_STDERR"], file=sys.stderr)
lines = []
if os.environ.get("STUB_MYPY_OUTPUT"):
    lines = [l for l in open(os.environ["STUB_MYPY_OUTPUT"]).read().splitlines() if l.strip()]
for line in lines:
    print(line)
errors = any(json.loads(l).get("severity") == "error" for l in lines if l.startswith("{"))
sys.exit(int(os.environ.get("STUB_MYPY_EXIT", "1" if errors else "0")))
