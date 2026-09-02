import XCTest
@testable import CloseLid

final class ShellRunnerTests: XCTestCase {
    func testProcessRunnerCapturesStdoutAndStatus() throws {
        let result = try ProcessShellRunner().run(["/bin/echo", "hello", "world"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "hello world\n")
        XCTAssertEqual(result.stderr, "")
    }

    func testProcessRunnerCapturesStderrAndNonZeroStatus() throws {
        let result = try ProcessShellRunner().run(["/bin/sh", "-c", "echo oops 1>&2; exit 3"])
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.stderr, "oops\n")
    }

    func testProcessRunnerThrowsOnMissingExecutable() {
        XCTAssertThrowsError(try ProcessShellRunner().run(["/nonexistent/binary"]))
    }

    func testProcessRunnerDoesNotDeadlockWhenChildFillsStderrBeforeClosingStdout() throws {
        // 200 KB on stderr (well past the 64 KB pipe buffer) before anything on stdout.
        let result = try ProcessShellRunner().run(["/bin/sh", "-c", "yes e | head -c 200000 1>&2; echo done"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout, "done\n")
        XCTAssertEqual(result.stderr.count, 200000)
    }

    // The script is inlined into the AppleScript literal, never written to a file: a
    // user-owned temp file would be read by root only after the password dialog is
    // dismissed, giving any same-UID process a window to rewrite it.
    func testOsascriptRunnerInlinesTheScriptIntoTheAppleScriptLiteral() throws {
        var captured: [String]?
        let recorder = RecordingShellRunner { argv in
            captured = argv
            return ShellResult(status: 0, stdout: "", stderr: "")
        }
        let script = "set -eu\nTMP=\"$(/usr/bin/mktemp)\"\n/bin/echo back\\slash\n"
        try OsascriptPrivilegedRunner(shell: recorder)
            .runAsRoot(script: script, prompt: "CloseLid needs your password.")

        XCTAssertEqual(captured, [
            "/usr/bin/osascript",
            "-e",
            #"do shell script "set -eu\nTMP=\"$(/usr/bin/mktemp)\"\n/bin/echo back\\slash\n""#
                + #" with administrator privileges with prompt "CloseLid needs your password.""#,
        ])
    }

    func testOsascriptRunnerWritesNoTemporaryScriptFile() throws {
        let temp = FileManager.default.temporaryDirectory
        func closelidFiles() -> [String] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
            return names.filter { $0.hasPrefix("closelid-") }
        }
        let before = closelidFiles()

        let recorder = RecordingShellRunner { _ in
            XCTAssertEqual(closelidFiles(), before, "no script file may exist while osascript runs")
            return ShellResult(status: 0, stdout: "", stderr: "")
        }
        try OsascriptPrivilegedRunner(shell: recorder).runAsRoot(script: "set -eu\n/bin/echo hi\n", prompt: "p")
        XCTAssertEqual(closelidFiles(), before)
    }

    func testEscapeForAppleScriptHandlesBackslashQuoteAndLineBreaks() {
        XCTAssertEqual(OsascriptPrivilegedRunner.escapeForAppleScript("a\\b"), #"a\\b"#)
        XCTAssertEqual(OsascriptPrivilegedRunner.escapeForAppleScript("say \"hi\""), #"say \"hi\""#)
        XCTAssertEqual(OsascriptPrivilegedRunner.escapeForAppleScript("one\ntwo"), #"one\ntwo"#)
        XCTAssertEqual(OsascriptPrivilegedRunner.escapeForAppleScript("one\r\ntwo"), #"one\r\ntwo"#)
        // Backslash first: a literal \n in the input must not become a line break.
        XCTAssertEqual(OsascriptPrivilegedRunner.escapeForAppleScript(#"a\nb"#), #"a\\nb"#)
    }

    func testOsascriptRunnerEscapesQuotesBackslashesAndLineBreaksInPrompt() throws {
        var captured: [String]?
        let recorder = RecordingShellRunner { argv in
            captured = argv
            return ShellResult(status: 0, stdout: "", stderr: "")
        }
        try OsascriptPrivilegedRunner(shell: recorder)
            .runAsRoot(script: "set -eu\n", prompt: "say \"hi\" \\ bye\r\nnow")
        let argv = try XCTUnwrap(captured)
        XCTAssertTrue(argv[2].hasSuffix(#"with prompt "say \"hi\" \\ bye\r\nnow""#), argv[2])
    }

    // End-to-end through the real osascript, without `with administrator privileges`
    // so no password dialog appears. Proves an inlined multi-line script actually runs:
    // all three commands execute and the quoted heredoc is not expanded.
    func testEscapedMultiLineScriptExecutesThroughRealOsascript() throws {
        let script = """
        TMP="$(/bin/echo alpha)"
        /bin/echo "$TMP"
        /bin/cat <<'CLOSELID_RULE'
        $TMP
        CLOSELID_RULE
        /bin/echo done
        """
        let literal = "do shell script \"\(OsascriptPrivilegedRunner.escapeForAppleScript(script))\""
        let result = try ProcessShellRunner().run(["/usr/bin/osascript", "-e", literal])
        XCTAssertEqual(result.status, 0, result.stderr)
        // AppleScript's own line ending is CR, so osascript prints the multi-line result
        // with CR separators and a single trailing LF.
        XCTAssertEqual(result.stdout, "alpha\r$TMP\rdone\n")
    }

    func testOsascriptRunnerMapsUserCancelToCancelledError() {
        let recorder = RecordingShellRunner { _ in
            ShellResult(status: 1, stdout: "", stderr: "execution error: User canceled. (-128)\n")
        }
        XCTAssertThrowsError(try OsascriptPrivilegedRunner(shell: recorder).runAsRoot(script: "set -eu\n", prompt: "p")) { error in
            XCTAssertEqual(error as? PrivilegedError, .cancelled)
        }
    }

    func testOsascriptRunnerMapsOtherFailuresToFailed() {
        let recorder = RecordingShellRunner { _ in
            ShellResult(status: 1, stdout: "", stderr: "visudo: parse error\n")
        }
        XCTAssertThrowsError(try OsascriptPrivilegedRunner(shell: recorder).runAsRoot(script: "set -eu\n", prompt: "p")) { error in
            XCTAssertEqual(error as? PrivilegedError, .failed("visudo: parse error\n"))
        }
    }

    func testIOPMAssertionAcquireReleaseIsIdempotent() {
        let a = IOPMSleepAssertion()
        XCTAssertFalse(a.isHeld)
        a.acquire(); a.acquire()
        XCTAssertTrue(a.isHeld)
        a.release(); a.release()
        XCTAssertFalse(a.isHeld)
    }
}

/// Minimal closure-backed runner for tests that cannot predict argv exactly.
struct RecordingShellRunner: ShellRunning {
    let handler: ([String]) throws -> ShellResult
    func run(_ argv: [String]) throws -> ShellResult { try handler(argv) }
}
