import runpy
import subprocess
import sys
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path

import pytest

ROOT = Path(__file__).parents[1]


def run_script(
    script: Path, *args: str, process: bool = False
) -> subprocess.CompletedProcess[str]:
    """Exercise a real script, retaining subprocess mode for boundary acceptance."""
    script_path = ROOT / script
    command = [sys.executable, str(script_path), *args]
    if process:
        return subprocess.run(
            command, cwd=ROOT, capture_output=True, text=True, check=False, timeout=30
        )
    stdout = StringIO()
    stderr = StringIO()
    with (
        pytest.MonkeyPatch.context() as environment,
        redirect_stdout(stdout),
        redirect_stderr(stderr),
    ):
        environment.chdir(ROOT)
        environment.setattr(sys, "path", [str(script_path.parent), *sys.path])
        environment.setattr(sys, "argv", command[1:])
        with pytest.raises(SystemExit) as exited:
            _ = runpy.run_path(str(script_path), run_name="__main__")
        code = exited.value.code
    assert isinstance(code, int)
    return subprocess.CompletedProcess(
        command, code, stdout.getvalue(), stderr.getvalue()
    )
