import Accounting
import AccountingCompiler
import Agentic
import AgenticIO
import Macros
import Schema
import Workspace

public extension Accounting.Tools {
    @Tool("accounting_used_entry_ids")
    struct UsedEntryIDs: Tool {
        @JSONSchema
        public struct Input: HashableSource {
            public init() {}
        }

        @JSONSchema
        public struct IDRange: HashableResult {
            public let lower: Int
            public let upper: Int

            public init(lower: Int, upper: Int) {
                self.lower = lower
                self.upper = upper
            }
        }

        @JSONSchema
        public struct Output: HashableResult {
            public let count: Int
            public let minimum: Int?
            public let maximum: Int?
            public let usedRanges: [IDRange]
            public let gaps: [IDRange]

            public init(
                count: Int,
                minimum: Int?,
                maximum: Int?,
                usedRanges: [IDRange],
                gaps: [IDRange]
            ) {
                self.count = count
                self.minimum = minimum
                self.maximum = maximum
                self.usedRanges = usedRanges
                self.gaps = gaps
            }
        }

        public enum Failure: Error {
            case workspaceRequired
        }

        public static let purpose = """
        Inspect used entry ID ranges and gaps in the active accounting project.
        Read-only; an ID gap is not a reservation or a recommendation to reuse it.
        Use accounting_next_entry_ids for fresh contiguous ID suggestions.
        """
        public static let risk: ActionRisk = .observe
        public init() {}

        private static func authorize(_ context: ToolContext) throws {
            guard let workspace = context.workspace else {
                throw Failure.workspaceRequired
            }
            _ = try FileToolAccess.authorize(
                workspace: workspace,
                rootID: workspace.rootIdentifier,
                path: "entries",
                capability: .scan,
                toolName: Self.identifier.rawValue,
                type: .directory
            )
            _ = try FileToolAccess.authorize(
                workspace: workspace,
                rootID: workspace.rootIdentifier,
                path: "config/settings.ec",
                capability: .read,
                toolName: Self.identifier.rawValue,
                type: .file
            )
        }

        public func preflight(_ input: Input, in context: ToolContext) async throws -> ToolPreflight {
            try Self.authorize(context)
            guard let workspace = context.workspace else {
                throw Failure.workspaceRequired
            }
            return .init(
                tool: Self.definition.identifier,
                risk: Self.definition.risk,
                summary: "Inspect used accounting entry ID ranges and gaps",
                access: .init(
                    targets: ["entries", "config/settings.ec"],
                    roots: [workspace.rootIdentifier.rawValue],
                    capabilities: [.scan, .read]
                ),
                sideEffects: []
            )
        }

        public func call(_ input: Input, in context: ToolContext) async throws -> Output {
            try Self.authorize(context)
            guard let workspace = context.workspace else {
                throw Failure.workspaceRequired
            }
            // Keep all reads inside the execution-scoped workspace boundary.
            let project = EntryCompilerProject(workspace: workspace)
            let settings = try EntryCompilerSettingsLoader.load(from: project, trace: false)
            let used = try IDScanner.usedIDs(
                project: project,
                settings: settings,
                kind: .entry,
                allowCollisions: false
            )
            return .init(
                count: used.count,
                minimum: used.first,
                maximum: used.last,
                usedRanges: IDScanner.compressRuns(used).map {
                    .init(lower: $0.lowerBound, upper: $0.upperBound)
                },
                gaps: IDScanner.gaps(between: used).map {
                    .init(lower: $0.lowerBound, upper: $0.upperBound)
                }
            )
        }
    }
}
