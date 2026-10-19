from html.parser import HTMLParser
from pathlib import Path

from typing_extensions import override


class BadgeParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.link: str | None = None
        self.badges: dict[str | None, dict[str, str | None]] = {}

    @override
    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        if tag == "a":
            self.link = attributes["href"]
        if tag == "img":
            self.badges[self.link] = attributes


def test_glama_score_is_a_linked_accessible_badge_in_existing_row() -> None:
    # Given: the README's existing HTML header.
    header = Path("README.md").read_text(encoding="utf-8").split("</div>", 1)[0]
    # When: parsing the badge row (its images use HTML void-element syntax).
    badge_row = header.rsplit("<p>", 1)[1].split("</p>", 1)[0]
    parser = BadgeParser()
    parser.feed(badge_row)
    # Then: a small linked score badge joins the four existing badges.
    assert len(parser.badges) == 5
    assert parser.badges[
        "https://glama.ai/mcp/servers/roian6/apple-health-ai-bridge"
    ] == {
        "src": "https://glama.ai/mcp/servers/roian6/apple-health-ai-bridge/badges/score.svg",
        "alt": "Glama tool quality and maintenance",
        "width": "110",
        "height": "20",
    }
