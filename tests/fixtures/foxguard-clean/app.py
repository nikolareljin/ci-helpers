"""A file foxguard parses and reports nothing on; the clean self-test fixture."""


def greet(name: str) -> str:
    return "hello, " + name


if __name__ == "__main__":
    print(greet("world"))
