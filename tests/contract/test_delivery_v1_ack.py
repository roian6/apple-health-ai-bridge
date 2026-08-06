import hashlib

import pytest
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

from health_bridge.contract import delivery_v1 as delivery
from tests.contract.delivery_v1_support import (
    ACK_FIELDS,
    BATCH,
    DOMAINS,
    RETRYABLE,
    TERMINAL,
    Contexts,
    authenticated_ack_id_mismatch,
    decode_binary,
    decode_object,
    error_code,
    receipt,
    string_field,
)

pytest_plugins = ("tests.contract.delivery_v1_fixtures",)


def test_ack_has_complete_exact_field_set(contexts: Contexts) -> None:
    # Given
    _, _, ack_seal, _ = contexts
    # When
    ack = delivery.create_delivery_ack(receipt(), ack_seal)
    # Then
    assert set(decode_object(ack.to_bytes())) == ACK_FIELDS


def test_receipt_has_complete_exact_field_set() -> None:
    # Given / When
    encoded = receipt().to_bytes()
    # Then
    assert set(decode_object(encoded)) == {
        "result",
        "payload_sha256",
        "receipt_id",
        "dataset_generation",
        "committed_at_ms",
        "error_code",
    }


@pytest.mark.parametrize(
    ("result", "code"),
    [("retryable", code) for code in RETRYABLE]
    + [("terminal", code) for code in TERMINAL],
)
def test_ack_round_trips_every_closed_error_mapping(
    contexts: Contexts, result: str, code: str
) -> None:
    # Given
    _, _, ack_seal, ack_open = contexts
    ack = delivery.create_delivery_ack(receipt(result, code, None), ack_seal)
    # When
    opened = delivery.open_delivery_ack(ack.to_bytes(), ack_open)
    # Then
    assert (opened.result, opened.error_code) == (result, code)


@pytest.mark.parametrize(
    ("result", "error_code", "receipt_id"),
    [
        ("committed", "payload_invalid", 9),
        ("retryable", "unknown", None),
        ("terminal", None, None),
        ("other", None, None),
        ("committed", None, -1),
    ],
)
def test_receipt_rejects_values_outside_closed_result_domain(
    result: str, error_code: str | None, receipt_id: int | None
) -> None:
    # Given / When / Then
    with pytest.raises(delivery.DeliveryProtocolError):
        _ = delivery.DeliveryReceiptV1(
            result=result,
            payload_sha256=hashlib.sha256(BATCH).hexdigest(),
            receipt_id=receipt_id,
            dataset_generation=4 if receipt_id is not None else None,
            committed_at_ms=1_782_000_000_456 if receipt_id is not None else None,
            error_code=error_code,
        )


def test_ack_regeneration_is_byte_identical(contexts: Contexts) -> None:
    # Given
    _, _, ack_seal, _ = contexts
    committed = receipt()
    # When
    regenerated = (
        delivery.create_delivery_ack(committed, ack_seal).to_bytes(),
        delivery.create_delivery_ack(committed, ack_seal).to_bytes(),
    )
    # Then
    assert regenerated[0] == regenerated[1]


def test_ack_kdf_nonce_aad_ciphertext_and_signature_match_normative_preimages(
    contexts: Contexts,
) -> None:
    # Given
    _, _, ack_seal, _ = contexts
    committed = receipt()
    ack = delivery.create_delivery_ack(committed, ack_seal)
    raw = decode_object(ack.to_bytes())
    ack_id = bytes.fromhex(string_field(raw, "ack_id"))
    shared = X25519PrivateKey.from_private_bytes(b"\x33" * 32).exchange(
        X25519PrivateKey.from_private_bytes(b"\x44" * 32).public_key()
    )
    salt = hashlib.sha256(
        DOMAINS["ACK_SALT_DOMAIN"] + b"\0" + b"\x02" * 16 + b"\x03" * 16
    ).digest()
    key = HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=salt,
        info=DOMAINS["ACK_KEY_DOMAIN"] + b"\0" + ack_id,
    ).derive(shared)
    nonce = HKDF(
        algorithm=hashes.SHA256(),
        length=12,
        salt=salt,
        info=DOMAINS["ACK_NONCE_DOMAIN"] + b"\0" + ack_id,
    ).derive(shared)
    aad_names = tuple(ACK_FIELDS - {"nonce", "ciphertext", "signature"})
    aad = (
        DOMAINS["ACK_AAD_DOMAIN"]
        + b"\0"
        + delivery.hbjcs1_encode({name: raw[name] for name in aad_names})
    )
    # When
    expected_ciphertext = AESGCM(key).encrypt(nonce, committed.to_bytes(), aad)
    # Then
    assert (
        decode_binary(string_field(raw, "nonce")),
        decode_binary(string_field(raw, "ciphertext")),
    ) == (
        nonce,
        expected_ciphertext,
    )
    Ed25519PrivateKey.from_private_bytes(b"\x22" * 32).public_key().verify(
        decode_binary(string_field(raw, "signature")),
        DOMAINS["ACK_SIGNATURE_DOMAIN"]
        + b"\0"
        + delivery.hbjcs1_encode(
            {name: value for name, value in raw.items() if name != "signature"}
        ),
    )


@pytest.mark.parametrize(
    ("result", "code"),
    [
        ("committed", None),
        ("retryable", "receiver_busy"),
        ("terminal", "payload_invalid"),
    ],
)
def test_ack_id_is_unique_for_each_receipt_context(
    contexts: Contexts, result: str, code: str | None
) -> None:
    # Given
    _, _, ack_seal, _ = contexts
    context_receipt = receipt(result, code, 9)
    # When
    ack = delivery.create_delivery_ack(context_receipt, ack_seal)
    # Then
    assert (
        ack.ack_id
        == hashlib.sha256(
            DOMAINS["ACK_ID_DOMAIN"] + b"\0" + b"\x01" * 16 + context_receipt.to_bytes()
        )
        .digest()[:16]
        .hex()
    )


def test_committed_retryable_and_terminal_ack_ids_are_distinct(
    contexts: Contexts,
) -> None:
    # Given
    _, _, ack_seal, _ = contexts
    receipts = (
        receipt(),
        receipt("retryable", "receiver_busy", None),
        receipt("terminal", "payload_invalid", None),
    )
    # When
    ack_ids = {delivery.create_delivery_ack(item, ack_seal).ack_id for item in receipts}
    # Then
    assert len(ack_ids) == 3


@pytest.mark.parametrize("field", sorted(ACK_FIELDS))
def test_ack_rejects_each_outer_field_mutation(contexts: Contexts, field: str) -> None:
    # Given
    _, _, ack_seal, ack_open = contexts
    raw = decode_object(delivery.create_delivery_ack(receipt(), ack_seal).to_bytes())
    raw[field] = 2 if field in {"v", "connection_generation"} else "A" * 43
    # When / Then
    with pytest.raises(delivery.DeliveryProtocolError) as exc:
        _ = delivery.open_delivery_ack(delivery.hbjcs1_encode(raw), ack_open)
    assert error_code(exc) == "authentication_failed"


def test_ack_rejects_recomputed_id_mismatch(
    contexts: Contexts,
) -> None:
    _, _, ack_seal, ack_open = contexts
    encoded = authenticated_ack_id_mismatch(receipt(), ack_seal)

    with pytest.raises(delivery.DeliveryProtocolError) as exc:
        _ = delivery.open_delivery_ack(encoded, ack_open)

    assert error_code(exc) == "authentication_failed"


def test_ack_rejects_outer_bytes_over_limit(
    contexts: Contexts,
) -> None:
    # Given
    _, _, _, ack_open = contexts
    # When / Then
    with pytest.raises(delivery.DeliveryProtocolError) as exc:
        _ = delivery.open_delivery_ack(b" " * 65_537, ack_open)
    assert error_code(exc) == "authentication_failed"


def test_ack_rejects_excessive_metadata_nesting_with_closed_error(
    contexts: Contexts,
) -> None:
    _, _, _, ack_open = contexts
    encoded = b"[" * 1_200 + b"0" + b"]" * 1_200

    with pytest.raises(delivery.DeliveryProtocolError) as exc:
        _ = delivery.open_delivery_ack(encoded, ack_open)

    assert error_code(exc) == "authentication_failed"
