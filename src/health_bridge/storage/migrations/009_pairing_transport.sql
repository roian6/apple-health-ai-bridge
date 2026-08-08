alter table pairing_invitations
    add column transport text not null default 'direct'
    check (transport in ('direct', 'mailbox'));
