"""cleanpkg with changes that break its callers: greet lost a parameter,
and add gained a required one."""

__all__ = ["add", "greet"]


def add(a: int, b: int, c: int) -> int:
    """Return the sum of a, b and c."""
    return a + b + c


def greet(name: str) -> str:
    """Return a greeting for name."""
    return f"Hello, {name}!"
