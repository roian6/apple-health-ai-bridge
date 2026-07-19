import base64
import json
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import ClassVar, Final, Literal, Self
from urllib.parse import parse_qs, urlencode, urlparse

from pydantic import BaseModel, ConfigDict, Field, ValidationError

from health_bridge.receiver.invitations import create_pairing_invitation
from health_bridge.receiver.tokens import create_receiver_token

PAIRING_SCHEMA_ID: Final = "health_bridge.receiver_pairing.v1"
PAIRING_SCHEMA_VERSION: Final = "1.0.0"
PAIRING_INVITATION_SCHEMA_ID: Final = "health_bridge.receiver_pairing_invitation.v2"
PAIRING_INVITATION_SCHEMA_VERSION: Final = "2.0.0"
PAIRING_DEEP_LINK_SCHEME: Final = "healthbridge"
PAIRING_DEEP_LINK_HOST: Final = "pair"
PAIRING_WARNING: Final = (
    "This pairing bundle contains a receiver bearer-token secret. "
    "Import it on your own device, then keep it out of chat, Git, wiki, and logs."
)
PAIRING_INVITATION_WARNING: Final = (
    "This setup contains a temporary, single-use invitation. "
    "Import it on your own device before it expires, then delete the setup artifact."
)
EMPTY_BEARER_MESSAGE: Final = "Pairing bundle bearer credential must not be empty."
INVALID_DEEP_LINK_MESSAGE: Final = "Pairing deep link must use healthbridge://pair."
MISSING_PAYLOAD_MESSAGE: Final = "Pairing deep link is missing payload."
INVALID_PAYLOAD_MESSAGE: Final = "Pairing deep link payload is invalid."
INVALID_URL_SCHEME_MESSAGE: Final = "Pairing receiver URL must use http or https."
INVALID_URL_HOST_MESSAGE: Final = "Pairing receiver URL must include a host."
CROSS_ORIGIN_REDEEM_MESSAGE: Final = (
    "Pairing redeem URL must use the same origin as the receiver URL."
)


class ReceiverPairingBundleError(ValueError):
    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message: str = message


class ReceiverPairingBundle(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, extra="forbid")

    schema_id: Literal["health_bridge.receiver_pairing.v1"] = PAIRING_SCHEMA_ID
    schema_version: Literal["1.0.0"] = PAIRING_SCHEMA_VERSION
    label: str
    receiver_url: str
    bearer_token: str
    token_prefix: str
    created_at: str
    warning: str = Field(default=PAIRING_WARNING)

    @classmethod
    def build(
        cls,
        *,
        label: str,
        receiver_url: str,
        bearer_token: str,
        token_prefix: str,
        created_at: str,
    ) -> Self:
        _validate_receiver_url(receiver_url)
        if not bearer_token.strip():
            raise ReceiverPairingBundleError(EMPTY_BEARER_MESSAGE)
        return cls(
            label=label,
            receiver_url=receiver_url,
            bearer_token=bearer_token,
            token_prefix=token_prefix,
            created_at=created_at,
        )


class ReceiverPairingInvitationPayload(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, extra="forbid")

    schema_id: Literal["health_bridge.receiver_pairing_invitation.v2"] = (
        PAIRING_INVITATION_SCHEMA_ID
    )
    schema_version: Literal["2.0.0"] = PAIRING_INVITATION_SCHEMA_VERSION
    label: str
    receiver_url: str
    redeem_url: str
    invitation_secret: str
    expires_at: str

    @classmethod
    def build(
        cls,
        *,
        label: str,
        receiver_url: str,
        redeem_url: str,
        invitation_secret: str,
        expires_at: str,
    ) -> Self:
        _validate_pairing_urls(receiver_url, redeem_url)
        if not invitation_secret.strip():
            raise ReceiverPairingBundleError(INVALID_PAYLOAD_MESSAGE)
        return cls(
            label=label,
            receiver_url=receiver_url,
            redeem_url=redeem_url,
            invitation_secret=invitation_secret,
            expires_at=expires_at,
        )


class ReceiverPairingInvitationBundle(BaseModel):
    model_config: ClassVar[ConfigDict] = ConfigDict(frozen=True, extra="forbid")

    schema_id: Literal["health_bridge.receiver_pairing_invitation.v2"] = (
        PAIRING_INVITATION_SCHEMA_ID
    )
    schema_version: Literal["2.0.0"] = PAIRING_INVITATION_SCHEMA_VERSION
    invitation_id: str
    label: str
    receiver_url: str
    redeem_url: str
    invitation_secret: str
    invitation_code: str
    created_at: str
    expires_at: str
    warning: str = Field(default=PAIRING_INVITATION_WARNING)

    def qr_payload(self) -> ReceiverPairingInvitationPayload:
        return ReceiverPairingInvitationPayload.build(
            label=self.label,
            receiver_url=self.receiver_url,
            redeem_url=self.redeem_url,
            invitation_secret=self.invitation_secret,
            expires_at=self.expires_at,
        )


def create_receiver_pairing_bundle(
    db_path: Path,
    *,
    label: str,
    receiver_url: str,
    token: str | None = None,
    created_at: str | None = None,
) -> ReceiverPairingBundle:
    _validate_receiver_url(receiver_url)
    issued = create_receiver_token(db_path, label=label, token=token)
    return ReceiverPairingBundle.build(
        label=issued.label,
        receiver_url=receiver_url,
        bearer_token=issued.token,
        token_prefix=issued.token_prefix,
        created_at=created_at or _utc_now(),
    )


def create_receiver_pairing_invitation_bundle(  # noqa: PLR0913 - deterministic test hooks.
    db_path: Path,
    *,
    label: str,
    receiver_url: str,
    now: datetime | None = None,
    expires_in: timedelta | None = None,
    invitation_secret: str | None = None,
    invitation_code: str | None = None,
) -> ReceiverPairingInvitationBundle:
    invitation_ttl = timedelta(minutes=20) if expires_in is None else expires_in
    issued = create_pairing_invitation(
        db_path,
        label=label,
        receiver_url=receiver_url,
        now=now,
        expires_in=invitation_ttl,
        invitation_secret=invitation_secret,
        invitation_code=invitation_code,
    )
    return ReceiverPairingInvitationBundle(
        invitation_id=issued.invitation_id,
        label=issued.label,
        receiver_url=issued.receiver_url,
        redeem_url=issued.redeem_url,
        invitation_secret=issued.invitation_secret,
        invitation_code=issued.invitation_code,
        created_at=issued.created_at,
        expires_at=issued.expires_at,
    )


def pairing_deep_link(
    bundle: ReceiverPairingBundle | ReceiverPairingInvitationBundle,
) -> str:
    payload: ReceiverPairingBundle | ReceiverPairingInvitationPayload
    if isinstance(bundle, ReceiverPairingInvitationBundle):
        payload = bundle.qr_payload()
    else:
        payload = bundle
    json_payload = json.dumps(
        payload.model_dump(mode="json"),
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    encoded_payload = (
        base64.urlsafe_b64encode(json_payload).rstrip(b"=").decode("ascii")
    )
    return (
        f"{PAIRING_DEEP_LINK_SCHEME}://{PAIRING_DEEP_LINK_HOST}?"
        f"{urlencode({'payload': encoded_payload})}"
    )


def pairing_bundle_from_deep_link(deep_link: str) -> ReceiverPairingBundle:
    decoded = _decoded_deep_link_payload(deep_link)
    try:
        bundle = ReceiverPairingBundle.model_validate_json(decoded)
    except (ValueError, ValidationError, json.JSONDecodeError) as exc:
        raise ReceiverPairingBundleError(INVALID_PAYLOAD_MESSAGE) from exc
    _validate_receiver_url(bundle.receiver_url)
    return bundle


def pairing_invitation_from_deep_link(
    deep_link: str,
) -> ReceiverPairingInvitationPayload:
    decoded = _decoded_deep_link_payload(deep_link)
    try:
        invitation = ReceiverPairingInvitationPayload.model_validate_json(decoded)
    except (ValueError, ValidationError, json.JSONDecodeError) as exc:
        raise ReceiverPairingBundleError(INVALID_PAYLOAD_MESSAGE) from exc
    _validate_pairing_urls(invitation.receiver_url, invitation.redeem_url)
    return invitation


def _decoded_deep_link_payload(deep_link: str) -> bytes:
    parsed = urlparse(deep_link)
    if (
        parsed.scheme != PAIRING_DEEP_LINK_SCHEME
        or parsed.netloc != PAIRING_DEEP_LINK_HOST
    ):
        raise ReceiverPairingBundleError(INVALID_DEEP_LINK_MESSAGE)
    payloads = parse_qs(parsed.query).get("payload")
    if not payloads:
        raise ReceiverPairingBundleError(MISSING_PAYLOAD_MESSAGE)
    payload = payloads[0]
    padded_payload = payload + "=" * (-len(payload) % 4)
    try:
        return base64.urlsafe_b64decode(padded_payload.encode("ascii"))
    except ValueError as exc:
        raise ReceiverPairingBundleError(INVALID_PAYLOAD_MESSAGE) from exc


def _validate_pairing_urls(receiver_url: str, redeem_url: str) -> None:
    _validate_receiver_url(receiver_url)
    _validate_receiver_url(redeem_url)
    receiver = urlparse(receiver_url)
    redeem = urlparse(redeem_url)
    if (receiver.scheme.lower(), receiver.netloc.lower()) != (
        redeem.scheme.lower(),
        redeem.netloc.lower(),
    ):
        raise ReceiverPairingBundleError(CROSS_ORIGIN_REDEEM_MESSAGE)


def _validate_receiver_url(receiver_url: str) -> None:
    parsed = urlparse(receiver_url)
    if parsed.scheme not in {"http", "https"}:
        raise ReceiverPairingBundleError(INVALID_URL_SCHEME_MESSAGE)
    if not parsed.netloc:
        raise ReceiverPairingBundleError(INVALID_URL_HOST_MESSAGE)


def _utc_now() -> str:
    return datetime.now(tz=UTC).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")
