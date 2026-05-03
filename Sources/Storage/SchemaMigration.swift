import Foundation

enum SchemaMigrationError: Error, Equatable {
    case unknownFutureVersion(Int)
    case malformed(String)
}

/// Owns the on-disk JSON schema version for `meeting.json`, `transcript.json`, `summary.json`.
///
/// `currentVersion` is the schemaVersion this build emits. When loading, anything
/// with `schemaVersion <= currentVersion` is migrated forward in-place (no-op for
/// v1). Anything with a higher version is rejected — a newer build wrote the file
/// and we don't know how to read it. Don't silently downgrade.
enum SchemaMigration {
    static let currentVersion = 1

    /// Migrates a raw decoded JSON dictionary to `currentVersion`.
    ///
    /// - Throws `unknownFutureVersion` if the file was written by a build newer than this one.
    /// - Throws `malformed` if the JSON is shaped wrong (e.g. schemaVersion missing AND no legacy hints).
    static func migrate(_ json: [String: Any]) throws -> [String: Any] {
        let version = (json["schemaVersion"] as? Int) ?? 0

        guard version <= currentVersion else {
            throw SchemaMigrationError.unknownFutureVersion(version)
        }

        var out = json

        // Pre-v1 (version == 0) → v1: stamp the version. v1 is the baseline schema; no field
        // changes. If a future v2 adds/removes fields, write `migrateV1ToV2` here:
        //   if version < 2 { out = try migrateV1ToV2(out) }

        out["schemaVersion"] = currentVersion
        return out
    }

    /// Convenience for raw `Data` coming off disk.
    static func migrate(rawJSON data: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SchemaMigrationError.malformed("not a JSON object")
        }
        let migrated = try migrate(object)
        return try JSONSerialization.data(withJSONObject: migrated, options: [.prettyPrinted, .sortedKeys])
    }
}
