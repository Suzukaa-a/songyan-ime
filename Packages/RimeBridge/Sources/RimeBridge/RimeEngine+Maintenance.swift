import Foundation
import RimeKit

extension RimeEngine {
    // MARK: - Learning snapshots

    /// Exclusive temporary-engine operation. Releases all sessions without rebuilding them.
    /// The caller must use the process-local engine coordinator, hold a cross-process
    /// transfer lease, and shut this engine down afterwards. Neither controls another
    /// process's keyboard; an external active user-dictionary lock fails closed natively.
    public func backupLearningData() throws -> [RimeLearningSnapshot] {
        try queue.sync {
            let native = try learningNativeOnQueue()
            try releaseLearningSessionsOnQueue(api: native.api)
            return try native.backupAll()
        }
    }

    /// Validates the entire batch before writes, then merges it with librime's restore.
    /// A failure after a native write is not rolled back; the caller keeps a safety backup.
    /// No input session is rebuilt; only an exclusive temporary maintenance engine may call this.
    public func restoreLearningData(_ snapshots: [RimeLearningSnapshot]) throws {
        try queue.sync {
            let native = try learningNativeOnQueue()
            let documents = try native.validate(snapshots)
            try releaseLearningSessionsOnQueue(api: native.api)
            try native.restore(snapshots, documents: documents)
        }
    }

    private func learningNativeOnQueue() throws -> RimeLearningNative {
        guard let engine, rb_engine_ready(engine) != 0,
            Self.processOwnerID.withLock({ $0 }) == ObjectIdentifier(self), let api = rime_get_api()
        else {
            throw RimeEngineError.notStarted
        }
        guard !snapshotRecoveryRequired else { throw RimeEngineError.snapshotUnavailable }
        return try RimeLearningNative(api: api, user: configuration.userDirectory)
    }

    private func releaseLearningSessionsOnQueue(api: UnsafeMutablePointer<RimeApi>) throws {
        let maintaining = try RimeLearningNative.provided(api, \.is_maintenance_mode)
        let join = try RimeLearningNative.provided(api, \.join_maintenance_thread)
        let statusRead = try RimeLearningNative.provided(api, \.get_status)
        let statusFree = try RimeLearningNative.provided(api, \.free_status)
        let destroy = try RimeLearningNative.provided(api, \.destroy_session)
        let cleanup = try RimeLearningNative.provided(api, \.cleanup_all_sessions)
        guard maintaining() == 0 else { throw RimeLearningBackupError.unsupported }
        join()
        for identifier in [session, wordSession] where identifier != 0 {
            var status = RimeStatus()
            status.data_size = Int32(MemoryLayout<RimeStatus>.size - MemoryLayout<Int32>.size)
            guard statusRead(identifier, &status) != 0 else {
                snapshotRecoveryRequired = true
                throw RimeEngineError.snapshotUnavailable
            }
            let composing = status.is_composing != 0
            guard statusFree(&status) != 0 else {
                snapshotRecoveryRequired = true
                throw RimeEngineError.snapshotUnavailable
            }
            guard !composing else { throw RimeLearningBackupError.unsupported }
        }
        if session != 0 {
            guard destroy(session) != 0 else { throw RimeLearningBackupError.unsupported }
            session = 0
        }
        destroyWordSessionOnQueue()
        cleanup()
        suspendedSession = nil
        activeSchemaID = ""
        explicitlySetOptions.removeAll()
        lastTrustedState = .empty
        invalidateDisplayContextOnQueue()
    }

    // MARK: - Maintenance / native sync

    /// Runs librime's native user-data sync (`sync_user_data`): exports this
    /// device's snapshots and merges other devices' snapshots from the sync
    /// directory, then restores a working session with the previous schema.
    /// The caller is expected to hold exclusive database access.
    public func sync() throws -> RimeState {
        try queue.sync {
            try maintainOnQueue(sync: true, fullCheck: true)
        }
    }

    /// Runs a maintenance pass (full check re-compiles changed dictionaries).
    /// Useful after importing new schemas/packages. Restores the session.
    public func redeploy(fullCheck: Bool = true) throws -> RimeState {
        try queue.sync {
            try maintainOnQueue(sync: false, fullCheck: fullCheck)
        }
    }

    /// Host-only compilation of a generated encoding adapter. Does not edit schema_list
    /// or user custom; the caller validates the resulting schema before publishing it.
    public func deploySchemaFile(_ file: URL) throws {
        try queue.sync {
            guard configuration.prebuiltDirectory == nil, let engine else {
                throw RimeEngineError.operationFailed("schema compilation requires a host deployment engine")
            }
            let previous = readCurrentSchemaIDOnQueue()
            if session != 0 { rb_session_destroy(engine, session) }
            session = 0
            destroyWordSessionOnQueue()
            let success = file.path.withCString { rime_get_api().pointee.deploy_schema($0) }
            session = rb_session_create(engine)
            guard session != 0 else {
                throw RimeEngineError.operationFailed("cannot recreate session after schema compilation")
            }
            if !previous.isEmpty { _ = previous.withCString { rb_select_schema(engine, session, $0) } }
            activeSchemaID = readCurrentSchemaIDOnQueue()
            invalidateDisplayContextOnQueue()
            // Compiling a schema rewrites the deployed config this memo describes.
            // (Host deployment mode never arms the memo, so this is belt-and-braces.)
            invalidateSchemaFactsOnQueue()
            guard success != 0 else {
                throw RimeEngineError.operationFailed("schema compilation failed: \(file.lastPathComponent)")
            }
        }
    }

    private func maintainOnQueue(sync: Bool, fullCheck: Bool) throws -> RimeState {
        guard configuration.prebuiltDirectory == nil else {
            throw RimeEngineError.operationFailed(
                "maintenance is disabled for prebuilt startup; deploy/sync in the host App")
        }
        guard let engine = engine else { throw RimeEngineError.notStarted }
        let wantedSchema = readCurrentSchemaIDOnQueue()
        let optionNames = explicitlySetOptions.union(["ascii_mode", "full_shape", "simplification", "ascii_punct"])
        let options = optionNames.map { name in
            (name, name.withCString { rb_get_option(engine, session, $0) })
        }
        // Redeploy does not clean up sessions; sync does, even on failure.
        // Release first so no stale ID or open userdb survives either path.
        if session != 0 { rb_session_destroy(engine, session) }
        session = 0
        destroyWordSessionOnQueue()
        activeSchemaID = ""
        let started =
            sync
            ? rb_sync_user_data(engine)
            : rb_start_maintenance(engine, fullCheck ? 1 : 0)
        rb_join_maintenance(engine)
        let error: (String) -> RimeEngineError = {
            sync ? .syncFailed($0) : .operationFailed($0)
        }
        session = rb_session_create(engine)
        guard session != 0 else {
            cleanupEngineOnQueue()
            throw error("cannot recreate session after maintenance; engine closed, start() may retry")
        }
        let restored =
            wantedSchema.isEmpty
            || wantedSchema.withCString {
                rb_select_schema(engine, session, $0) != 0
            }
        activeSchemaID = readCurrentSchemaIDOnQueue()
        invalidateDisplayContextOnQueue()
        // Redeploy/sync recompiles the deployed schema config; any memoized
        // component/key/dependency answer from before this point is stale.
        invalidateSchemaFactsOnQueue()
        for (name, value) in options {
            name.withCString { _ = rb_set_option(engine, session, $0, value) }
        }
        guard restored else { throw error("could not restore schema \(wantedSchema)") }
        guard rb_last_deploy_state(engine) != RimeDeployState.failure.rawValue else {
            throw error("deployment reported failure; session recreated")
        }
        // Incremental maintenance returns false normally when nothing changed.
        guard started != 0 || (!sync && !fullCheck) else {
            throw error("could not start maintenance; session recreated")
        }
        return try actionSnapshotOnQueue()
    }
}
