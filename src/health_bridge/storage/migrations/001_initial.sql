create table if not exists schema_migrations (
    migration_id text primary key,
    applied_at text not null default (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

create table if not exists sync_runs (
    sync_run_id integer primary key,
    started_at text not null,
    finished_at text not null,
    status text not null check (status in ('succeeded', 'failed')),
    schema_id text,
    schema_version text,
    fixture_name text not null,
    source_count integer not null default 0,
    health_type_count integer not null default 0,
    sample_count integer not null default 0,
    workout_count integer not null default 0,
    sleep_session_count integer not null default 0,
    deleted_record_count integer not null default 0,
    sync_cursor_count integer not null default 0,
    error_summary text
);

create table if not exists sources (
    source_id integer primary key,
    source_key text not null unique,
    name text not null,
    kind text not null,
    bundle_id text,
    device_model text,
    created_at text not null default (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at text not null default (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

create table if not exists health_types (
    type_code text primary key,
    display_name text not null,
    category text not null,
    default_unit text not null,
    sensitivity text not null,
    created_at text not null default (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at text not null default (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

create table if not exists health_type_aliases (
    alias_id integer primary key,
    type_code text not null references health_types(type_code) on delete cascade,
    alias text not null,
    unique (type_code, alias)
);

create table if not exists samples (
    sample_id integer primary key,
    source_id integer not null references sources(source_id) on delete cascade,
    type_code text not null references health_types(type_code) on delete restrict,
    client_record_id text not null,
    start_time text not null,
    end_time text not null,
    value real not null,
    unit text not null,
    metadata_json text not null,
    created_at text not null default (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at text not null default (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    unique (source_id, type_code, client_record_id)
);

create table if not exists workouts (
    workout_id integer primary key,
    source_id integer not null references sources(source_id) on delete cascade,
    client_record_id text not null,
    workout_type text not null,
    start_time text not null,
    end_time text not null,
    duration_seconds integer not null,
    energy_kcal real,
    distance_meters real,
    created_at text not null default (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at text not null default (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    unique (source_id, client_record_id)
);

create table if not exists sleep_sessions (
    sleep_session_id integer primary key,
    source_id integer not null references sources(source_id) on delete cascade,
    client_record_id text not null,
    start_time text not null,
    end_time text not null,
    created_at text not null default (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at text not null default (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    unique (source_id, client_record_id)
);

create table if not exists sleep_stage_intervals (
    sleep_stage_interval_id integer primary key,
    sleep_session_id integer not null
        references sleep_sessions(sleep_session_id) on delete cascade,
    stage text not null,
    start_time text not null,
    end_time text not null,
    unique (sleep_session_id, stage, start_time, end_time)
);

create table if not exists deleted_records (
    deleted_record_id integer primary key,
    source_id integer not null references sources(source_id) on delete cascade,
    record_family text not null,
    client_record_id text not null,
    deleted_at text not null,
    unique (source_id, record_family, client_record_id)
);

create table if not exists sync_cursors (
    sync_cursor_id integer primary key,
    source_id integer not null references sources(source_id) on delete cascade,
    cursor_kind text not null,
    cursor_value text not null,
    updated_at text not null default (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    unique (source_id, cursor_kind)
);
