import subprocess
import sys
from pathlib import Path


def test_committed_self_test_fixture_passes_through_real_module_surface() -> None:
    # Given
    command = [
        sys.executable,
        "-m",
        "health_bridge.contract.delivery_v1",
        "--self-test",
        str(Path("fixtures/delivery_v1.synthetic.json")),
    ]
    # When
    result = subprocess.run(command, capture_output=True, check=False, timeout=30)
    # Then
    assert result.returncode == 0
    assert result.stdout == b'{"ack_cases":1,"delivery_cases":1}\n'
    assert result.stderr == b""


def test_deep_self_test_descriptor_fails_closed_without_traceback(
    tmp_path: Path,
) -> None:
    descriptor = tmp_path / "deep.synthetic.json"
    _ = descriptor.write_bytes(b'{"v":' + b"[" * 1_200 + b"0" + b"]" * 1_200 + b"}")
    command = [
        sys.executable,
        "-m",
        "health_bridge.contract.delivery_v1",
        "--self-test",
        str(descriptor),
    ]

    result = subprocess.run(command, capture_output=True, check=False, timeout=30)

    assert result.returncode == 2
    assert result.stdout == b"payload_invalid\n"
    assert result.stderr == b""
