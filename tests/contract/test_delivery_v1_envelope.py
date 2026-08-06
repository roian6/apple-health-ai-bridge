import hashlib
from dataclasses import replace

import pytest
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

from health_bridge.contract import delivery_v1 as delivery
from health_bridge.contract._delivery_envelope import seal_delivery_envelope_vector
from health_bridge.contract._delivery_models import DeliverySealParams
from tests.contract.delivery_v1_support import (
    BATCH,
    DOMAINS,
    ENVELOPE_FIELDS,
    Contexts,
    decode_binary,
    decode_object,
    error_code,
    string_field,
)

pytest_plugins = ("tests.contract.delivery_v1_fixtures",)


def test_delivery_envelope_has_complete_exact_field_set(
    contexts: Contexts,
) -> None:
    # Given
    seal, _, _, _ = contexts
    # When
    envelope = delivery.create_delivery_envelope(BATCH, seal)
    # Then
    assert set(decode_object(envelope.to_bytes())) == ENVELOPE_FIELDS


def test_delivery_digest_binds_exact_caller_bytes_without_reserialization(
    contexts: Contexts,
) -> None:
    # Given
    seal, _, _, _ = contexts
    alternate = BATCH.replace(b'"value":1.25', b'"value":1.2500')
    # When
    envelope = delivery.create_delivery_envelope(alternate, seal)
    # Then
    assert envelope.payload_sha256 == hashlib.sha256(alternate).hexdigest()


def test_production_constructor_never_reuses_delivery_key_nonce_context(
    contexts: Contexts,
) -> None:
    # Given
    seal, opening, _, _ = contexts
    alternate = BATCH.replace(b'"value":1.25', b'"value":1.2500')
    # When
    first = delivery.create_delivery_envelope(BATCH, seal)
    second = delivery.create_delivery_envelope(alternate, seal)
    # Then
    assert first.ephemeral_public_key != second.ephemeral_public_key
    assert first.nonce != second.nonce
    assert first.to_bytes() != second.to_bytes()
    assert delivery.open_delivery_envelope(first.to_bytes(), opening).plaintext == BATCH
    assert (
        delivery.open_delivery_envelope(second.to_bytes(), opening).plaintext
        == alternate
    )


@pytest.mark.parametrize("created_at_ms", [-(2**63), -1, 2**63 - 1])
def test_delivery_created_at_accepts_full_signed_64_bit_domain(
    contexts: Contexts, created_at_ms: int
) -> None:
    # Given
    seal, opening, _, _ = contexts
    timestamped = replace(seal, created_at_ms=created_at_ms)
    # When
    envelope = delivery.create_delivery_envelope(BATCH, timestamped)
    opened = delivery.open_delivery_envelope(envelope.to_bytes(), opening)
    # Then
    assert envelope.created_at_ms == created_at_ms
    assert opened.plaintext == BATCH


@pytest.mark.parametrize("created_at_ms", [-(2**63) - 1, 2**63])
def test_delivery_created_at_rejects_values_outside_signed_64_bit_domain(
    contexts: Contexts, created_at_ms: int
) -> None:
    # Given
    seal, _, _, _ = contexts
    timestamped = replace(seal, created_at_ms=created_at_ms)
    # When / Then
    with pytest.raises(delivery.DeliveryProtocolError) as exc:
        _ = delivery.create_delivery_envelope(BATCH, timestamped)
    assert error_code(exc) == "authentication_failed"


def test_delivery_kdf_aad_ciphertext_and_signature_match_normative_preimages(
    vector_seal: DeliverySealParams,
) -> None:
    # Given
    envelope = seal_delivery_envelope_vector(BATCH, vector_seal)
    raw = decode_object(envelope.to_bytes())
    salt = hashlib.sha256(
        DOMAINS["DELIVERY_SALT_DOMAIN"] + b"\0" + b"\x02" * 16 + b"\x03" * 16
    ).digest()
    shared = X25519PrivateKey.from_private_bytes(b"\x55" * 32).exchange(
        X25519PrivateKey.from_private_bytes(b"\x33" * 32).public_key()
    )
    key = HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=salt,
        info=DOMAINS["DELIVERY_KEY_DOMAIN"] + b"\0" + b"\x01" * 16,
    ).derive(shared)
    aad_names = tuple(ENVELOPE_FIELDS - {"ciphertext", "signature"})
    aad = (
        DOMAINS["DELIVERY_AAD_DOMAIN"]
        + b"\0"
        + delivery.hbjcs1_encode({name: raw[name] for name in aad_names})
    )
    signature_fields = {
        name: value for name, value in raw.items() if name != "signature"
    }
    # When
    expected_ciphertext = AESGCM(key).encrypt(b"\x66" * 12, BATCH, aad)
    # Then
    assert decode_binary(string_field(raw, "ciphertext")) == expected_ciphertext
    Ed25519PrivateKey.from_private_bytes(b"\x11" * 32).public_key().verify(
        decode_binary(string_field(raw, "signature")),
        DOMAINS["DELIVERY_SIGNATURE_DOMAIN"]
        + b"\0"
        + delivery.hbjcs1_encode(signature_fields),
    )


def test_envelope_rejects_wrong_version_before_directional_open(
    contexts: Contexts,
) -> None:
    # Given
    seal, opening, _, _ = contexts
    raw = decode_object(delivery.create_delivery_envelope(BATCH, seal).to_bytes())
    raw["v"] = 2
    # When / Then
    with pytest.raises(delivery.DeliveryProtocolError) as exc:
        _ = delivery.open_delivery_envelope(delivery.hbjcs1_encode(raw), opening)
    assert error_code(exc) == "authentication_failed"


def test_envelope_rejects_outer_bytes_over_limit(
    contexts: Contexts,
) -> None:
    # Given
    _, opening, _, _ = contexts
    # When / Then
    with pytest.raises(delivery.DeliveryProtocolError) as exc:
        _ = delivery.open_delivery_envelope(b" " * 2_097_153, opening)
    assert error_code(exc) == "authentication_failed"


def test_envelope_rejects_excessive_metadata_nesting_with_closed_error(
    contexts: Contexts,
) -> None:
    _, opening, _, _ = contexts
    encoded = b"[" * 1_200 + b"0" + b"]" * 1_200

    with pytest.raises(delivery.DeliveryProtocolError) as exc:
        _ = delivery.open_delivery_envelope(encoded, opening)

    assert error_code(exc) == "authentication_failed"


@pytest.mark.parametrize("field", sorted(ENVELOPE_FIELDS - {"v"}))
def test_envelope_rejects_each_outer_field_mutation(
    contexts: Contexts, field: str
) -> None:
    # Given
    seal, opening, _, _ = contexts
    raw = decode_object(delivery.create_delivery_envelope(BATCH, seal).to_bytes())
    raw[field] = 8 if field in {"connection_generation", "created_at_ms"} else "A" * 43
    # When / Then
    with pytest.raises(delivery.DeliveryProtocolError) as exc:
        _ = delivery.open_delivery_envelope(delivery.hbjcs1_encode(raw), opening)
    assert error_code(exc) == "authentication_failed"


def test_delivery_nonce_is_authenticated_against_serialized_mutation(
    contexts: Contexts,
) -> None:
    # Given
    seal, opening, _, _ = contexts
    raw = decode_object(delivery.create_delivery_envelope(BATCH, seal).to_bytes())
    raw["nonce"] = "d3JvbmctZGlyZWN0"
    # When / Then
    with pytest.raises(delivery.DeliveryProtocolError) as exc:
        _ = delivery.open_delivery_envelope(delivery.hbjcs1_encode(raw), opening)
    assert error_code(exc) == "authentication_failed"
