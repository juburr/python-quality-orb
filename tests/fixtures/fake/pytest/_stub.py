"""Stand-in pytest. STUB_PYTEST_JUNIT: the JUnit report it writes (default
three passing tests); STUB_PYTEST_EXIT: its exit code (default 1 when the
report has a failure or error, else 0); STUB_PYTEST_COLLECT:
what --collect-only prints (by default the node IDs, or the files with their
counts at verbosity -2 or less, counting PYTEST_ADDOPTS as pytest does);
STUB_PYTEST_COLLECT_EXIT: the collection's exit code. Its own exit code 5
writes an empty report."""
import os
import re
import shlex
import shutil
import sys

from _stubrecord import option, record

PASSING = """<?xml version="1.0" encoding="utf-8"?><testsuites><testsuite name="pytest" errors="0" failures="0" skipped="0" tests="3">
<testcase classname="tests.test_demo" name="test_one" file="tests/test_demo.py" line="2"/>
<testcase classname="tests.test_demo" name="test_two" file="tests/test_demo.py" line="6"/>
<testcase classname="tests.test_other" name="test_three" file="tests/test_other.py" line="2"/>
</testsuite></testsuites>
"""


NODE_IDS = ["tests/test_demo.py::test_one", "tests/test_demo.py::test_two", "tests/test_other.py::test_three"]


def verbosity(argv):
    """The verbosity pytest ends up with: PYTEST_ADDOPTS first, then the
    command line, each -q one less, each -v one more, --verbosity=N N."""
    level = 0
    for arg in shlex.split(os.environ.get("PYTEST_ADDOPTS", "")) + list(argv):
        if re.fullmatch(r"-q+", arg):
            level -= len(arg) - 1
        elif re.fullmatch(r"-v+", arg):
            level += len(arg) - 1
        elif arg in ("--quiet",):
            level -= 1
        elif arg.startswith("--verbosity="):
            level = int(arg.split("=", 1)[1])
    return level


def main(argv):
    record("pytest", argv)
    if "--collect-only" in argv:
        if os.environ.get("STUB_PYTEST_COLLECT_EXIT"):
            print("no tests collected in 0.01s")
            return int(os.environ["STUB_PYTEST_COLLECT_EXIT"])
        if os.environ.get("STUB_PYTEST_COLLECT"):
            print(os.environ["STUB_PYTEST_COLLECT"])
        elif verbosity(argv) <= -2:
            # As pytest does at -qq: each file with its count of tests.
            print("tests/test_demo.py: 2\ntests/test_other.py: 1")
        else:
            print("\n".join(NODE_IDS) + "\n\n3 tests collected in 0.01s")
        return 0
    junit = option(argv, "junitxml")
    code = os.environ.get("STUB_PYTEST_EXIT")
    source = os.environ.get("STUB_PYTEST_JUNIT")
    if code == "5":
        open(junit, "w").write('<testsuites><testsuite name="pytest" tests="0"/></testsuites>\n')
        print("no tests ran in 0.01s")
        return 5
    if code in ("2", "3", "4"):
        print("ERROR: interrupted: 1 error during collection")
        return int(code)
    text = open(source).read() if source else PASSING
    open(junit, "w").write(text)
    failed = re.search(r"<(failure|error)\b", text) is not None
    print("==== %s ====" % ("1 failed" if failed else "3 passed"))
    return int(code) if code else (1 if failed else 0)
