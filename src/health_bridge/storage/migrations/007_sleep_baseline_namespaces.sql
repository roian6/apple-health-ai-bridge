create table sleep_baseline_namespaces (
    source_id integer not null references sources(source_id) on delete cascade,
    namespace text not null,
    authoritative_applied integer not null default 1 check (authoritative_applied in (0, 1)),
    first_seen_at text not null default (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    primary key (source_id, namespace)
);

insert into sleep_baseline_namespaces (
    source_id,
    namespace,
    authoritative_applied
)
select source_id, cursor_value, 1
from sync_cursors
where cursor_kind = 'anchored_sleep_baseline_reset'
on conflict(source_id, namespace) do nothing;
