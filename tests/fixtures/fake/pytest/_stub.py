"""Stand-in pytest. STUB_PYTEST_JUNIT: the JUnit report it writes (default
three passing tests); STUB_PYTEST_EXIT: its exit code (default 1 when the
report has a failure or error, else 0); STUB_PYTEST_COLLECT: what
--collect-only -q prints. Its own exit code 5 writes an empty report."""
import os
import re
import shutil
import sys

from _stubrecord import option, record

PASSING = """<?xml version="1.0" encoding="utf-8"?><testsuites><testsuite name="pytest" errors="0" failures="0" skipped="0" tests="3">
<testcase classname="tests.test_demo" name="test_one" file="tests/test_demo.py" line="2"/>
<testcase classname="tests.test_demo" name="test_two" file="tests/test_demo.py" line="6"/>
<testcase classname="tests.test_other" name="test_three" file="tests/test_other.py" line="2"/>
</testsuite></testsuites>
"""


def main(argv):
    record("pytest", argv)
    if "--collect-only" in argv:
        print(os.environ.get("STUB_PYTEST_COLLECT", "tests/test_demo.py::test_one\ntests/test_demo.py::test_two\n"
                             "tests/test_other.py::test_three\n\n3 tests collected in 0.01s"))
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
