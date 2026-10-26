from collections.abc import Callable, Sequence
from types import TracebackType
from typing import Protocol, Self

class _ImportHook(Protocol):
    def __enter__(self) -> Self: ...
    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None: ...

def instrument_imports(
    include: Sequence[str] | None = None,
    exclude: Sequence[str] | None = None,
    enable_loader_override: bool = True,
) -> _ImportHook: ...
def Setup(  # noqa: N802 - Atheris public API spelling.
    args: Sequence[str], test_one_input: Callable[[bytes], bool | None], /
) -> list[str]: ...
def Fuzz() -> None: ...  # noqa: N802 - Atheris public API spelling.
