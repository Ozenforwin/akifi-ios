import XCTest
@testable import AkifiIOS

/// Codable-evolution contract for the offline queue:
///
/// 1. Disk round-trip (with `queuePersistenceKey` on the encoder) preserves
///    the client-only DTO flags — losing them across an app restart is the
///    bug that would desync auto-transfer triplets on replay.
/// 2. Legacy queue files (pre-offline-v2, no attempts/flags) still decode.
/// 3. WITHOUT the key, client-only fields never leak into network payloads.
@MainActor
final class PendingOperationCodableTests: XCTestCase {

    private func diskEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.userInfo[PersistenceManager.queuePersistenceKey] = true
        return e
    }

    private func networkEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private func diskDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func makeCrossCurrencyCreate() -> CreateTransactionInput {
        CreateTransactionInput(
            id: "tx-1",
            user_id: "u1",
            account_id: "acc-target",
            amount: 9_000,
            currency: "RUB",
            type: "expense",
            date: "2026-07-04",
            description: "Ужин",
            category_id: "cat-1",
            merchant_name: nil,
            payment_source_account_id: "acc-source",
            source_amount: 100,
            source_currency: "USD"
        )
    }

    // MARK: - Disk round-trip

    func test_diskRoundTrip_preservesClientOnlyFields() throws {
        var op = PendingOperation(operation: .create(makeCrossCurrencyCreate()))
        op.attempts = 2
        op.lastErrorDescription = "boom"

        let data = try diskEncoder().encode(op)
        let decoded = try diskDecoder().decode(PendingOperation.self, from: data)

        XCTAssertEqual(decoded.id, op.id)
        XCTAssertEqual(decoded.attempts, 2)
        XCTAssertEqual(decoded.lastErrorDescription, "boom")
        guard case .create(let input) = decoded.operation else {
            return XCTFail("operation type lost in round-trip")
        }
        XCTAssertEqual(input.id, "tx-1", "client id must survive the disk round-trip")
        XCTAssertEqual(input.source_amount, 100, "cross-currency routing fields must survive")
        XCTAssertEqual(input.source_currency, "USD")
    }

    func test_diskRoundTrip_preservesUpdateFlags() throws {
        let update = UpdateTransactionInput(
            amount: 500,
            amount_native: 500,
            useAutoTransferUpdate: true,
            replaceCurrencyFields: true,
            source_amount: 5,
            source_currency: "USD"
        )
        let op = PendingOperation(operation: .update(transactionId: "tx-1", update))

        let data = try diskEncoder().encode(op)
        let decoded = try diskDecoder().decode(PendingOperation.self, from: data)

        guard case .update(let txId, let input) = decoded.operation else {
            return XCTFail("operation type lost in round-trip")
        }
        XCTAssertEqual(txId, "tx-1")
        XCTAssertTrue(input.useAutoTransferUpdate, "RPC-routing flag must survive an app restart")
        XCTAssertTrue(input.replaceCurrencyFields, "currency-replace semantics must survive")
        XCTAssertEqual(input.source_amount, 5)
        XCTAssertEqual(input.source_currency, "USD")
    }

    // MARK: - Legacy tolerance

    func test_legacyQueueFile_withoutNewFields_stillDecodes() throws {
        // Simulate a pre-offline-v2 file: encode with today's encoder, then
        // strip the fields that didn't exist back then.
        let op = PendingOperation(operation: .create(makeCrossCurrencyCreate()))
        let data = try diskEncoder().encode(op)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "attempts")
        json.removeValue(forKey: "lastErrorDescription")
        let legacyData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try diskDecoder().decode(PendingOperation.self, from: legacyData)

        XCTAssertEqual(decoded.attempts, 0, "missing attempts defaults to 0")
        XCTAssertNil(decoded.lastErrorDescription)
    }

    // MARK: - Network payload contract

    func test_networkEncoding_omitsClientOnlyKeys() throws {
        let create = makeCrossCurrencyCreate()
        let createJSON = String(data: try networkEncoder().encode(create), encoding: .utf8)!

        XCTAssertFalse(createJSON.contains("source_amount"), "source_* must never hit the transactions INSERT")
        XCTAssertFalse(createJSON.contains("source_currency"))
        XCTAssertTrue(createJSON.contains("\"id\":\"tx-1\""), "client id IS part of the INSERT payload")

        let update = UpdateTransactionInput(
            amount: 500,
            useAutoTransferUpdate: true,
            replaceCurrencyFields: true,
            source_amount: 5,
            source_currency: "USD"
        )
        let updateJSON = String(data: try networkEncoder().encode(update), encoding: .utf8)!

        XCTAssertFalse(updateJSON.contains("use_auto_transfer_update"), "routing flags must never hit the UPDATE payload")
        XCTAssertFalse(updateJSON.contains("replace_currency_fields"))
        XCTAssertFalse(updateJSON.contains("source_amount"))
    }

    func test_networkEncoding_withoutClientId_omitsIdKey() throws {
        let create = CreateTransactionInput(
            user_id: "u1", account_id: "acc-1", amount: 100, currency: "RUB",
            type: "expense", date: "2026-07-04",
            description: nil, category_id: nil, merchant_name: nil
        )
        let json = String(data: try networkEncoder().encode(create), encoding: .utf8)!

        XCTAssertFalse(json.contains("\"id\""), "nil id must be dropped so the server generates one")
    }
}
