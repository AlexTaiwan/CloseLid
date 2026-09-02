import Foundation

struct ShellResult: Equatable {
    var status: Int32
    var stdout: String
    var stderr: String
}

protocol ShellRunning {
    /// Runs `argv[0]` with `argv[1...]` as arguments, waits for exit, captures output.
    /// Throws only if the process could not be launched.
    func run(_ argv: [String]) throws -> ShellResult
}

struct ProcessShellRunner: ShellRunning {
    func run(_ argv: [String]) throws -> ShellResult {
        precondition(!argv.isEmpty, "argv must contain an executable path")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Drain both pipes concurrently. Reading them one after the other can deadlock:
        // a child that fills the stderr pipe before closing stdout blocks on write while
        // we block reading stdout.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return ShellResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}
