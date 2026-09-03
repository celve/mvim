import os

/// The one `os_log` subsystem every part of Norm writes under, so a single
/// predicate collects the lot:
///
///     log show --predicate 'subsystem == "com.loom.Norm"' --last 1h --info --debug
///
/// LoomCore owns only the permission plumbing's category — failures that
/// happen before any field is bound. The engine's categories live in `Diag`,
/// which can name the engine types LoomCore cannot see.
public enum Log {
    public static let subsystem = "com.loom.Norm"

    /// Tap installation and the login item: one-shot failures with a cause
    /// worth explaining, never a stream.
    public static let system = Logger(subsystem: subsystem, category: "system")
}
