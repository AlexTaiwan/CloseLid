import XCTest
@testable import CloseLid

final class SudoersRuleTests: XCTestCase {
    func testRendersExactRuleForUser() throws {
        let expected = """
        # Installed by CloseLid.app - allows toggling lid-close sleep without a password
        alexwang ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0

        """
        XCTAssertEqual(try SudoersRule.render(username: "alexwang"), expected)
    }

    func testRuleEndsWithSingleNewline() throws {
        let text = try SudoersRule.render(username: "bob")
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertFalse(text.hasSuffix("\n\n"))
    }

    func testRuleNeverUsesAdminGroup() throws {
        XCTAssertFalse(try SudoersRule.render(username: "bob").contains("%admin"))
    }

    func testAcceptsTypicalMacUsernames() throws {
        for name in ["alexwang", "alex.wang", "alex-wang", "_svc", "Alex99"] {
            XCTAssertNoThrow(try SudoersRule.render(username: name), name)
        }
    }

    func testRejectsDangerousUsernames() {
        for name in ["", "alex wang", "alex\nALL=(ALL) NOPASSWD: ALL", "alex\n", "alex\r\n", "alex\u{2028}", "alex,root", "9alex", "alex/", "a\tb", "ALL"] {
            XCTAssertThrowsError(try SudoersRule.render(username: name), name) { error in
                XCTAssertEqual(error as? SudoersRule.Error, .invalidUsername(name))
            }
        }
    }

    func testPathConstant() {
        XCTAssertEqual(SudoersRule.path, "/etc/sudoers.d/closelid")
    }
}
