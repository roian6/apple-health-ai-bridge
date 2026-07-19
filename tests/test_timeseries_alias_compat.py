from health_bridge.timeseries_catalog import (
    canonical_deleted_sample_client_record_id,
    canonical_sample_client_record_id,
    canonical_sample_type_code,
    canonical_sync_cursor_kind,
    compatible_deleted_sample_client_record_ids,
)


def test_body_mass_aliases_canonicalize_to_weight_across_record_and_cursor_keys() -> (
    None
):
    assert canonical_sample_type_code("body_mass") == "weight"
    assert (
        canonical_sample_client_record_id(
            "body_mass",
            "hk-quantity-body-mass-abc123",
        )
        == "hk-quantity-weight-abc123"
    )
    assert (
        canonical_deleted_sample_client_record_id(
            "hk-quantity-body-mass-abc123",
        )
        == "hk-quantity-weight-abc123"
    )
    assert compatible_deleted_sample_client_record_ids(
        "hk-quantity-weight-abc123",
    ) == (
        "hk-quantity-weight-abc123",
        "hk-quantity-body-mass-abc123",
    )
    assert (
        canonical_sync_cursor_kind("foreground_quantity_sync:body_mass")
        == "foreground_quantity_sync:weight"
    )
