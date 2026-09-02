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

    func testOsascriptRunnerWritesScriptFileAndInvokesOsascriptWithAdminPrivileges() throws {
        var captured: [String]?
        // We cannot enqueue by exact argv because the temp path is random, so use a
        // permissive runner that records what it was asked to do.
        let recorder = RecordingShellRunner { argv in
            captured = argv
            return ShellResult(status: 0, stdout: "", stderr: "")
        }
        try OsascriptPrivilegedRunner(shell: recorder).runAsRoot(script: "set -eu\n/bin/echo hi\n", prompt: "CloseLid needs your password.")

        let argv = try XCTUnwrap(captured)
        XCTAssertEqual(argv[0], "/usr/bin/osascript")
        XCTAssertEqual(argv[1], "-e")
        XCTAssertTrue(argv[2].hasPrefix("do shell script \"/bin/sh '"))
        XCTAssertTrue(argv[2].hasSuffix("'\" with administrator privileges with prompt \"CloseLid needs your password.\""))
    }

    func testOsascriptRunnerEscapesQuotesAndBackslashesInPrompt() throws {
        var captured: [String]?
        let recorder = RecordingShellRunner { argv in
            captured = argv
            return ShellResult(status: 0, stdout: "", stderr: "")
        }
        try OsascriptPrivilegedRunner(shell: recorder).runAsRoot(script: "set -eu\n", prompt: #"say "hi" \ bye"#)
        let argv = try XCTUnwrap(captured)
        XCTAssertTrue(argv[2].hasSuffix(#"with prompt "say \"hi\" \\ bye""#))
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

    func testOsascriptRunnerRemovesTempScriptAfterwards() throws {
        var scriptPath: String?
        let recorder = RecordingShellRunner { argv in
            // extract path between /bin/sh ' and '
            let s = argv[2]
            let start = s.range(of: "/bin/sh '")!.upperBound
            let end = s.range(of: "'\" with")!.lowerBound
            scriptPath = String(s[start..<end])
            XCTAssertTrue(FileManager.default.fileExists(atPath: scriptPath!), "script must exist while osascript runs")
            return ShellResult(status: 0, stdout: "", stderr: "")
        }
        try OsascriptPrivilegedRunner(shell: recorder).runAsRoot(script: "set -eu\n", prompt: "p")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(scriptPath)))
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
