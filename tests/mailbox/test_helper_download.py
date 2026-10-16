import httpx2
import pytest

from health_bridge.mailbox import helper_download as owner
from health_bridge.mailbox.helper_lifecycle import HelperResult, HelperStatusCode


def test_helper_discovery_refuses_foreign_or_unpublished_release() -> None:
    with pytest.raises(ValueError, match="draft"):
        _ = owner.Release.model_validate(
            {
                "tag_name": "receiver-v0.0.0",
                "draft": True,
                "prerelease": False,
                "assets": [],
            }
        )


@pytest.mark.parametrize(
    ("data", "digest"), [(b"synthetic", "0" * 64), (b"", "f" * 64)]
)
def test_download_integrity_is_checked_before_installer(
    data: bytes, digest: str
) -> None:
    with pytest.raises(ValueError, match="digest"):
        _ = owner.checked_bytes(data, digest)


@pytest.mark.parametrize(
    "url",
    [
        "http://github.com/file",
        "https://evil.invalid/file",
        "https://fixture-user:fixture-pass" + chr(64) + "github.com/file",
    ],
)
def test_helper_download_rejects_untrusted_routes(url: str) -> None:
    with pytest.raises(ValueError, match="HTTPS"):
        owner.require_release_url(url)


@pytest.mark.parametrize(
    ("status", "body", "limit", "error"),
    [(404, b"", 10, "not available"), (200, b"synthetic-too-large", 4, "limit")],
)
def test_download_missing_and_oversized_http_fixtures(
    status: int, body: bytes, limit: int, error: str
) -> None:
    def respond(request: httpx2.Request) -> httpx2.Response:
        return httpx2.Response(status, content=body, request=request)

    with (
        httpx2.Client(transport=httpx2.MockTransport(respond)) as client,
        pytest.raises(ValueError, match=error),
    ):
        _ = owner.download(client, "https://api.github.com/fixture-only", limit)


def test_ready_helper_os_status_fixture_reuses_without_network(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def ready(*, expected_version: str) -> HelperResult:
        assert expected_version
        return HelperResult(code=HelperStatusCode.READY)

    monkeypatch.setattr(owner, "read_helper_status", ready)
    assert owner.install_published_helper().code is HelperStatusCode.READY
