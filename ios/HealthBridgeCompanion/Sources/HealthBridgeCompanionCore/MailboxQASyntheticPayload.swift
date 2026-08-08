import Foundation

public enum MailboxQASyntheticPayload {
    public static let exactBytes = Data(
        """
        {"deleted_records":[],"export_window":{"end_time":"2026-01-01T00:15:00Z","start_time":"2026-01-01T00:00:00Z"},"generated_at":"2026-01-01T00:15:00Z","health_types":[{"aliases":["HKQuantityTypeIdentifierStepCount"],"category":"activity","default_unit":"count","display_name":"Steps","sensitivity":"low","type_code":"steps"}],"samples":[{"client_record_id":"synthetic-qa-steps-0001","end_time":"2026-01-01T00:15:00Z","metadata":{"fixture":"mailbox_qa"},"source_key":"apple_health.phone","start_time":"2026-01-01T00:00:00Z","type_code":"steps","unit":"count","value":1234}],"schema_id":"health_bridge.batch.v1","schema_version":"1.0.0","sleep_sessions":[],"sources":[{"bundle_id":"dev.example.healthbridge.mailboxqa","device_model":"SyntheticPhone1,1","kind":"phone","name":"Synthetic QA Phone","source_key":"apple_health.phone"}],"sync":{"cursors":[],"sync_window":{"end_time":"2026-01-01T00:15:00Z","start_time":"2026-01-01T00:00:00Z"}},"workouts":[]}
        """.utf8
    )
}
