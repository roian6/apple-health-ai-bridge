from __future__ import annotations

from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Self

import pytest

from health_bridge.launchd import LocalHealthProbe

if TYPE_CHECKING:
    from collections.abc import Callable

TEST_BODY_CAP = 4_096


@dataclass(slots=True)
class FakeClock:
    current: float = 0.0

    def __call__(self) -> float:
        return self.current


@dataclass(slots=True)
class FakeResponse:
    status: int
    chunks: list[bytes]
    clock: FakeClock
    advance_per_read: float = 0.0
    content_length: str | None = None
    read_sizes: list[int] = field(default_factory=list)

    def getheader(self, name: str) -> str | None:
        return self.content_length if name == "Content-Length" else None

    def read1(self, amount: int) -> bytes:
        self.read_sizes.append(amount)
        self.clock.current += self.advance_per_read
        if not self.chunks:
            return b""
        chunk = self.chunks.pop(0)
        returned = chunk[:amount]
        remainder = chunk[amount:]
        if remainder:
            self.chunks.insert(0, remainder)
        return returned

    def close(self) -> None:
        return


@dataclass(slots=True)
class FakeConnection:
    response: FakeResponse

    def request(self, method: str, target: str) -> None:
        assert (method, target) == ("GET", "/health")

    def getresponse(self) -> FakeResponse:
        return self.response

    def close(self) -> None:
        return

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *_args: object) -> None:
        self.close()


def _connection_factory(
    response: FakeResponse,
) -> Callable[[str, int, float, Callable[[], float]], FakeConnection]:
    def create(
        _host: str,
        _port: int,
        _deadline: float,
        _monotonic: Callable[[], float],
    ) -> FakeConnection:
        return FakeConnection(response)

    return create


def test_health_probe_enforces_one_monotonic_deadline_across_trickled_reads() -> None:
    clock = FakeClock()
    response = FakeResponse(
        status=200,
        chunks=[b"x"] * 20,
        clock=clock,
        advance_per_read=0.03,
    )

    probe = LocalHealthProbe(
        timeout_seconds=0.1,
        monotonic=clock,
        connection_factory=_connection_factory(response),
    )
    result = probe.probe("127.0.0.1", 8765)

    assert result.value == "unavailable"
    assert clock.current <= 0.12
    assert len(response.read_sizes) <= 4


def test_health_probe_rejects_response_whose_eof_arrives_after_deadline() -> None:
    clock = FakeClock()
    response = FakeResponse(
        status=200,
        chunks=[b'{"status":"ok"}'],
        clock=clock,
        advance_per_read=0.055,
    )

    probe = LocalHealthProbe(
        timeout_seconds=0.1,
        monotonic=clock,
        connection_factory=_connection_factory(response),
    )

    assert probe.probe("127.0.0.1", 8765).value == "unavailable"


def test_health_probe_caps_oversized_response_before_accumulating_body() -> None:
    clock = FakeClock()
    response = FakeResponse(
        status=200,
        chunks=[b"x" * (TEST_BODY_CAP * 8)],
        clock=clock,
    )

    probe = LocalHealthProbe(
        timeout_seconds=1.0,
        monotonic=clock,
        connection_factory=_connection_factory(response),
    )
    result = probe.probe("127.0.0.1", 8765)

    assert result.value == "unavailable"
    assert sum(response.read_sizes) <= TEST_BODY_CAP + 1


@pytest.mark.parametrize(
    "payload",
    [
        b"not-json",
        b'{"status":"ok"} trailing',
        b'{"status":"ok"' + b" " * TEST_BODY_CAP,
    ],
)
def test_health_probe_rejects_malformed_oversize_or_trailing_body(
    payload: bytes,
) -> None:
    clock = FakeClock()
    response = FakeResponse(status=200, chunks=[payload], clock=clock)
    probe = LocalHealthProbe(
        timeout_seconds=1.0,
        monotonic=clock,
        connection_factory=_connection_factory(response),
    )

    assert probe.probe("127.0.0.1", 8765).value == "unavailable"
