from pathlib import Path
from typing import Final, Protocol

import pytest
from pydantic import JsonValue, TypeAdapter
from ruamel.yaml import YAML

from health_bridge.mcp.types import JsonObject, required_list, required_object

FORM_PATHS: Final = {
    "bug_report": Path(".github/ISSUE_TEMPLATE/bug_report.yml"),
    "feature_request": Path(".github/ISSUE_TEMPLATE/feature_request.yml"),
    "setup_feedback": Path(".github/ISSUE_TEMPLATE/setup_feedback.yml"),
}
PRIVACY_CONFIRMATION_IDS: Final = {
    "bug_report": "privacy",
    "feature_request": "safety",
    "setup_feedback": "privacy",
}


class YamlLoader(Protocol):
    def load(self, stream: str) -> JsonValue: ...


def _load_form(loader: YamlLoader, path: Path) -> JsonObject:
    return TypeAdapter(dict[str, JsonValue]).validate_python(
        loader.load(path.read_text(encoding="utf-8"))
    )


def _fields(form: JsonObject) -> dict[str, JsonObject]:
    fields: dict[str, JsonObject] = {}
    for raw_field in required_list(form["body"]):
        field = required_object(raw_field)
        field_id = field.get("id")
        if isinstance(field_id, str):
            fields[field_id] = field
    return fields


@pytest.fixture
def forms() -> dict[str, JsonObject]:
    loader = YAML(typ="safe")
    return {name: _load_form(loader, path) for name, path in FORM_PATHS.items()}


def test_setup_form_offers_app_store_and_optional_visible_error(
    forms: dict[str, JsonObject],
) -> None:
    # Given: the parsed setup feedback form.
    fields = _fields(forms["setup_feedback"])
    flow = required_object(fields["flow"]["attributes"])
    flow_options = required_list(flow["options"])
    visible_error = required_object(fields["visible-error"]["validations"])

    # When: a contributor selects a setup route or supplies an error.
    # Then: App Store installation is a route, and an error is optional.
    assert "App Store installation" in flow_options
    assert visible_error["required"] is False


def test_bug_report_keeps_reproduction_required(forms: dict[str, JsonObject]) -> None:
    # Given: the parsed bug report form.
    fields = _fields(forms["bug_report"])

    # When: a contributor submits a bug report.
    # Then: reproduction remains mandatory.
    assert required_object(fields["reproduction"]["validations"])["required"] is True


def test_feature_request_allows_unknown_app_review_impact(
    forms: dict[str, JsonObject],
) -> None:
    # Given: the parsed feature request form.
    fields = _fields(forms["feature_request"])
    app_review = fields["app-review-impact"]
    app_review_attributes = required_object(app_review["attributes"])
    app_review_options = required_list(app_review_attributes["options"])
    app_review_validations = required_object(app_review["validations"])

    # When: a contributor cannot determine the specialist review impact.
    # Then: the required response can still describe uncertainty.
    assert app_review["type"] == "dropdown"
    assert app_review_validations["required"] is True
    assert "Unsure" in app_review_options


@pytest.mark.parametrize(
    ("form_name", "confirmation_id"),
    PRIVACY_CONFIRMATION_IDS.items(),
)
def test_issue_forms_keep_privacy_confirmations_required(
    forms: dict[str, JsonObject],
    form_name: str,
    confirmation_id: str,
) -> None:
    # Given: the parsed privacy confirmation field for each issue form.
    field = _fields(forms[form_name])[confirmation_id]
    attributes = required_object(field["attributes"])
    options = [
        required_object(option) for option in required_list(attributes["options"])
    ]

    # When: the issue form is submitted.
    # Then: every privacy confirmation remains required.
    assert options
    assert all(option["required"] is True for option in options)
