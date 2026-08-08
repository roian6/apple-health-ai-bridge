create table delivery_receipts (
    delivery_receipt_row_id integer primary key,
    receipt_id check (
        receipt_id is null
        or (
            typeof(receipt_id) = 'integer'
            and receipt_id between 0 and 9223372036854775807
        )
    ),
    envelope_id blob not null
        check (typeof(envelope_id) = 'blob' and length(envelope_id) = 16),
    payload_sha256 blob not null
        check (typeof(payload_sha256) = 'blob' and length(payload_sha256) = 32),
    receiver_id blob not null
        check (typeof(receiver_id) = 'blob' and length(receiver_id) = 16),
    device_id blob not null
        check (typeof(device_id) = 'blob' and length(device_id) = 16),
    receiver_agreement_key_id blob not null
        check (
            typeof(receiver_agreement_key_id) = 'blob'
            and length(receiver_agreement_key_id) = 16
        ),
    sender_signing_key_id blob not null
        check (
            typeof(sender_signing_key_id) = 'blob'
            and length(sender_signing_key_id) = 16
        ),
    device_agreement_key_id blob not null
        check (
            typeof(device_agreement_key_id) = 'blob'
            and length(device_agreement_key_id) = 16
        ),
    receiver_signing_key_id blob not null
        check (
            typeof(receiver_signing_key_id) = 'blob'
            and length(receiver_signing_key_id) = 16
        ),
    opaque_binding blob not null
        check (typeof(opaque_binding) = 'blob' and length(opaque_binding) = 32),
    connection_generation not null check (
        typeof(connection_generation) = 'integer'
        and connection_generation between 0 and 9223372036854775807
    ),
    result text not null check (result in ('committed', 'retryable', 'terminal')),
    committed_sync_run_id references sync_runs(sync_run_id) check (
        committed_sync_run_id is null
        or (
            typeof(committed_sync_run_id) = 'integer'
            and committed_sync_run_id between 1 and 9223372036854775807
        )
    ),
    ack_id blob not null
        check (typeof(ack_id) = 'blob' and length(ack_id) = 16),
    dataset_generation check (
        dataset_generation is null
        or (
            typeof(dataset_generation) = 'integer'
            and dataset_generation between 0 and 9223372036854775807
        )
    ),
    committed_at_ms check (
        committed_at_ms is null
        or (
            typeof(committed_at_ms) = 'integer'
            and committed_at_ms between 0 and 9223372036854775807
        )
    ),
    error_code text check (
        error_code in (
            'receiver_busy',
            'storage_unavailable',
            'quota_exceeded',
            'internal_retry',
            'payload_invalid',
            'payload_oversize',
            'duplicate_conflict',
            'principal_mismatch',
            'binding_mismatch',
            'generation_mismatch',
            'key_revoked'
        )
    ),
    check (
        (
            result = 'committed'
            and receipt_id is not null
            and dataset_generation is not null
            and committed_at_ms is not null
            and committed_sync_run_id is not null
            and error_code is null
        )
        or (
            result = 'retryable'
            and receipt_id is null
            and dataset_generation is null
            and committed_at_ms is null
            and committed_sync_run_id is null
            and error_code in (
                'receiver_busy',
                'storage_unavailable',
                'quota_exceeded',
                'internal_retry'
            )
        )
        or (
            result = 'terminal'
            and receipt_id is null
            and dataset_generation is null
            and committed_at_ms is null
            and committed_sync_run_id is null
            and error_code in (
                'payload_invalid',
                'payload_oversize',
                'duplicate_conflict',
                'principal_mismatch',
                'binding_mismatch',
                'generation_mismatch',
                'key_revoked'
            )
        )
    ),
    unique (receiver_id, device_id, envelope_id),
    unique (receipt_id),
    unique (ack_id)
);
