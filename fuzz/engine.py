# pyright: reportMissingModuleSource=false
# Local stubs type the API even when the optional native runtime is absent.
import sys


def require_fresh_imports() -> None:
    if "fuzz.targets" in sys.modules or any(
        name == "health_bridge" or name.startswith("health_bridge.")
        for name in sys.modules
    ):
        message = "Run fuzz.engine in a fresh process before importing product code"
        raise RuntimeError(message)


def main() -> None:
    require_fresh_imports()
    import atheris  # noqa: PLC0415 - optional engine, loaded only on invocation.

    with atheris.instrument_imports(include=("health_bridge", "fuzz")):
        from fuzz.targets import batch, mcp_dates  # noqa: PLC0415

    target = {"batch": batch, "mcp_dates": mcp_dates}[sys.argv[1]]
    _ = atheris.Setup([sys.argv[0], *sys.argv[2:]], target)
    atheris.Fuzz()


if __name__ == "__main__":
    main()
