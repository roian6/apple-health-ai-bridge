create table daily_projection_owners (
    source_id integer not null references sources(source_id) on delete cascade,
    type_code text not null,
    namespace text not null,
    primary key (source_id, type_code)
);
create table daily_projection_records (
    source_id integer not null references sources(source_id) on delete cascade,
    type_code text not null,
    client_record_id text not null,
    kind text not null check (kind in ('raw', 'daily')),
    namespace text,
    sequence text,
    fingerprint text not null,
    start_time text not null,
    end_time text not null,
    status text not null check (status in ('current', 'last_known', 'unknown')),
    primary key (source_id, type_code, client_record_id)
);
create table daily_projection_fences (
    source_id integer not null references sources(source_id) on delete cascade,
    type_code text not null,
    fingerprint text not null,
    namespace text,
    sequence text,
    start_time text,
    end_time text,
    uncertain integer not null default 0 check (uncertain in (0, 1)),
    primary key (source_id, type_code, fingerprint)
);
create table daily_projection_replays (
    source_id integer not null references sources(source_id) on delete cascade,
    fingerprint text not null,
    primary key (source_id, fingerprint)
);
create index daily_projection_record_identity on daily_projection_records(source_id, client_record_id);
create index daily_projection_record_ranges on daily_projection_records(source_id, type_code, kind, start_time, end_time);
create index daily_projection_fence_ranges on daily_projection_fences(source_id, type_code, start_time, end_time);
