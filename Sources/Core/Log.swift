import os

/// The subsystem every part of mvim writes under; the engine's categories are in `Diag`.
public enum Log {
    public static let subsystem = "com.loom.mvim"

    public static let system = Logger(subsystem: subsystem, category: "system")
}
