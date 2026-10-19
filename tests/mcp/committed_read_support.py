from collections.abc import Generator
from contextlib import contextmanager
from pathlib import Path
from selectors import EVENT_READ, DefaultSelector
from subprocess import PIPE, Popen, TimeoutExpired
from typing import Final

from pydantic import JsonValue, TypeAdapter

from health_bridge.mcp.types import JsonObject, required_object, required_string

JSON_OBJECT: Final = TypeAdapter(dict[str, JsonValue])
WRITER: Final = """
import sqlite3
import sys
from pathlib import Path
from health_bridge.storage.database import connect_database

with connect_database(Path(sys.argv[1])) as connection:
    connection.execute('pragma busy_timeout = 0')
    connection.execute('begin immediate')
    connection.execute('delete from samples')
    connection.execute('delete from workouts')
    print('ready', flush=True)
    for line in sys.stdin:
        if line.strip() == 'commit':
            try:
                connection.commit()
            except sqlite3.OperationalError:
                print('blocked', flush=True)
            else:
                print('committed', flush=True)
        elif line.strip() == 'quit':
            break
"""


@contextmanager
def line_process(command: list[str]) -> Generator[Popen[str], None, None]:
    process = Popen(command, stdin=PIPE, stdout=PIPE, stderr=PIPE, text=True)
    try:
        yield process
    finally:
        if process.poll() is None:
            process.terminate()
        try:
            _, stderr = process.communicate(timeout=5)
        except TimeoutExpired:
            process.kill()
            _, stderr = process.communicate(timeout=5)
        assert stderr == ""


def receive(process: Popen[str]) -> str:
    assert process.stdout is not None
    with DefaultSelector() as selector:
        _ = selector.register(process.stdout, EVENT_READ)
        assert selector.select(timeout=5), "child response deadline expired"
    line = TypeAdapter(str).validate_python(process.stdout.readline())
    assert line, "child exited before responding"
    return line.rstrip("\n")


def send(process: Popen[str], line: str) -> str:
    assert process.stdin is not None
    _ = process.stdin.write(line + "\n")
    process.stdin.flush()
    return receive(process)


def status_request(request_id: int = 1) -> JsonObject:
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": "tools/call",
        "params": {"name": "get_bridge_status", "arguments": {}},
    }


def status_payload(response: JsonObject) -> JsonObject:
    assert "result" in response, "committed snapshot must remain available"
    result = required_object(response["result"])
    content = result["content"]
    assert isinstance(content, list)
    return JSON_OBJECT.validate_json(
        required_string(required_object(content[0])["text"])
    )


def cli_command(db_path: Path) -> list[str]:
    return ["health-bridge", "status", "--json", "--db", str(db_path)]
