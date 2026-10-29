import Accounting
import AccountingCompiler
import Agentic
import Foundation
import Macros
import Schema

public extension Accounting.Tools {
    @Tool("accounting_compile_entries")
    struct CompileEntries: Tool {
        @JSONSchema
        public struct Input: HashableSource {
            /// Nil compiles the complete ledger; otherwise selects a reporting period.
            public let period: String?
            public let anchor: String?
            public let toDate: Bool

            public init(period: String? = nil, anchor: String? = nil, toDate: Bool = false) {
                self.period = period
                self.anchor = anchor
                self.toDate = toDate
            }
        }

        @JSONSchema
        public struct StatementRow: HashableResult {
            public let id: Int
            public let code: String?
            public let label: String
            public let amount: String
            public let level: Int

            public init(id: Int, code: String?, label: String, amount: String, level: Int) {
                self.id = id
                self.code = code
                self.label = label
                self.amount = amount
                self.level = level
            }
        }

        @JSONSchema
        public struct Output: HashableResult {
            public let valid: Bool
            public let entityCount: Int
            public let accountCount: Int
            public let transactionCount: Int
            /// Whole project, regardless of the reporting period.
            public let entryCount: Int
            public let resolvedEntryCount: Int
            /// Entries inside the requested reporting window (or all for nil period).
            public let selectedEntryCount: Int
            public let period: String?
            public let anchor: String?
            public let windowFrom: String?
            public let windowTo: String?
            public let balance: [StatementRow]
            public let income: [StatementRow]

            public init(
                valid: Bool, entityCount: Int, accountCount: Int, transactionCount: Int,
                entryCount: Int, resolvedEntryCount: Int, selectedEntryCount: Int,
                period: String?, anchor: String?, windowFrom: String?, windowTo: String?,
                balance: [StatementRow], income: [StatementRow]
            ) {
                self.valid = valid
                self.entityCount = entityCount
                self.accountCount = accountCount
                self.transactionCount = transactionCount
                self.entryCount = entryCount
                self.resolvedEntryCount = resolvedEntryCount
                self.selectedEntryCount = selectedEntryCount
                self.period = period
                self.anchor = anchor
                self.windowFrom = windowFrom
                self.windowTo = windowTo
                self.balance = balance
                self.income = income
            }
        }

        public enum Failure: Error {
            case invalidPeriod(String)
            case periodRequiredForAnchor
            case periodRequiredForToDate
            case emptyAnchor
            case unsupportedPeriod(String)
        }

        public static let purpose = """
        Compile accounting entries and return balance-sheet and income-statement
        rows. Optionally select a year, half, quarter, month or ISO week using a
        period anchor, with optional to-date truncation. No period compiles the
        complete ledger. All filesystem reads remain workspace-authorized.
        The total entry count is whole-ledger; selectedEntryCount is period-scoped.
        Read-only; compiler or assembly failures are errors.
        """
        public static let risk: ActionRisk = .observe
        public init() {}

        private static func periodKind(for input: Input) throws -> PeriodKind? {
            guard let raw = input.period else {
                if input.anchor != nil { throw Failure.periodRequiredForAnchor }
                if input.toDate { throw Failure.periodRequiredForToDate }
                return nil
            }
            guard let kind = PeriodKind(rawValue: raw) else {
                throw Failure.invalidPeriod(raw)
            }
            switch kind {
            case .year, .half, .quarter, .month, .week:
                break
            case .custom, .lifetime:
                throw Failure.unsupportedPeriod(raw)
            }
            if let anchor = input.anchor,
               anchor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw Failure.emptyAnchor
            }
            return kind
        }

        private static func day(_ date: Date?, timeZone: TimeZone) -> String? {
            guard let date else { return nil }
            let formatter = DateFormatter()
            formatter.calendar = periodCalendar(timeZone: timeZone)
            formatter.timeZone = timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }

        private static func rows(_ lines: [StatementLine], chart: CompiledChart) -> [StatementRow] {
            let codes = Dictionary(uniqueKeysWithValues: chart.nodes.map { ($0.id, $0.codes.code) })
            return lines.map { line in
                .init(
                    id: line.id,
                    code: codes[line.id],
                    label: line.label,
                    amount: NSDecimalNumber(decimal: line.amount).stringValue,
                    level: line.level
                )
            }
        }

        public func preflight(_ input: Input, in context: ToolContext) async throws -> ToolPreflight {
            let kind = try Self.periodKind(for: input)
            let workspace = try AccountingCompileAccess.authorize(
                context, toolName: Self.identifier.rawValue
            )
            return .init(
                tool: Self.definition.identifier,
                risk: Self.definition.risk,
                summary: kind.map { "Compile accounting entries for \($0.rawValue)" }
                    ?? "Compile complete accounting ledger",
                access: .init(
                    targets: ["config", "entries", "transactions", "config/settings.ec"],
                    roots: [workspace.rootIdentifier.rawValue],
                    capabilities: [.scan, .read]
                ),
                sideEffects: []
            )
        }

        public func call(_ input: Input, in context: ToolContext) async throws -> Output {
            let kind = try Self.periodKind(for: input)
            let workspace = try AccountingCompileAccess.authorize(
                context, toolName: Self.identifier.rawValue
            )
            let project = EntryCompilerProject(workspace: workspace)
            let result = try await EntryCompileDriver.compile(
                project: project,
                setting: CompileDriveSetting(loc_trace: false),
                verbose: false
            )
            let cut = AssembleCut(
                target: .L3,
                includeCodes: [],
                includeIntermediates: true,
                omitZerosBeyondLevel1: true
            )

            let bundle: StatementBundle
            let chart: CompiledChart
            let selectedEntryCount: Int
            var resolvedAnchor: String? = nil
            var windowFrom: String? = nil
            var windowTo: String? = nil

            if let kind {
                let settings = try EntryCompilerSettingsLoader.load(from: project, trace: false)
                let tz = settings.entry.defaultTimezone
                let shape = PeriodShape(kind: kind, rangeToDate: input.toDate)
                let requested = try PeriodSlicer.anchor(
                    shape: shape,
                    anchor: input.anchor,
                    timeZone: tz
                )
                let calendar = periodCalendar(timeZone: tz)
                let native = try NativeOutputBuilder.buildPeriodOutput(
                    result: result,
                    shape: shape,
                    anchor: requested.anchor,
                    cut: cut,
                    omslag: .apply,
                    entity: .vof,
                    calendar: calendar
                )
                chart = native.chart
                bundle = native.assembled.current.bundle
                let window = native.assembled.current.range
                selectedEntryCount = filterEntries(result.resolved, within: window).count
                resolvedAnchor = Self.day(requested.anchor, timeZone: tz)
                windowFrom = Self.day(window.from, timeZone: tz)
                windowTo = Self.day(window.to, timeZone: tz)
            } else {
                let native = try NativeOutputBuilder.buildCompileOutput(
                    result: result,
                    cut: cut,
                    omslag: .apply,
                    entity: .vof
                )
                chart = native.chart
                bundle = native.bundle
                selectedEntryCount = result.resolved.count
            }

            return .init(
                valid: true,
                entityCount: result.entities.byFull.count,
                accountCount: result.accounts.count,
                transactionCount: result.transactions.count,
                entryCount: result.entries.count,
                resolvedEntryCount: result.resolved.count,
                selectedEntryCount: selectedEntryCount,
                period: kind?.rawValue,
                anchor: resolvedAnchor,
                windowFrom: windowFrom,
                windowTo: windowTo,
                balance: Self.rows(bundle.balance, chart: chart),
                income: Self.rows(bundle.income, chart: chart)
            )
        }
    }
}
