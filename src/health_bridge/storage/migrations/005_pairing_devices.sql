create table if not exists receiver_devices (
    receiver_device_id integer primary key,
    installation_id_hash text not null unique,
    device_label text not null,
    platform text not null,
    created_at text not null,
    last_paired_at text not null,
    revoked_at text
);

create table if not exists receiver_token_devices (
    receiver_token_id integer primary key
        references receiver_tokens(receiver_token_id) on delete cascade,
    receiver_device_id integer not null
        references receiver_devices(receiver_device_id) on delete cascade,
    paired_at text not null
);

create index if not exists idx_receiver_token_devices_device
    on receiver_token_devices(receiver_device_id);

create table if not exists pairing_invitation_redemptions (
    pairing_invitation_id text primary key
        references pairing_invitations(pairing_invitation_id) on delete cascade,
    receiver_device_id integer not null
        references receiver_devices(receiver_device_id) on delete cascade,
    receiver_token_id integer not null unique
        references receiver_tokens(receiver_token_id) on delete cascade,
    redeemed_at text not null
);
