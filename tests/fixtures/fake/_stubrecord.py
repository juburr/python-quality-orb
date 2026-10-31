"""Records a stand-in's call as tests/commands_test.sh reads it."""
import os


def record(tool, argv):
    calls = os.path.join(os.environ["STUB_DIR"], "calls")
    os.makedirs(calls, exist_ok=True)
    n = len([f for f in os.listdir(calls) if f.endswith(".args")]) + 1
    with open(os.path.join(calls, "%d.args" % n), "w") as f:
        f.write("\n".join([tool] + list(argv)) + "\n")
    with open(os.path.join(calls, "%d.meta" % n), "w") as f:
        f.write("cwd=%s\n" % os.getcwd())
        for key in sorted(os.environ):
            if key.startswith(("MYPY_", "COVERAGE_", "PYTEST_")):
                f.write("%s=%s\n" % (key, os.environ[key]))


def option(argv, name):
    """The value of --NAME VALUE or --NAME=VALUE in argv, or None."""
    for i, arg in enumerate(argv):
        if arg == "--" + name and i + 1 < len(argv):
            return argv[i + 1]
        if arg.startswith("--" + name + "="):
            return arg.split("=", 1)[1]
    return None
