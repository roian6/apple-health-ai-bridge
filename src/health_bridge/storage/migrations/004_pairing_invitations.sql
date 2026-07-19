create table if not exists pairing_invitations (
    pairing_invitation_id text primary key,
    invitation_label text not null,
    receiver_url text not null,
    invitation_secret_hash text not null unique,
    invitation_code_selector text not null unique,
    invitation_code_hash text not null,
    invitation_code_salt text not null,
    created_at text not null,
    expires_at text not null,
    redeemed_at text,
    revoked_at text,
    failed_attempt_count integer not null default 0 check (failed_attempt_count >= 0),
    max_failed_attempts integer not null default 5 check (max_failed_attempts > 0),
    last_failed_at text
);

create index if not exists idx_pairing_invitations_label_active
    on pairing_invitations(invitation_label)
    where redeemed_at is null and revoked_at is null;

create index if not exists idx_pairing_invitations_expiry_active
    on pairing_invitations(expires_at)
    where redeemed_at is null and revoked_at is null;
