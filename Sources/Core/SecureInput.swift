import Carbon.HIToolbox

/// Secure Event Input (password fields, the login window): the system hides
/// keystrokes from taps, and vim must stand down entirely — the flag is
/// system-wide, so it also covers apps whose fields AX cannot see.
public enum SecureInput {
    public static var isActive: Bool { IsSecureEventInputEnabled() }
}
