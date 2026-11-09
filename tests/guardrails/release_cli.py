from pathlib import Path
from subprocess import CompletedProcess

from tests.script_runner import run_script


def run_release_tool(*args: str) -> CompletedProcess[str]:
    """Run the real CLI parser and operations without restarting Python."""
    return run_script(Path("scripts/release_tools.py"), *args)
