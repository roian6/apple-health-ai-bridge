import ast
import subprocess
import sys
from pathlib import Path


def test_native_entrypoint_imports_and_uses_atheris_directly() -> None:
    source = Path("scripts/fuzz/engine.py").read_text()
    module = ast.parse(source)
    main = next(
        node
        for node in module.body
        if isinstance(node, ast.FunctionDef) and node.name == "main"
    )

    imports = [
        node
        for node in main.body
        if isinstance(node, ast.Import)
        and any(alias.name == "atheris" for alias in node.names)
    ]

    assert imports, "Native main must execute a real, unconditional Atheris import"
    native_import = imports[0]
    assert "import atheris" in (ast.get_source_segment(source, native_import) or "")
    alias = next(alias for alias in native_import.names if alias.name == "atheris")
    binding = alias.asname or alias.name
    calls = {
        node.func.attr: node.lineno
        for node in ast.walk(main)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and isinstance(node.func.value, ast.Name)
        and node.func.value.id == binding
    }
    assert native_import.lineno < calls["instrument_imports"]
    assert calls["instrument_imports"] < calls["Setup"] < calls["Fuzz"]
    fresh_check = main.body[0]
    assert isinstance(fresh_check, ast.Expr)
    assert isinstance(fresh_check.value, ast.Call)
    assert isinstance(fresh_check.value.func, ast.Name)
    assert fresh_check.value.func.id == "require_fresh_imports"


def test_native_invocation_reaches_real_import_before_loading_engine() -> None:
    command = """
import runpy
import sys

def observe_import(event, args):
    if event == "import" and args[0] == "atheris":
        raise SystemExit(42)

sys.addaudithook(observe_import)
sys.argv = ["scripts.fuzz.engine", "batch"]
runpy.run_module("scripts.fuzz.engine", run_name="__main__")
"""

    result = subprocess.run(
        [sys.executable, "-c", command],
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )

    assert result.returncode == 42, result.stderr


def test_pure_modules_and_engine_definition_do_not_load_atheris() -> None:
    command = """
import sys

def reject_native_import(event, args):
    if event == "import" and args[0] == "atheris":
        raise AssertionError("native engine loaded outside invocation")

sys.addaudithook(reject_native_import)
import scripts.fuzz.targets
import scripts.fuzz.campaign
import scripts.fuzz.engine
assert "atheris" not in sys.modules
"""

    result = subprocess.run(
        [sys.executable, "-c", command],
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )

    assert result.returncode == 0, result.stderr
