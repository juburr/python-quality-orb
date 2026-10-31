"""Stand-in coverage.py. run runs the stand-in pytest; combine, json, xml and
report work on the data file COVERAGE_FILE names. STUB_COVERAGE_TOTALS: the
JSON report's totals (default 90 of 100 lines covered); STUB_COVERAGE_NODATA:
nothing was measured; STUB_COVERAGE_FAIL_UNDER: the project's fail_under,
which every reporting command applies unless given --fail-under."""
import json
import os
import sys

from _stubrecord import option, record

argv = sys.argv[1:]
record("coverage", argv)
action = argv[0]
data = os.environ.get("COVERAGE_FILE", ".coverage")
totals = json.loads(os.environ.get("STUB_COVERAGE_TOTALS") or
                    '{"covered_lines": 90, "num_statements": 100, "percent_covered": 90.0, "missing_lines": 10}')
percent = totals["percent_covered"]


def fail_under():
    given = option(argv, "fail-under")
    if given is not None:
        return float(given)
    return float(os.environ.get("STUB_COVERAGE_FAIL_UNDER", "0"))


if action == "run":
    from pytest._stub import main
    open(data + ".host.1.123", "w").write("data")
    sys.exit(main(argv[argv.index("pytest") + 1:]))
if action == "combine":
    if os.environ.get("STUB_COVERAGE_NODATA"):
        print("No data to combine")
        sys.exit(1)
    open(data, "w").write("combined")
    sys.exit(0)
if not os.path.exists(data):
    print("No data to report.")
    sys.exit(1)
if action == "json":
    json.dump({"meta": {"version": "7.17.0"}, "files": {}, "totals": totals}, open(option(argv, "o") or argv[argv.index("-o") + 1], "w"))
elif action == "xml":
    open(argv[argv.index("-o") + 1], "w").write('<?xml version="1.0" ?><coverage line-rate="0.9"/>\n')
elif action == "report":
    print("Name    Stmts   Miss  Cover\nTOTAL     %d     %d    %d%%" % (totals["num_statements"], totals["num_statements"] - totals["covered_lines"], percent))
if percent < fail_under():
    print("Coverage failure: total of %d is less than fail-under=%d" % (percent, fail_under()))
    sys.exit(2)
sys.exit(0)
