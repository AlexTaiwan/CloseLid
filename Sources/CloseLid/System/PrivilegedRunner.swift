import Foundation

enum PrivilegedError: Error, Equatable {
    case cancelled          // user dismissed the admin password dialog
    case failed(String)     // stderr from osascript / the script
}

protocol PrivilegedRunning {
    /// Runs a `/bin/sh` script as root after the system admin-password dialog.
    /// `prompt` is the sentence shown in that dialog; it must name CloseLid and say
    /// what is being changed, because the dialog is otherwise attributed to "osascript".
    func runAsRoot(script: String, prompt: String) throws
}

/// Runs the script through AppleScript's `do shell script … with administrator
/// privileges`, which shows the standard macOS authentication dialog.
///
/// The script text is inlined into the AppleScript literal rather than written to a
/// temp file. A user-owned file would be opened by root only *after* the password
/// dialog is dismissed, so any process running as the same user could rewrite it in
/// the meantime and get arbitrary root. An inlined literal is fixed at the moment the
/// argument vector is built and cannot be changed afterwards.
struct OsascriptPrivilegedRunner: PrivilegedRunning {
    let shell: ShellRunning

    init(shell: ShellRunning) { self.shell = shell }

    func runAsRoot(script: String, prompt: String) throws {
        let appleScript = "do shell script \"\(Self.escapeForAppleScript(script))\""
            + " with administrator privileges"
            + " with prompt \"\(Self.escapeForAppleScript(prompt))\""
        let result = try shell.run(["/usr/bin/osascript", "-e", appleScript])
        guard result.status == 0 else {
            if result.stderr.contains("(-128)") { throw PrivilegedError.cancelled }
            throw PrivilegedError.failed(result.stderr)
        }
    }

    /// Escapes text for an AppleScript string literal. Backslash must come first, or
    /// the backslashes introduced by the later replacements would be escaped again.
    /// `\n` and `\r` are the escapes AppleScript understands for line breaks; a raw
    /// newline inside a literal is a syntax error.
    static func escapeForAppleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
