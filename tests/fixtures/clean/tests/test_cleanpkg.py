from cleanpkg import add, greet


def test_add() -> None:
    assert add(2, 3) == 5


def test_greet() -> None:
    assert greet("world") == "Hello, world!"
    assert greet("you", "?") == "Hello, you?"
