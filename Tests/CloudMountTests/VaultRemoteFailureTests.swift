import XCTest
@testable import CloudMount

final class VaultRemoteFailureTests: XCTestCase {
    private func result(_ text: String, status: Int32 = 1) -> CommandResult {
        CommandResult(status: status, stdout: "", stderr: text, stillRunning: false)
    }
    func testNasRootWriteDenialExplainsSelectingSharedFolderWithoutLeakingResponse() {
        let response = "mkdir failed: 403 Forbidden: https://user:secret@example.invalid/private-file access_token=token"
        let message = VaultRemoteFailure.message(result(response), selectingFolder: true)
        XCTAssertTrue(message.contains("home"))
        for secret in ["secret", "example.invalid", "private-file", "token"] { XCTAssertFalse(message.contains(secret)) }
        for response in ["405 Method Not Allowed", "409 Conflict"] {
            XCTAssertNotEqual(VaultRemoteFailure.message(result(response)), VaultRemoteFailure.message(result("unknown error")))
        }
    }
    func testAuthenticationTimeoutPermissionAndCertificateHaveDifferentAdvice() {
        let messages = ["401 Unauthorized", "403 Forbidden", "404 Not Found", "423 Locked", "507 Insufficient Storage", "x509: certificate signed by unknown authority"].map {
            VaultRemoteFailure.message(result($0))
        }
        XCTAssertEqual(Set(messages).count, 6)
        XCTAssertNotEqual(VaultRemoteFailure.message(result("", status: -2)), VaultRemoteFailure.message(result("unknown")))
        XCTAssertEqual(VaultRemoteFailure.message(result("", status: -3)), L10n.string("操作已取消。"))
    }
    func testUnknownErrorsNeverExposeRawOutput() {
        let message = VaultRemoteFailure.message(result("unrecognized server response password=top-secret filename=private.txt"))
        XCTAssertFalse(message.contains("top-secret"))
        XCTAssertFalse(message.contains("private.txt"))
    }
}
