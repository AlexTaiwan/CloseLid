import Foundation
@testable import CloseLid

/// Scripted shell for tests. Responses are keyed by the exact argv; each key holds a
/// FIFO queue so the same command can answer differently on successive calls
/// (e.g. probe before/after a toggle). Every call is recorded.
final class MockShellRunner: ShellRunning {
    struct UnexpectedCommand: Error, Equatable { let argv: [String] }

    private var queues: [[String]: [ShellResult]] = [:]
    private(set) var calls: [[String]] = []

    func enqueue(_ argv: [String], _ result: ShellResult) {
        queues[argv, default: []].append(result)
    }

    func enqueue(_ argv: [String], status: Int32 = 0, stdout: String = "", stderr: String = "") {
        enqueue(argv, ShellResult(status: status, stdout: stdout, stderr: stderr))
    }

    func run(_ argv: [String]) throws -> ShellResult {
        calls.append(argv)
        guard var queue = queues[argv], !queue.isEmpty else { throw UnexpectedCommand(argv: argv) }
        let result = queue.removeFirst()
        queues[argv] = queue
        return result
    }
}

final class MockPrivilegedRunner: PrivilegedRunning {
    var scripts: [String] = []
    var prompts: [String] = []
    var error: PrivilegedError?
    func runAsRoot(script: String, prompt: String) throws {
        scripts.append(script)
        prompts.append(prompt)
        if let error { throw error }
    }
}

final class MockSleepAssertion: SleepAssertionHolding {
    private(set) var isHeld = false
    private(set) var acquireCount = 0
    private(set) var releaseCount = 0
    func acquire() { acquireCount += 1; isHeld = true }
    func release() { releaseCount += 1; isHeld = false }
}

final class MockLoginItem: LoginItemManaging {
    var status: LoginItemStatus = .disabled
    var error: Error?
    /// If set, `setEnabled(true)` leaves status at `.requiresApproval` instead of `.enabled`.
    var needsApproval = false
    private(set) var calls: [Bool] = []
    func setEnabled(_ on: Bool) throws {
        calls.append(on)
        if let error { throw error }
        status = on ? (needsApproval ? .requiresApproval : .enabled) : .disabled
    }
}
