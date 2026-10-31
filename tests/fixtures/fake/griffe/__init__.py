"""Stand-in Griffe: load() finds a package in the search paths as Griffe's
finder does (raising ModuleNotFoundError when it isn't there), and
find_breaking_changes() yields the breakages in the JSON file
STUB_GRIFFE_BREAKAGES names: [{"kind", "path", "old", "new", "line",
"in_new"}]. STUB_GRIFFE_FAIL makes load() fail as on a syntax error."""
import enum
import json
import os

from _stubrecord import record


class ExplanationStyle(enum.Enum):
    ONE_LINE = "oneline"


class BreakageKind(enum.Enum):
    PARAMETER_REMOVED = "Parameter was removed"
    OBJECT_REMOVED = "Public object was removed"
    RETURN_CHANGED_TYPE = "Return types are incompatible"


class Obj:
    def __init__(self, path, filepath, lineno=None):
        self.path = path
        self.filepath = filepath
        self.lineno = lineno
        self.is_alias = False
        self.parent = None

    def get_member(self, name):
        for entry in _breakages():
            if entry["path"] == self.path + "." + name and entry.get("in_new", True):
                return Obj(entry["path"], self.filepath, entry.get("new_line", entry.get("line")))
        raise KeyError(name)


def _breakages():
    path = os.environ.get("STUB_GRIFFE_BREAKAGES")
    return json.load(open(path)) if path else []


def load(name, *, search_paths=(), try_relative_path=True, allow_inspection=True, **kwargs):
    record("griffe", ["load", name] + list(search_paths)
           + ["try_relative_path=%s" % try_relative_path, "allow_inspection=%s" % allow_inspection])
    if os.environ.get("STUB_GRIFFE_FAIL"):
        raise SyntaxError("invalid syntax (__init__.py, line 3)")
    for base in search_paths:
        init = os.path.join(base, name, "__init__.py")
        if os.path.isfile(init):
            return Obj(name, os.path.abspath(init))
    raise ModuleNotFoundError(name)


class Breakage:
    def __init__(self, entry, root):
        self.kind = BreakageKind[entry["kind"]]
        self.obj = Obj(entry["path"], root.filepath, entry.get("line"))
        self.old_value = entry.get("old")
        self.new_value = entry.get("new")

    def explain(self, style=ExplanationStyle.ONE_LINE):
        return "\x1b[1m%s\x1b[0m: %s" % (self.obj.path, self.kind.value)


def find_breaking_changes(old, new):
    for entry in _breakages():
        yield Breakage(entry, old)
