# Supported Apple Health data

Health Bridge for AI requests **read-only** access to every runtime-available supported type in the list below. The same unified type set drives permission requests, foreground sync, observer registration, and background refresh. Apple Health's system permission sheet still lets the user allow or deny each type individually, and only allowed records can sync. The app does not request HealthKit write access.

The app uses permitted records only to prepare sync batches for the receiver URL configured by the user, show sync status, and retry pending user-directed transfers. It does not use these records for advertising, tracking, data brokerage, or clinical decisions.

This list is the complete requested scope and the public disclosure source for App Store Connect privacy answers and App Review notes. A Swift test compares it with the app's unified authorization policy so a newly supported type cannot be added silently or omitted from sync coverage.

## Requested read types

- `atrial_fibrillation_burden` — Atrial Fibrillation Burden
- `basal_energy` — Basal Energy
- `blood_alcohol_content` — Blood Alcohol Content
- `blood_glucose` — Blood Glucose
- `blood_pressure_diastolic` — Blood Pressure Diastolic
- `blood_pressure_systolic` — Blood Pressure Systolic
- `body_fat_percentage` — Body Fat Percentage
- `body_mass_index` — Body Mass Index
- `body_temperature` — Body Temperature
- `distance_cycling` — Cycling Distance
- `distance_downhill_snow_sports` — Downhill Snow Sports Distance
- `distance_swimming` — Swimming Distance
- `distance_walking_running` — Walking + Running Distance
- `electrodermal_activity` — Electrodermal Activity
- `energy` — Active Energy
- `environmental_audio_exposure` — Environmental Audio Exposure
- `estimated_workout_effort_score` — Estimated Workout Effort Score
- `exercise_time` — Exercise Time
- `flights_climbed` — Flights Climbed
- `forced_expiratory_volume_1` — Forced Expiratory Volume 1
- `forced_vital_capacity` — Forced Vital Capacity
- `headphone_audio_exposure` — Headphone Audio Exposure
- `heart_rate` — Heart Rate
- `heart_rate_recovery_one_minute` — Heart Rate Recovery One Minute
- `heart_rate_variability_sdnn` — Heart Rate Variability SDNN
- `height` — Height
- `hydration` — Hydration
- `inhaler_usage` — Inhaler Usage
- `insulin_delivery` — Insulin Delivery
- `lean_body_mass` — Lean Body Mass
- `nike_fuel` — Nike Fuel
- `number_of_alcoholic_beverages` — Number of Alcoholic Beverages
- `number_of_times_fallen` — Number of Times Fallen
- `oxygen_saturation` — Oxygen Saturation
- `peak_expiratory_flow_rate` — Peak Expiratory Flow Rate
- `peripheral_perfusion_index` — Peripheral Perfusion Index
- `physical_effort` — Physical Effort
- `push_count` — Push Count
- `respiratory_rate` — Respiratory Rate
- `resting_heart_rate` — Resting Heart Rate
- `running_ground_contact_time` — Running Ground Contact Time
- `running_power` — Running Power
- `running_speed` — Running Speed
- `running_stride_length` — Running Stride Length
- `running_vertical_oscillation` — Running Vertical Oscillation
- `six_minute_walk_test_distance` — Six Minute Walk Test Distance
- `skin_temperature` — Wrist Temperature
- `sleep_analysis` — Sleep Analysis
- `sleeping_breathing_disturbances` — Sleeping Breathing Disturbances
- `stair_ascent_speed` — Stair Ascent Speed
- `stair_descent_speed` — Stair Descent Speed
- `stand_time` — Stand Time
- `steps` — Steps
- `swimming_stroke_count` — Swimming Stroke Count
- `underwater_depth` — Underwater Depth
- `uv_exposure` — UV Exposure
- `vo2_max` — VO2 Max
- `waist_circumference` — Waist Circumference
- `walking_asymmetry_percentage` — Walking Asymmetry Percentage
- `walking_double_support_percentage` — Walking Double Support Percentage
- `walking_heart_rate_average` — Walking Heart Rate Average
- `walking_speed` — Walking Speed
- `walking_steadiness` — Walking Steadiness
- `walking_step_length` — Walking Step Length
- `weight` — Weight
- `workout` — Workout
- `workout_effort_score` — Workout Effort Score

Runtime availability varies by iPhone model, paired devices, region, and iOS version. A type appearing here does not mean the user has granted it or that a record exists. Revoking access in Apple Health prevents future reads of that type; it does not delete records already sent to the user's receiver.

Sleep correction, deletion, reset-epoch, and crash-recovery behavior is documented in [Architecture and trust boundaries](architecture.md#sleep-corrections).
