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

/// Writes the script to a private temp file and runs it through AppleScript's
/// `do shell script … with administrator privileges`, which shows the standard
/// macOS authentication dialog. Writing to a file avoids any AppleScript string escaping.
struct OsascriptPrivilegedRunner: PrivilegedRunning {
    let shell: ShellRunning

    init(shell: ShellRunning) { self.shell = shell }

    func runAsRoot(script: String, prompt: String) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("closelid-\(UUID().uuidString).sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        defer { try? FileManager.default.removeItem(at: url) }

        // temporaryDirectory paths never contain single quotes, so this quoting is safe.
        let appleScript = "do shell script \"/bin/sh '\(url.path)'\" with administrator privileges with prompt \"\(Self.escapeForAppleScript(prompt))\""
        let result = try shell.run(["/usr/bin/osascript", "-e", appleScript])
        guard result.status == 0 else {
            if result.stderr.contains("(-128)") { throw PrivilegedError.cancelled }
            throw PrivilegedError.failed(result.stderr)
        }
    }

    /// AppleScript string literals escape only backslash and double quote.
    static func escapeForAppleScript(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
