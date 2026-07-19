create table if not exists receiver_tokens (
    receiver_token_id integer primary key,
    token_label text not null,
    token_prefix text not null,
    token_hash text not null unique,
    created_at text not null default (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    last_used_at text,
    revoked_at text
);

create index if not exists idx_receiver_tokens_prefix_active
    on receiver_tokens(token_prefix)
    where revoked_at is null;
