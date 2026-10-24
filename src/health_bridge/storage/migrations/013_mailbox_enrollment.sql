alter table pairing_invitation_redemptions
    add column mailbox_enrollment_sha256 text
    check (mailbox_enrollment_sha256 is null or
        (length(mailbox_enrollment_sha256) = 64 and
         mailbox_enrollment_sha256 not glob '*[^0-9a-f]*'));

alter table pairing_invitation_redemptions add column native_request_sha256 text
    check (native_request_sha256 is null or
        (length(native_request_sha256) = 64 and native_request_sha256 not glob '*[^0-9a-f]*'));

alter table pairing_invitations add column native_cancel_sha256 text
    check (native_cancel_sha256 is null or
        (length(native_cancel_sha256) = 64 and native_cancel_sha256 not glob '*[^0-9a-f]*'));
