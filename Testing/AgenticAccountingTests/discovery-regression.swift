import Accounting
import Agentic
import AgenticAccounting
import Foundation
import Testing

enum AccountingDiscoveryRegression {
    static func run() async throws {
        let fixture = try NextEntryIDsWorkspaceFixture()
        defer { fixture.cleanup() }
        try fixture.installCompilableLedger()
        let context = try fixture.context(capabilities: [.read, .scan])

        let selection = Accounting.Tools.Discovery.IDs(
            values: [41, 999],
            from: 42,
            to: 43
        )
        let read = try await Accounting.Tools.ReadEntries().call(
            .init(ids: selection),
            in: context
        )
        try Expect.equal(
            read.records.map(\.id),
            [41],
            "Existing entries survive missing IDs"
        )
        try Expect.equal(
            read.missingIDs,
            [999, 42, 43],
            "All missing IDs reported in requested order"
        )
        try Expect.equal(
            read.records.first?.postingAmounts,
            ["25", "25"],
            "Exact decimal posting amounts retained"
        )

        let searched = try await Accounting.Tools.SearchEntries().call(
            .init(
                ids: .init(from: 40, to: 43),
                accounts: ["BLimBanRba"],
                page: .init(limit: 10)
            ),
            in: context
        )
        try Expect.equal(
            searched.hits.map(\.id),
            [41],
            "Composed account and ID-range filters"
        )
        try Expect.equal(
            searched.matchedCount,
            1,
            "Matched cardinality reflects complete filtered result"
        )

        let missingTransaction = try await Accounting.Tools.ReadTransactions().call(
            .init(ids: .init(values: [100, 101])),
            in: context
        )
        try Expect.equal(missingTransaction.records.count, 0, "No invented transactions")
        try Expect.equal(missingTransaction.missingIDs, [100, 101], "Missing transaction IDs")

        let accounts = try await Accounting.Tools.SearchAccounts().call(
            .init(
                references: ["BLimBanRba"],
                page: .init(limit: 5)
            ),
            in: context
        )
        try Expect.equal(accounts.hits.map(\.code), ["BLimBanRba"], "Exact chart lookup")

        let readAccounts = try await Accounting.Tools.ReadAccounts().call(
            .init(ids: .init(values: [1, 999])),
            in: context
        )
        try Expect.equal(readAccounts.records.map(\.id), [1], "Existing chart account")
        try Expect.equal(readAccounts.missingIDs, [999], "Missing chart account")

        let entities = try await Accounting.Tools.SearchEntities().call(
            .init(text: "compiler_fixture"),
            in: context
        )
        try Expect.equal(entities.matchedCount > 0, true, "Entity text search")

        let readEntities = try await Accounting.Tools.ReadEntities().call(
            .init(references: ["does_not_exist"]),
            in: context
        )
        try Expect.equal(
            readEntities.missingReferences,
            ["does_not_exist"],
            "Missing entity reference is explicit"
        )

        let denied = try fixture.context(capabilities: [.scan])
        var rejected = false
        do {
            _ = try await Accounting.Tools.ReadEntries().call(
                .init(ids: .init(values: [41])),
                in: denied
            )
        } catch {
            rejected = true
        }
        try Expect.equal(rejected, true, "Read grant remains mandatory")
    }
}
