"""A package every python-quality-orb check passes."""

__all__ = ["add", "greet"]


def add(a: int, b: int) -> int:
    """Return the sum of a and b."""
    return a + b


def greet(name: str, punctuation: str = "!") -> str:
    """Return a greeting for name."""
    return f"Hello, {name}{punctuation}"
