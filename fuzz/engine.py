import sys
from collections.abc import Callable, Sequence
from contextlib import AbstractContextManager
from importlib import import_module
from typing import Protocol, runtime_checkable


@runtime_checkable
class Atheris(Protocol):
    def instrument_imports(
        self, *, include: Sequence[str]
    ) -> AbstractContextManager[None]: ...

    def Setup(  # noqa: N802 - Atheris public API spelling.
        self, args: list[str], callback: Callable[[bytes], bool]
    ) -> None: ...

    def Fuzz(self) -> None: ...  # noqa: N802 - Atheris public API spelling.


def require_fresh_imports() -> None:
    if "fuzz.targets" in sys.modules or any(
        name == "health_bridge" or name.startswith("health_bridge.")
        for name in sys.modules
    ):
        message = "Run fuzz.engine in a fresh process before importing product code"
        raise RuntimeError(message)


def main() -> None:
    require_fresh_imports()
    engine = import_module("atheris")
    if not isinstance(engine, Atheris):
        message = "The installed Atheris does not expose the required engine API"
        raise TypeError(message)
    with engine.instrument_imports(include=("health_bridge", "fuzz")):
        from fuzz.targets import batch, mcp_dates  # noqa: PLC0415

    target = {"batch": batch, "mcp_dates": mcp_dates}[sys.argv[1]]
    engine.Setup([sys.argv[0], *sys.argv[2:]], target)
    engine.Fuzz()


if __name__ == "__main__":
    main()
