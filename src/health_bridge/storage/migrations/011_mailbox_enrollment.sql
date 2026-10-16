alter table pairing_invitation_redemptions
    add column mailbox_enrollment_sha256 text
    check (mailbox_enrollment_sha256 is null or
        (length(mailbox_enrollment_sha256) = 64 and
         mailbox_enrollment_sha256 not glob '*[^0-9a-f]*'));
