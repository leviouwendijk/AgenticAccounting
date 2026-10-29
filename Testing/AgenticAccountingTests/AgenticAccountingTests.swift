import Agentic
import AgenticAccounting
import Foundation
import Testing

private enum AgenticAccountingTestingFailure: Error {
    case failed
}

@main
struct AgenticAccountingTestingMain {
    static func main() async throws {
        let reporter = PlainTextTestReporter()
        let result = await TestRunner.run(
            AgenticAccountingTestSuite.suite,
            sink: reporter
        )
        let rendered = await reporter.rendered()
        if !rendered.isEmpty {
            print(rendered)
        }
        if result.isFailure {
            throw AgenticAccountingTestingFailure.failed
        }
    }
}

enum AgenticAccountingTestSuite {
    static let suite = TestSuite(
        "agentic-accounting",
        title: "AgenticAccounting"
    ) {
        Test("financial-ratios-use-native-accounting-builder") {
            let output = try Accounting.Tools.FinancialRatios.evaluate(.init(
                assets: "1000", equity: "400", liabilities: "600",
                net_turnover: "500", cost_of_revenue: "200",
                operating_expenses: "100", net_income: "100"
            ))
            try Expect.equal(output.has_analysis, true, "Analysis exists")
            try Expect.equal(output.metrics.first(where: { $0.key == "equity_ratio" })?.value, "0.4", "Equity ratio")
            try Expect.equal(output.metrics.first(where: { $0.key == "debt_ratio" })?.value, "0.6", "Debt ratio")
            try Expect.equal(output.metrics.first(where: { $0.key == "debt_to_equity" })?.value, "1.5", "Debt/equity")
            try Expect.equal(output.metrics.first(where: { $0.key == "gross_margin" })?.value, "0.6", "Gross margin")
            try Expect.equal(output.metrics.first(where: { $0.key == "operating_margin" })?.value, "0.4", "Operating margin")
            try Expect.equal(output.metrics.first(where: { $0.key == "net_margin" })?.value, "0.2", "Net margin")
            try Expect.equal(output.unavailable.contains("current_ratio"), true, "Unavailable current ratio")
            try Expect.equal(Accounting.Tools.FinancialRatios.definition.identifier.rawValue, "financial_ratios", "Tool identifier")
        }

        Test("absent-and-zero-denominator-ratios-are-not-zero") {
            let output = try Accounting.Tools.FinancialRatios.evaluate(.init(
                assets: "0", equity: "0", liabilities: "100", net_income: "10"
            ))
            try Expect.equal(output.has_analysis, true, "Analysis exists")
            try Expect.equal(output.unavailable.contains("equity_ratio"), true, "Undefined equity ratio")
            try Expect.equal(output.unavailable.contains("debt_to_equity"), true, "Undefined debt/equity")
            try Expect.equal(output.unavailable.contains("return_on_assets"), true, "Undefined ROA")
            try Expect.equal(output.metrics.first(where: { $0.key == "equity_ratio" })?.value, nil, "Undefined ratio is not zero")
        }

        Test("next-entry-ids-uses-authorized-project") {
            let fixture = try NextEntryIDsWorkspaceFixture()
            defer { fixture.cleanup() }

            let context = try fixture.context(capabilities: [.scan, .read])
            let tool = Accounting.Tools.NextEntryIDs()
            let preflight = try await tool.preflight(.init(count: 3), in: context)
            try Expect.equal(preflight.risk, .observe, "Read-only tool risk")
            let result = try await tool.call(.init(count: 3), in: context)
            try Expect.equal(result.existingEntryCount, 2, "Two existing IDs")
            try Expect.equal(result.highestExistingID, 46, "Highest existing ID")
            try Expect.equal(result.ids, [47, 48, 49], "Contiguous next ID suggestions")
        }

        Test("next-entry-ids-does-not-bypass-workspace-denials") {
            var fixture = try NextEntryIDsWorkspaceFixture()
            defer { fixture.cleanup() }

            let tool = Accounting.Tools.NextEntryIDs()
            let scanOnly = try fixture.context(capabilities: [.scan])
            var deniedRead = false
            do {
                _ = try await tool.call(.init(count: 1), in: scanOnly)
            } catch {
                deniedRead = true
            }
            try Expect.equal(deniedRead, true, "Missing read grant must fail")

            // Preflight succeeds with root-level read/scan, but the compiler
            // must still refuse an .ec symlink targeting a file outside it.
            try fixture.installEscapingSymlink()
            let permitted = try fixture.context(capabilities: [.scan, .read])
            _ = try await tool.preflight(.init(count: 1), in: permitted)
            var rejectedEscapingLink = false
            do {
                _ = try await tool.call(.init(count: 1), in: permitted)
            } catch {
                rejectedEscapingLink = true
            }
            try Expect.equal(rejectedEscapingLink, true, "Escaping .ec symlink must be refused")
        }

        Test("used-entry-ids-reports-ranges-and-gaps") {
            let fixture = try NextEntryIDsWorkspaceFixture()
            defer { fixture.cleanup() }
            try """
            entry { id = 42 date = 2026-04-14 }
            entry { id = 43 date = 2026-04-15 }
            entry { id = 50 date = 2026-04-16 }
            """.write(
                to: fixture.root.appendingPathComponent("entries/2026/2/4/extra.ec"),
                atomically: true, encoding: .utf8
            )

            let tool = Accounting.Tools.UsedEntryIDs()
            let context = try fixture.context(capabilities: [.scan, .read])
            let preflight = try await tool.preflight(.init(), in: context)
            try Expect.equal(preflight.risk, .observe, "Read-only tool risk")
            try Expect.equal(Accounting.Tools.UsedEntryIDs.definition.identifier.rawValue,
                             "accounting_used_entry_ids", "Tool identifier")
            let output = try await tool.call(.init(), in: context)
            try Expect.equal(output.count, 5, "Unique used IDs")
            try Expect.equal(output.minimum, 41, "Minimum ID")
            try Expect.equal(output.maximum, 50, "Maximum ID")
            try Expect.equal(output.usedRanges.map { "\($0.lower)-\($0.upper)" },
                             ["41-43", "46-46", "50-50"], "Compressed used ranges")
            try Expect.equal(output.gaps.map { "\($0.lower)-\($0.upper)" },
                             ["44-45", "47-49"], "Internal gaps only")
        }

        Test("used-entry-ids-empty-ledger") {
            let fixture = try NextEntryIDsWorkspaceFixture()
            defer { fixture.cleanup() }
            try FileManager.default.removeItem(
                at: fixture.root.appendingPathComponent("entries/2026/2/4/main.ec")
            )
            let context = try fixture.context(capabilities: [.scan, .read])
            let output = try await Accounting.Tools.UsedEntryIDs().call(.init(), in: context)
            try Expect.equal(output.count, 0, "No used IDs")
            try Expect.equal(output.minimum, nil, "No minimum")
            try Expect.equal(output.maximum, nil, "No maximum")
            try Expect.equal(output.usedRanges.isEmpty, true, "No ranges")
            try Expect.equal(output.gaps.isEmpty, true, "No gaps")
        }

        Test("used-entry-ids-enforces-workspace-and-symlink-boundaries") {
            var fixture = try NextEntryIDsWorkspaceFixture()
            defer { fixture.cleanup() }
            let tool = Accounting.Tools.UsedEntryIDs()
            let scanOnly = try fixture.context(capabilities: [.scan])
            var denied = false
            do {
                _ = try await tool.call(.init(), in: scanOnly)
            } catch {
                denied = true
            }
            try Expect.equal(denied, true, "No read capability must deny scan")

            try fixture.installEscapingSymlink()
            let allowed = try fixture.context(capabilities: [.scan, .read])
            _ = try await tool.preflight(.init(), in: allowed)
            var rejectedSymlink = false
            do {
                _ = try await tool.call(.init(), in: allowed)
            } catch {
                rejectedSymlink = true
            }
            try Expect.equal(rejectedSymlink, true, "Escaping .ec symlink must be refused")
        }

        Test("missing-inputs-and-invalid-decimal-rejected") {
            let empty = try Accounting.Tools.FinancialRatios.evaluate(.init(
                assets: "0", equity: "0", liabilities: "0"
            ))
            try Expect.equal(empty.has_analysis, false, "No analysis for empty values")
            try Expect.equal(empty.metrics.isEmpty, true, "No metrics for empty values")
            try Expect.throwsError("Invalid decimal should throw") {
                _ = try Accounting.Tools.FinancialRatios.evaluate(.init(
                    assets: "not-a-decimal", equity: "400", liabilities: "600"
                ))
            }
        }
    }
}
