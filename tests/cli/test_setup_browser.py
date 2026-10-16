import sys
import threading
import webbrowser

import pytest
from typer.testing import CliRunner

from health_bridge import cli
from health_bridge import cli_setup_interactive as guided


@pytest.mark.parametrize("outcome", [True, False, "error"])
def test_browser_always_leaves_copyable_url(
    outcome: bool | str,
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    # Given a deliberately synthetic private-page URL and a local browser seam.
    url = "https://synthetic.invalid/setup/fixture-only"
    monkeypatch.setenv("DISPLAY", ":fixture")

    def open_browser(_url: str) -> bool:
        if outcome == "error":
            message = "synthetic unavailable browser"
            raise webbrowser.Error(message)
        return bool(outcome)

    monkeypatch.setattr(webbrowser, "open", open_browser)
    # When the human requests the setup page.
    guided.open_page(url)
    # Then the URL remains copyable even on browser success or error.
    assert url in capsys.readouterr().out


def test_ssh_never_attempts_unseen_browser(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("SSH_CONNECTION", "synthetic session")
    monkeypatch.setattr(sys, "platform", "darwin")

    def unexpected(_url: str) -> bool:
        pytest.fail("SSH must not launch a browser on an unseen Mac")

    monkeypatch.setattr(webbrowser, "open", unexpected)
    guided.open_page("http://127.0.0.1:8080/setup/fixture-only")
    assert "http://127.0.0.1:8080/setup/fixture-only" in capsys.readouterr().out


def test_setup_accepts_no_browser_without_enabling_interaction() -> None:
    result = CliRunner().invoke(cli.app, ["setup", "--no-browser", "--help"])
    assert result.exit_code == 0


def test_no_browser_policy_prints_url_without_opening(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setenv("DISPLAY", ":fixture")

    def unexpected(_url: str) -> bool:
        pytest.fail("--no-browser must not launch a browser")

    monkeypatch.setattr(webbrowser, "open", unexpected)
    with guided.browser_policy(enabled=False):
        guided.open_page("https://synthetic.invalid/setup/fixture-only")
    assert "https://synthetic.invalid/setup/fixture-only" in capsys.readouterr().out


def test_browser_wait_is_bounded(monkeypatch: pytest.MonkeyPatch) -> None:
    release = threading.Event()

    def blocked(_url: str) -> bool:
        _ = release.wait(timeout=2)
        return True

    monkeypatch.setattr(webbrowser, "open", blocked)
    try:
        assert guided.open_browser_bounded("https://synthetic.invalid", 0.01) is False
    finally:
        release.set()
