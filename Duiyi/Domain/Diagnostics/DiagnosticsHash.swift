import Foundation

enum DiagnosticsHash {
    /// FNV-1a 64-bit hex. Used only to correlate repeated diagnostic jobs with
    /// the same source text; it is not a secret and is never user-facing.
    static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
