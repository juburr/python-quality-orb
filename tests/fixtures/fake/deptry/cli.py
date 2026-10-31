"""Stand-in deptry. STUB_DEPTRY_JSON: the violations it reports;
STUB_DEPTRY_FILES: how many files it says it scans (default 3);
STUB_DEPTRY_CRASH: fail before writing the report."""
import os
import shutil
import sys

from _stubrecord import option, record


def deptry():
    argv = sys.argv[1:]
    record("deptry", argv)
    if "--version" in argv:
        print("deptry 0.25.1")
        sys.exit(0)
    print("Scanning %s files..." % os.environ.get("STUB_DEPTRY_FILES", "3"))
    if os.environ.get("STUB_DEPTRY_CRASH"):
        print("Traceback (most recent call last):\nValueError: no [project] table", file=sys.stderr)
        sys.exit(1)
    out = option(argv, "json-output")
    source = os.environ.get("STUB_DEPTRY_JSON")
    if source:
        shutil.copy(source, out)
        import json
        found = len(json.load(open(source)))
    else:
        open(out, "w").write("[]")
        found = 0
    print("Found %d dependency issues." % found if found else "Success! No dependency issues found.")
    sys.exit(1 if found else 0)
