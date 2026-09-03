import os

/// The subsystem every part of Norm writes under; the engine's categories are in `Diag`.
public enum Log {
    public static let subsystem = "com.loom.Norm"

    public static let system = Logger(subsystem: subsystem, category: "system")
}
