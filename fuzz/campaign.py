import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Final

TARGETS: Final = ("batch", "mcp_dates")
ARGUMENT_COUNT: Final = 2
PROGRESS: Final = re.compile(
    r"^#(\d+)\s+(INITED|NEW|DONE)\s+cov:\s+(\d+)\s+ft:\s+(\d+)",
    re.MULTILINE,
)


def engine_command(target: str, workspace: Path, *, mutation: bool) -> list[str]:
    return [
        sys.executable,
        "-m",
        "fuzz.engine",
        target,
        str(workspace / "corpus"),
        f"-artifact_prefix={workspace / 'artifacts'}/",
        "-max_len=4096",
        "-timeout=5",
        "-rss_limit_mb=512",
        "-seed=20260601",
        "-print_final_stats=1",
        "-max_total_time=45" if mutation else "-runs=0",
    ]


def require_mutation_evidence(log: str) -> None:
    progress = list(PROGRESS.finditer(log))
    initial = [row for row in progress if row[2] == "INITED"]
    final = [row for row in progress if row[2] == "DONE"]
    if initial and final and any(row[2] == "NEW" for row in progress):
        start, finish = initial[-1], final[-1]
        if (
            int(finish[1]) > int(start[1])
            and int(start[3]) > 0
            and int(finish[3]) >= int(start[3])
            and int(finish[4]) > int(start[4])
        ):
            return
    message = "Native mutation must execute new inputs and grow coverage features"
    raise RuntimeError(message)


def run_engine(command: list[str], log: Path) -> None:
    with log.open("x", encoding="utf-8") as output:
        _ = subprocess.run(  # noqa: S603 - explicit argv, no shell.
            command,
            stdout=output,
            stderr=subprocess.STDOUT,
            timeout=90,
            check=True,
        )


def main() -> None:
    if len(sys.argv) != ARGUMENT_COUNT:
        message = "usage: python -m fuzz.campaign EMPTY_TEMP_DIRECTORY"
        raise SystemExit(message)
    scratch = Path(sys.argv[1]).resolve()
    scratch.mkdir(parents=True, exist_ok=True)
    corpus_root = Path(__file__).parent / "corpus"
    for target in TARGETS:
        workspace = scratch / target
        workspace.mkdir()
        _ = shutil.copytree(corpus_root / target, workspace / "corpus")
        (workspace / "artifacts").mkdir()
        run_engine(
            engine_command(target, workspace, mutation=False),
            workspace / "replay.log",
        )
        log = workspace / "mutation.log"
        run_engine(engine_command(target, workspace, mutation=True), log)
        output = log.read_text(encoding="utf-8")
        require_mutation_evidence(output)
        summary = [row for row in PROGRESS.finditer(output) if row[2] == "DONE"][-1]
        print(  # noqa: T201 - aggregate campaign result for CLI/CI.
            f"{target}: executions={summary[1]}",
            f"coverage={summary[3]} features={summary[4]}",
        )


if __name__ == "__main__":
    main()
