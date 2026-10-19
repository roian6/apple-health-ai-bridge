from html.parser import HTMLParser
from pathlib import Path
from typing import Final

from typing_extensions import override

PROJECT: Final = "github.com/roian6/apple-health-ai-bridge"
BADGE_URL: Final = f"https://api.scorecard.dev/projects/{PROJECT}/badge"
RESULT_URL: Final = f"https://scorecard.dev/viewer/?uri={PROJECT}"


class LinkedImageParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.href: str | None = None
        self.images: list[tuple[str | None, dict[str, str | None]]] = []

    @override
    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        if tag == "a":
            self.href = attributes.get("href")
        elif tag == "img":
            self.images.append((self.href, attributes))

    @override
    def handle_endtag(self, tag: str) -> None:
        if tag == "a":
            self.href = None


def test_readme_links_official_dynamic_scorecard_badge_to_actual_results() -> None:
    parser = LinkedImageParser()
    parser.feed(Path("README.md").read_text(encoding="utf-8"))
    parser.close()
    matches = [item for item in parser.images if item[1].get("src") == BADGE_URL]
    assert len(matches) == 1
    href, image = matches[0]
    assert href == RESULT_URL
    assert image.get("alt") == "OpenSSF Scorecard"
    assert image.get("height") == "20"
