import Accounting
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
        if CommandLine.arguments.contains("--accounting-compiler-stdout-probe") {
            let fixture = try NextEntryIDsWorkspaceFixture()
            defer { fixture.cleanup() }
            try fixture.installCompilableLedger()
            let context = try fixture.context(capabilities: [.scan, .read])
            let compile = Accounting.Tools.CompileEntries()
            _ = try await compile.call(.init(), in: context)
            _ = try await compile.call(.init(period: "month", anchor: "2026-04"), in: context)
            let draft = try await Accounting.Tools.ValidateEntryDraft().call(
                .init(source: NextEntryIDsWorkspaceFixture.validEntry(id: 42)),
                in: context
            )
            guard draft.valid else { throw AgenticAccountingTestingFailure.failed }
            return
        }
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

Test("synthetic-compiler-chart-has-complete-rgs-hierarchy") {
    let fixture = try NextEntryIDsWorkspaceFixture()
    defer { fixture.cleanup() }
    try fixture.installCompilableLedger()
    let chartURL = fixture.root.appendingPathComponent("config/resources/rgs/v3_8.json")
    let chart = try JSONDecoder().decode(CompiledChart.self, from: Data(contentsOf: chartURL))
    let problems = RGSIdentifierHierarchy.build(from: chart.nodes).problems
    try Expect.equal(problems.isEmpty, true, "Every level-2/3 node has exactly one code-prefix parent")
    try Expect.equal(
        chart.nodes.first(where: { $0.codes.code == "BEiv" })?.direction,
        .credit,
        "Level-2 equity anchor must retain credit orientation for financial assembly"
    )
}

Test("compile-entries-validates-synthetic-ledger") {
    let fixture = try NextEntryIDsWorkspaceFixture()
    defer { fixture.cleanup() }
    try fixture.installCompilableLedger()
    let context = try fixture.context(capabilities: [.scan, .read])
    let tool = Accounting.Tools.CompileEntries()
    let preflight = try await tool.preflight(.init(), in: context)
    try Expect.equal(preflight.risk, .observe, "Read-only risk")
    let result = try await tool.call(.init(), in: context)
    try Expect.equal(result.valid, true, "Full compilation passed")
    try Expect.equal(result.entityCount, 1, "One entity")
    try Expect.equal(result.accountCount, 11, "Eleven chart nodes with strict RGS parents")
    try Expect.equal(result.transactionCount, 0, "No transactions")
    try Expect.equal(result.entryCount, 1, "One entry")
    try Expect.equal(result.resolvedEntryCount, 1, "One resolved entry")
}

Test("compile-entries-rejects-unbalanced-ledger") {
    let fixture = try NextEntryIDsWorkspaceFixture()
    defer { fixture.cleanup() }
    try fixture.installCompilableLedger()
    try NextEntryIDsWorkspaceFixture.validEntry(id: 41, credit: "24.00").write(
        to: fixture.root.appendingPathComponent("entries/2026/2/4/main.ec"),
        atomically: true, encoding: .utf8
    )
    let context = try fixture.context(capabilities: [.scan, .read])
    var failed = false
    do { _ = try await Accounting.Tools.CompileEntries().call(.init(), in: context) }
    catch { failed = true }
    try Expect.equal(failed, true, "Unbalanced project must fail")
}

Test("compile-entries-enforces-access-and-symlinks") {
    var fixture = try NextEntryIDsWorkspaceFixture()
    defer { fixture.cleanup() }
    try fixture.installCompilableLedger()
    let tool = Accounting.Tools.CompileEntries()
    let denied = try fixture.context(capabilities: [.scan])
    var deniedRead = false
    do { _ = try await tool.call(.init(), in: denied) }
    catch { deniedRead = true }
    try Expect.equal(deniedRead, true, "Read denial must propagate")
    try fixture.installEscapingSymlink()
    let authorized = try fixture.context(capabilities: [.scan, .read])
    var deniedLink = false
    do { _ = try await tool.call(.init(), in: authorized) }
    catch { deniedLink = true }
    try Expect.equal(deniedLink, true, "Escaping .ec symlink must be refused")
}

Test("validate-entry-draft-accepts-balanced-unused-entry") {
    let fixture = try NextEntryIDsWorkspaceFixture()
    defer { fixture.cleanup() }
    try fixture.installCompilableLedger()
    let context = try fixture.context(capabilities: [.scan, .read])
    let tool = Accounting.Tools.ValidateEntryDraft()
    let input = Accounting.Tools.ValidateEntryDraft.Input(
        source: NextEntryIDsWorkspaceFixture.validEntry(id: 42)
    )
    let preflight = try await tool.preflight(input, in: context)
    try Expect.equal(preflight.risk, .observe, "Read-only risk")
    let result = try await tool.call(input, in: context)
    try Expect.equal(result.valid, true, "Valid draft accepted")
    try Expect.equal(result.parsedEntryCount, 1, "One draft entry")
    try Expect.equal(result.issues.isEmpty, true, "No issues")
}

Test("validate-entry-draft-reports-occupancy-and-duplicates") {
    let fixture = try NextEntryIDsWorkspaceFixture()
    defer { fixture.cleanup() }
    try fixture.installCompilableLedger()
    let context = try fixture.context(capabilities: [.scan, .read])
    let tool = Accounting.Tools.ValidateEntryDraft()
    let source = [
        NextEntryIDsWorkspaceFixture.validEntry(id: 41),
        NextEntryIDsWorkspaceFixture.validEntry(id: 42),
        NextEntryIDsWorkspaceFixture.validEntry(id: 42)
    ].joined(separator: "\n")
    let result = try await tool.call(.init(source: source), in: context)
    try Expect.equal(result.valid, false, "Conflicts must fail")
    try Expect.equal(result.parsedEntryCount, 3, "Three draft entries")
    try Expect.equal(result.issues.map(\.code).contains("occupied_id"), true, "Occupied ID")
    try Expect.equal(result.issues.map(\.code).contains("duplicate_id"), true, "Duplicate draft ID")
}

Test("validate-entry-draft-catches-unbalanced-and-unresolved") {
    let fixture = try NextEntryIDsWorkspaceFixture()
    defer { fixture.cleanup() }
    try fixture.installCompilableLedger()
    let context = try fixture.context(capabilities: [.scan, .read])
    let tool = Accounting.Tools.ValidateEntryDraft()
    let unbalanced = try await tool.call(.init(
        source: NextEntryIDsWorkspaceFixture.validEntry(id: 42, credit: "20.00")
    ), in: context)
    try Expect.equal(unbalanced.valid, false, "Unbalanced draft refused")
    try Expect.equal(unbalanced.issues.map(\.code), ["unbalanced"], "Balance issue")
    let unresolved = try await tool.call(.init(
        source: NextEntryIDsWorkspaceFixture.validEntry(id: 42, account: "WUnknown")
    ), in: context)
    try Expect.equal(unresolved.valid, false, "Unknown account refused")
    try Expect.equal(unresolved.issues.map(\.code), ["resolution"], "Resolution issue")
}

Test("validate-entry-draft-rejects-empty-and-malformed") {
    let fixture = try NextEntryIDsWorkspaceFixture()
    defer { fixture.cleanup() }
    try fixture.installCompilableLedger()
    let context = try fixture.context(capabilities: [.scan, .read])
    let tool = Accounting.Tools.ValidateEntryDraft()
    let empty = try await tool.call(.init(source: "  "), in: context)
    try Expect.equal(empty.valid, false, "Empty draft refused")
    let malformed = try await tool.call(
        .init(source: "entry { id = 42 date = 2026-04-12"), in: context
    )
    try Expect.equal(malformed.valid, false, "Malformed draft refused")
    try Expect.equal(malformed.issues.isEmpty, false, "Error reported")
}

Test("compiler-backed-tools-emit-no-terminal-output") {
    let process = Process()
    process.executableURL = Bundle.main.executableURL
        ?? URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--accounting-compiler-stdout-probe"]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    try Expect.equal(process.terminationStatus, 0, "Probe succeeds: \(err)")
    try Expect.equal(out, "", "Tools do not leak stdout into host")
    try Expect.equal(err, "", "Tools do not leak stderr into host")
}

Test("validate-entry-draft-enforces-access-and-symlinks") {
    var fixture = try NextEntryIDsWorkspaceFixture()
    defer { fixture.cleanup() }
    try fixture.installCompilableLedger()
    let tool = Accounting.Tools.ValidateEntryDraft()
    let input = Accounting.Tools.ValidateEntryDraft.Input(
        source: NextEntryIDsWorkspaceFixture.validEntry(id: 42)
    )
    let denied = try fixture.context(capabilities: [.scan])
    var deniedRead = false
    do { _ = try await tool.call(input, in: denied) }
    catch { deniedRead = true }
    try Expect.equal(deniedRead, true, "Read denial must propagate")
    try fixture.installEscapingSymlink()
    let authorized = try fixture.context(capabilities: [.scan, .read])
    var deniedLink = false
    do { _ = try await tool.call(input, in: authorized) }
    catch { deniedLink = true }
    try Expect.equal(deniedLink, true, "Escaping .ec symlink must be refused")
}

        Test("inspect-placeholders-is-read-only-and-bounded") {
            let fixture = try NextEntryIDsWorkspaceFixture()
            defer { fixture.cleanup() }
            try """
            entry {
                id = 41
                date = 2026-04-12
                for placeholder(service) in (WOmzNodOdh) { credit = 10.00 }
            }
            entry { id = 46 date = 2026-04-13 }
            """.write(
                to: fixture.root.appendingPathComponent("entries/2026/2/4/main.ec"),
                atomically: true, encoding: .utf8
            )
            let tool = Accounting.Tools.InspectPlaceholders()
            let context = try fixture.context(capabilities: [.scan, .read])
            let preflight = try await tool.preflight(.init(maximumFindings: 1), in: context)
            try Expect.equal(preflight.risk, .observe, "Read-only risk")
            let output = try await tool.call(.init(maximumFindings: 1), in: context)
            try Expect.equal(output.totalOccurrences, 1, "One placeholder")
            try Expect.equal(output.affectedEntryCount, 1, "One affected entry")
            try Expect.equal(output.findings[0].detection, "explicit", "Typed detection")
            try Expect.equal(output.findings[0].kind, "service", "Typed kind")
            try Expect.equal(output.truncated, false, "Exact count")
            try Expect.equal(output.findings[0].location != nil, true, "Source location")
        }

        Test("inspect-placeholders-enforces-workspace-access") {
            var fixture = try NextEntryIDsWorkspaceFixture()
            defer { fixture.cleanup() }
            let tool = Accounting.Tools.InspectPlaceholders()
            let scanOnly = try fixture.context(capabilities: [.scan])
            var denied = false
            do {
                _ = try await tool.call(.init(), in: scanOnly)
            } catch {
                denied = true
            }
            try Expect.equal(denied, true, "Missing read grant")
            try fixture.installEscapingSymlink()
            let context = try fixture.context(capabilities: [.scan, .read])
            var rejectedLink = false
            do {
                _ = try await tool.call(.init(), in: context)
            } catch {
                rejectedLink = true
            }
            try Expect.equal(rejectedLink, true, "Escaping .ec symlink denied")
        }

        Test("compile-entries-month-quarter-and-year-to-date") {
            let fixture = try NextEntryIDsWorkspaceFixture()
            defer { fixture.cleanup() }
            try fixture.installCompilableLedger()
            let mayDir = fixture.root.appendingPathComponent("entries/2026/2/5")
            try FileManager.default.createDirectory(at: mayDir, withIntermediateDirectories: true)
            let mayEntry = NextEntryIDsWorkspaceFixture.validEntry(id: 42)
                .replacingOccurrences(of: "2026-04-12", with: "2026-05-12")
            try mayEntry.write(to: mayDir.appendingPathComponent("main.ec"),
                               atomically: true, encoding: .utf8)
            let context = try fixture.context(capabilities: [.scan, .read])
            let tool = Accounting.Tools.CompileEntries()

            let full = try await tool.call(.init(), in: context)
            try Expect.equal(full.entryCount, 2, "All entries compiled")
            try Expect.equal(full.selectedEntryCount, 2, "No period selects all entries")
            try Expect.equal(full.period, nil, "No implicit period")
            try Expect.equal(full.windowFrom, nil, "No implicit window")
            try Expect.equal(full.balance.isEmpty, false, "Real balance statement returned")
            try Expect.equal(full.income.isEmpty, false, "Real income statement returned")

            let april = try await tool.call(.init(period: "month", anchor: "2026-04"), in: context)
            try Expect.equal(april.entryCount, 2, "Whole ledger count remains two")
            try Expect.equal(april.selectedEntryCount, 1, "April selects only its entry")
            try Expect.equal(april.period, "month", "Period returned")
            try Expect.equal(april.windowFrom, "2026-04-01", "Project timezone start")
            try Expect.equal(april.windowTo, "2026-04-30", "Project timezone end")
            try Expect.equal(april.balance.contains { $0.code == "BLimBanRba" }, true,
                             "Structured bank line returned")

            let may = try await tool.call(.init(period: "month", anchor: "2026-05"), in: context)
            try Expect.equal(may.selectedEntryCount, 1, "May selects only its entry")
            let quarter = try await tool.call(.init(period: "quarter", anchor: "2026Q2"), in: context)
            try Expect.equal(quarter.selectedEntryCount, 2, "Q2 contains both entries")
            try Expect.equal(quarter.windowFrom, "2026-04-01", "Quarter start")
            try Expect.equal(quarter.windowTo, "2026-06-30", "Quarter end")

            let ytd = try await tool.call(.init(period: "year", anchor: "2026-04-15", toDate: true), in: context)
            try Expect.equal(ytd.selectedEntryCount, 1, "Year-to-date excludes May")
            try Expect.equal(ytd.windowFrom, "2026-01-01", "Year-to-date starts in January")
            try Expect.equal(ytd.windowTo, "2026-04-15", "Year-to-date includes anchor day")
        }

        Test("compile-entries-rejects-invalid-period-input") {
            let fixture = try NextEntryIDsWorkspaceFixture()
            defer { fixture.cleanup() }
            try fixture.installCompilableLedger()
            let context = try fixture.context(capabilities: [.scan, .read])
            let tool = Accounting.Tools.CompileEntries()
            for input in [
                Accounting.Tools.CompileEntries.Input(period: "invalid"),
                .init(period: "custom"),
                .init(period: "lifetime"),
                .init(anchor: "2026-04"),
                .init(toDate: true),
                .init(period: "month", anchor: ""),
            ] {
                var rejected = false
                do { _ = try await tool.preflight(input, in: context) }
                catch { rejected = true }
                try Expect.equal(rejected, true, "Invalid input rejected before execution")
            }
            var badAnchor = false
            do { _ = try await tool.call(.init(period: "quarter", anchor: "not-a-quarter"), in: context) }
            catch { badAnchor = true }
            try Expect.equal(badAnchor, true, "Invalid anchor rejected")
        }

        Test("accounting-agent-capability-boundaries") {
            let inference = Accounting.Inferences.InterpretSourceRecord.definition.identifier
            let author = Accounting.Agents.EntryAuthor.capabilities
            let analyst = Accounting.Agents.Analyst.capabilities
            let reviewer = Accounting.Agents.LedgerReviewer.capabilities
            try Expect.equal(author.visible.inferences.members.contains(inference), true,
                             "Author has typed source interpretation available")
            try Expect.equal(reviewer.visible.inferences.members.contains(inference), true,
                             "Reviewer shares typed source interpretation")
            try Expect.equal(analyst.visible.tools.members.contains(
                Accounting.Tools.CompileEntries.definition.identifier), true,
                "Analyst can compile authorized periods")
            try Expect.equal(reviewer.available.tools.domains.isEmpty, true,
                             "Reviewer must not acquire whole mutable domains")
            try Expect.equal(reviewer.available.tools.members, reviewer.visible.tools.members,
                             "Reviewer visibility cannot expand beyond read-only allowlist")
            try Expect.equal(reviewer.visible.tools.members.contains(where: {
                $0.rawValue == "mutate_files"
            }), false, "Reviewer cannot mutate files")
        }

        Test("source-interpretation-contract-records-alternatives-and-evidence") {
            let output = Accounting.Inferences.InterpretSourceRecord.Output(
                proposedAccount: "BLimBanRba", proposedEntity: nil,
                vatBasis: nil, rationale: "Source is incomplete",
                unresolved: ["invoice missing"],
                alternativeAccounts: ["WOmzNodOdh"],
                supportingEvidence: ["supplied record says payment"]
            )
            try Expect.equal(output.alternativeAccounts, ["WOmzNodOdh"],
                             "Alternatives are retained without inventing postings")
            try Expect.equal(output.supportingEvidence,
                             ["supplied record says payment"], "Evidence is retained")
            try Expect.equal(output.vatBasis, nil, "VAT basis stays unknown")
            try Expect.equal(output.unresolved, ["invoice missing"], "Unknowns retained")
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
