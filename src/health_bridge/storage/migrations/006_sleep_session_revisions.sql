insert into deleted_records (
    source_id,
    record_family,
    client_record_id,
    deleted_at
)
select
    superseded.source_id,
    'sleep_session',
    superseded.client_record_id,
    (
        select preferred.end_time
        from sleep_sessions as preferred
        where preferred.source_id = superseded.source_id
          and preferred.start_time = superseded.start_time
        order by preferred.end_time desc, preferred.sleep_session_id asc
        limit 1
    )
from sleep_sessions as superseded
where exists (
    select 1
    from sleep_sessions as preferred
    where preferred.source_id = superseded.source_id
      and preferred.start_time = superseded.start_time
      and (
          preferred.end_time > superseded.end_time
          or (
              preferred.end_time = superseded.end_time
              and preferred.sleep_session_id < superseded.sleep_session_id
          )
      )
)
on conflict(source_id, record_family, client_record_id) do update set
    deleted_at = max(deleted_records.deleted_at, excluded.deleted_at);

-- Same HealthKit source and exact start time form one logical sleep session.
-- Keep the longest revision; use the oldest row id as a deterministic tie break.
delete from sleep_sessions
where exists (
    select 1
    from sleep_sessions as preferred
    where preferred.source_id = sleep_sessions.source_id
      and preferred.start_time = sleep_sessions.start_time
      and (
          preferred.end_time > sleep_sessions.end_time
          or (
              preferred.end_time = sleep_sessions.end_time
              and preferred.sleep_session_id < sleep_sessions.sleep_session_id
          )
      )
);

create unique index if not exists sleep_sessions_source_start_unique
    on sleep_sessions (source_id, start_time);
