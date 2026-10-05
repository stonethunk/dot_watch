import Foundation
import XCTest
@testable import DotCore
@testable import DotPrivateBootstrap

final class PrivateCredentialTests: XCTestCase {
    func testOnlyAccessTokenAndAccountCanBePersisted() throws {
        let input = try JSONValue.object([
            "access_token": .string("synthetic-access"), "account_id": .string("synthetic-account"),
            "refresh_token": .string("must-not-persist"), "another_secret": .string("must-not-persist")
        ]).encoded()
        let output = try JSONValue.decode(PrivateCredentialTransfer(data: input).canonicalData())
        XCTAssertEqual(output, .object(["access_token": .string("synthetic-access"), "account_id": .string("synthetic-account")]))
    }

    func testAccountReplacementRequiresSignOutButRenewalDoesNot() throws {
        let input = Data(#"{"access_token":"synthetic-new-access","account_id":"second tester-account"}"#.utf8)
        XCTAssertThrowsError(try PrivateCredentialTransfer(data: input, existingAccountID: "husband-account")) {
            XCTAssertEqual($0 as? DotError, .accountChangeRequiresSignOut)
        }
        XCTAssertEqual(try PrivateCredentialTransfer(data: input, existingAccountID: "second tester-account").credentials.accountID, "second tester-account")
    }

    func testInvalidAndOversizedTransfersFailWithoutEchoingInput() {
        for input in [Data(), Data("not-json".utf8), Data(repeating: 65, count: 64 * 1024),
                      Data(#"{"access_token":"bad token","account_id":"account"}"#.utf8),
                      Data(#"{"access_token":"synthetic","account_id":3}"#.utf8)] {
            XCTAssertThrowsError(try PrivateCredentialTransfer(data: input)) {
                XCTAssertEqual($0 as? DotError, .invalidCredentials)
            }
        }
    }
}
