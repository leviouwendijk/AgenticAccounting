import Accounting
import Agentic
import Macros
import Schema

public extension Accounting.Tools {
    @Tool("accounting_entry_context")
    struct EntryContext: Tool {
        @JSONSchema
        public struct Input: HashableSource {
            public init() {}
        }

        @JSONSchema
        public struct Output: HashableResult {
            public let timezone: String
            public let chart: String
            public let accountCount: Int
            public let entityCount: Int
            public let entryPathConvention: String
            public let referenceConvention: String
            public let transactionReferencesOptional: Bool
            public let suggestedWorkflow: [String]

            public init(
                timezone: String, chart: String, accountCount: Int, entityCount: Int,
                entryPathConvention: String, referenceConvention: String,
                transactionReferencesOptional: Bool, suggestedWorkflow: [String]
            ) {
                self.timezone = timezone
                self.chart = chart
                self.accountCount = accountCount
                self.entityCount = entityCount
                self.entryPathConvention = entryPathConvention
                self.referenceConvention = referenceConvention
                self.transactionReferencesOptional = transactionReferencesOptional
                self.suggestedWorkflow = suggestedWorkflow
            }
        }

        public static let purpose = """
        Return bounded project authoring conventions and selected chart context.
        Load the active chart and declarations without scanning entries or
        compiling the ledger. Do not enumerate all accounts or entities.
        """
        public static let risk: ActionRisk = .observe
        public init() {}

        public func preflight(_ input: Input, in context: ToolContext) async throws -> ToolPreflight {
            let workspace = try AccountingReferenceCatalog.authorize(
                context, toolName: Self.identifier.rawValue,
                accounts: true, entities: true
            )
            return .init(
                tool: Self.definition.identifier,
                risk: Self.definition.risk,
                summary: "Read concise accounting authoring context",
                access: .init(
                    targets: AccountingReferenceCatalog.targets(accounts: true, entities: true),
                    roots: [workspace.rootIdentifier.rawValue],
                    capabilities: [.read, .scan]
                ),
                sideEffects: []
            )
        }

        public func call(_ input: Input, in context: ToolContext) async throws -> Output {
            let catalog = try AccountingReferenceCatalog.load(
                context, toolName: Self.identifier.rawValue,
                accounts: true, entities: true
            )
            return .init(
                timezone: catalog.settings.entry.defaultTimezone.identifier,
                chart: "\(catalog.settings.aggregation.chartFind) \(catalog.settings.aggregation.chartVersion.versionString(separator: "_"))",
                accountCount: catalog.accounts?.count ?? 0,
                entityCount: catalog.entities?.byFull.count ?? 0,
                entryPathConvention: "entries/YYYY/Q/M/*.ec (Q is calendar quarter, M is quarter-local month)",
                referenceConvention: "Entries use existing account identifiers and 1–3 segment entity keys. Resolve candidates before drafting; a search hit is not validation.",
                transactionReferencesOptional: true,
                suggestedWorkflow: [
                    "accounting_next_entry_ids",
                    "accounting_find_references",
                    "accounting_resolve_references",
                    "accounting_validate_entry_draft",
                    "mutate_files",
                    "accounting_compile_entries (omit period, anchor and toDate for full-ledger verification)"
                ]
            )
        }
    }
}
