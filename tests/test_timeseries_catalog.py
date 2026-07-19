from health_bridge.timeseries_catalog import (
    LEGACY_TYPE_CODE_AGGREGATION_ALIASES,
    TIMESERIES_BY_TYPE_CODE,
    TIMESERIES_TYPES,
    canonical_deleted_sample_client_record_id,
    list_supported_timeseries_types,
    timeseries_aggregation_for,
)

DOCS_BASELINE_TIMESERIES_TYPE_CODES = {
    "heart_rate",
    "resting_heart_rate",
    "heart_rate_variability_sdnn",
    "heart_rate_variability_rmssd",
    "heart_rate_recovery_one_minute",
    "walking_heart_rate_average",
    "recovery_score",
    "oxygen_saturation",
    "blood_glucose",
    "blood_pressure_systolic",
    "blood_pressure_diastolic",
    "respiratory_rate",
    "sleeping_breathing_disturbances",
    "blood_alcohol_content",
    "peripheral_perfusion_index",
    "forced_vital_capacity",
    "forced_expiratory_volume_1",
    "peak_expiratory_flow_rate",
    "height",
    "weight",
    "body_fat_percentage",
    "body_mass_index",
    "lean_body_mass",
    "body_temperature",
    "skin_temperature",
    "waist_circumference",
    "body_fat_mass",
    "skeletal_muscle_mass",
    "vo2_max",
    "six_minute_walk_test_distance",
    "steps",
    "energy",
    "basal_energy",
    "stand_time",
    "exercise_time",
    "physical_effort",
    "flights_climbed",
    "average_met",
    "distance_walking_running",
    "distance_cycling",
    "distance_swimming",
    "distance_downhill_snow_sports",
    "distance_other",
    "walking_step_length",
    "walking_speed",
    "walking_double_support_percentage",
    "walking_asymmetry_percentage",
    "walking_steadiness",
    "stair_descent_speed",
    "stair_ascent_speed",
    "running_power",
    "running_speed",
    "running_vertical_oscillation",
    "running_ground_contact_time",
    "running_stride_length",
    "swimming_stroke_count",
    "underwater_depth",
    "cadence",
    "power",
    "speed",
    "workout_effort_score",
    "estimated_workout_effort_score",
    "environmental_audio_exposure",
    "headphone_audio_exposure",
    "uv_exposure",
    "inhaler_usage",
    "weather_temperature",
    "weather_humidity",
    "garmin_stress_level",
    "garmin_skin_temperature",
    "garmin_fitness_age",
    "garmin_body_battery",
    "electrodermal_activity",
    "push_count",
    "atrial_fibrillation_burden",
    "insulin_delivery",
    "number_of_times_fallen",
    "number_of_alcoholic_beverages",
    "nike_fuel",
    "hydration",
}


def test_timeseries_catalog_timeseries_catalog_matches_supported_doc_codes() -> None:
    assert set(TIMESERIES_BY_TYPE_CODE) == DOCS_BASELINE_TIMESERIES_TYPE_CODES
    assert len(TIMESERIES_TYPES) == 80


def test_timeseries_catalog_has_daily_aggregation_for_every_type() -> None:
    aggregations = {entry.aggregation for entry in TIMESERIES_TYPES}
    assert aggregations == {"sum", "min_max_average", "latest"}
    assert all(
        timeseries_aggregation_for(entry.type_code) for entry in TIMESERIES_TYPES
    )
    assert timeseries_aggregation_for("energy") == "sum"
    assert timeseries_aggregation_for("weight") == "latest"
    assert timeseries_aggregation_for("blood_pressure_systolic") == "min_max_average"
    assert timeseries_aggregation_for("electrodermal_activity") == "min_max_average"
    assert timeseries_aggregation_for("atrial_fibrillation_burden") == "min_max_average"


def test_timeseries_catalog_categories_match_receiver_contract() -> None:
    contract_categories = {
        "activity",
        "blood_respiratory",
        "body",
        "environmental",
        "fitness",
        "heart",
        "other",
        "provider_specific",
        "sleep",
        "workout",
    }
    assert {entry.category for entry in TIMESERIES_TYPES} <= contract_categories


def test_timeseries_catalog_catalog_preserves_legacy_bridge_type_aliases() -> None:
    assert {
        "active_energy",
        "body_mass",
    }.issubset(LEGACY_TYPE_CODE_AGGREGATION_ALIASES)
    assert timeseries_aggregation_for("active_energy") == "sum"
    assert timeseries_aggregation_for("body_mass") == "latest"


def test_legacy_deleted_sample_ids_rewrite_only_active_energy_prefix() -> None:
    assert (
        canonical_deleted_sample_client_record_id(
            "hk-quantity-active-energy-abc123",
        )
        == "hk-quantity-energy-abc123"
    )
    assert (
        canonical_deleted_sample_client_record_id(
            "hk-quantity-distance-active-energy-abc123",
        )
        == "hk-quantity-distance-active-energy-abc123"
    )


def test_timeseries_catalog_catalog_reports_ios_live_readability_status() -> None:
    catalog = list_supported_timeseries_types()
    by_type = {entry.type_code: entry for entry in catalog.types}

    assert catalog.schema_id == "health_bridge.supported_timeseries_catalog.v2"
    assert by_type["blood_alcohol_content"].ios_live_readable is True
    assert by_type["blood_alcohol_content"].unit == "%"
    assert by_type["peripheral_perfusion_index"].unit == "%"
    assert by_type["atrial_fibrillation_burden"].unit == "%"
    assert by_type["physical_effort"].unit == "kcal/kg/hr"
    assert by_type["electrodermal_activity"].unit == "S"
    assert by_type["insulin_delivery"].unit == "IU"
    assert by_type["environmental_audio_exposure"].unit == "dBASPL"
    assert by_type["workout_effort_score"].ios_live_readable is True
    assert by_type["workout_effort_score"].ios_background_eligible is True
    assert by_type["estimated_workout_effort_score"].ios_live_readable is True
    assert by_type["estimated_workout_effort_score"].ios_background_eligible is True
    assert by_type["energy"].ios_live_readable is True
    assert by_type["energy"].ios_background_eligible is True
    assert by_type["heart_rate"].ios_background_eligible is True
    assert (
        by_type["heart_rate_variability_rmssd"].ios_support_status == "derived_required"
    )
    assert "RMSSD" in by_type["heart_rate_variability_rmssd"].ios_support_note
    assert by_type["garmin_body_battery"].ios_support_status == "provider_specific"
    assert "Garmin" in by_type["garmin_body_battery"].ios_support_note
    assert by_type["power"].ios_support_status == "workout_context"
    assert "cycling" in by_type["power"].ios_support_note.lower()
    assert by_type["sleeping_breathing_disturbances"].ios_live_readable is True
    assert (
        by_type["sleeping_breathing_disturbances"].ios_support_status == "live_readable"
    )
    assert catalog.ios_live_readable_type_count == 65


def test_timeseries_catalog_catalog_counts_match_filtered_returned_types() -> None:
    catalog = list_supported_timeseries_types(category="body")
    by_type = {entry.type_code: entry for entry in catalog.types}

    assert catalog.total_type_count == 80
    assert catalog.ios_live_readable_type_count == 65
    assert catalog.ios_background_eligible_type_count == 65
    assert catalog.returned_type_count == 10
    assert set(by_type) == {
        "body_fat_mass",
        "body_fat_percentage",
        "body_mass_index",
        "body_temperature",
        "height",
        "lean_body_mass",
        "skeletal_muscle_mass",
        "skin_temperature",
        "waist_circumference",
        "weight",
    }
    assert catalog.returned_ios_live_readable_type_count == 8
    assert catalog.returned_ios_background_eligible_type_count == 8
    assert all("explicit opt-in" not in note for note in catalog.missing_data_notes)
    assert any("unified" in note for note in catalog.missing_data_notes)
