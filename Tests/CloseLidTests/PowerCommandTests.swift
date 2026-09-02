import XCTest
@testable import CloseLid

final class PowerCommandTests: XCTestCase {
    func testProbeCommands() {
        XCTAssertEqual(PowerCommand.probeSettings, ["/usr/bin/pmset", "-g"])
        XCTAssertEqual(PowerCommand.probeBattery, ["/usr/bin/pmset", "-g", "batt"])
        XCTAssertEqual(PowerCommand.probeHelper,
                       ["/usr/bin/sudo", "-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"])
    }

    func testSetSleepDisabledUsesNonInteractiveSudoWithExactArgs() {
        XCTAssertEqual(PowerCommand.setSleepDisabled(true),
                       ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "1"])
        XCTAssertEqual(PowerCommand.setSleepDisabled(false),
                       ["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "0"])
    }

    func testInstallScriptValidatesBeforeInstallingAndEmbedsRule() throws {
        let rule = try SudoersRule.render(username: "alexwang")
        let script = PowerCommand.installHelperScript(ruleText: rule)
        let lines = script.split(separator: "\n").map(String.init)

        XCTAssertEqual(lines.first, "set -eu")
        XCTAssertTrue(script.contains("<<'CLOSELID_RULE'"), "rule must be passed via a quoted heredoc so the shell never expands it")
        XCTAssertTrue(script.contains("alexwang ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"))

        let chmodIndex = lines.firstIndex { $0 == "/bin/chmod 0440 \"$TMP\"" }
        let visudoIndex = lines.firstIndex { $0.contains("/usr/sbin/visudo -c -f") }
        let installIndex = lines.firstIndex { $0.contains("/usr/bin/install -m 0440 -o root -g wheel") }
        XCTAssertNotNil(chmodIndex)
        XCTAssertNotNil(visudoIndex)
        XCTAssertNotNil(installIndex)
        XCTAssertLessThan(chmodIndex!, visudoIndex!, "visudo also checks file mode; chmod first")
        XCTAssertLessThan(visudoIndex!, installIndex!, "visudo check must run before install")
        XCTAssertTrue(lines[installIndex!].hasSuffix(" /etc/sudoers.d/closelid"))
        XCTAssertTrue(script.contains("/bin/rm -f \"$TMP\""))
    }

    func testInstallScriptDoesNotDuplicateTrailingNewlineInsideHeredoc() throws {
        let rule = try SudoersRule.render(username: "alexwang")
        let script = PowerCommand.installHelperScript(ruleText: rule)
        // The heredoc body must be the rule without its own trailing newline,
        // immediately followed by the terminator on its own line.
        XCTAssertTrue(script.contains("disablesleep 0\nCLOSELID_RULE\n"))
        XCTAssertFalse(script.contains("disablesleep 0\n\nCLOSELID_RULE"))
    }

    func testRemoveScriptRevertsSleepThenDeletesRule() {
        let lines = PowerCommand.removeHelperScript.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "set -u")
        let revert = lines.firstIndex(of: "/usr/bin/pmset -a disablesleep 0")
        let remove = lines.firstIndex(of: "/bin/rm -f /etc/sudoers.d/closelid")
        XCTAssertNotNil(revert)
        XCTAssertNotNil(remove)
        XCTAssertLessThan(revert!, remove!, "must revert sleep before removing the only silent way to do so")
    }

    func testScriptsUseAbsolutePathsOnly() throws {
        let install = PowerCommand.installHelperScript(ruleText: try SudoersRule.render(username: "u"))
        for script in [install, PowerCommand.removeHelperScript] {
            for line in script.split(separator: "\n") where !line.hasPrefix("set ") && !line.hasPrefix("#") && !line.hasPrefix("TMP=") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed != "CLOSELID_RULE", !trimmed.contains("ALL=(root)") else { continue }
                XCTAssertTrue(trimmed.hasPrefix("/"), "non-absolute command in root script: \(line)")
            }
        }
    }
}
