import Accounting
import AccountingCompiler
import Agentic
import AgenticIO
import Foundation
import Macros
import Schema
import Workspace

public extension Accounting.Tools {
    @Tool("accounting_next_entry_ids")
    struct NextEntryIDs: Tool {
        @JSONSchema
        public struct Input: HashableSource {
            public let count: Int

            public init(count: Int) {
                self.count = count
            }
        }

        @JSONSchema
        public struct Output: HashableResult {
            public let ids: [Int]
            public let existingEntryCount: Int
            public let highestExistingID: Int

            public init(
                ids: [Int],
                existingEntryCount: Int,
                highestExistingID: Int
            ) {
                self.ids = ids
                self.existingEntryCount = existingEntryCount
                self.highestExistingID = highestExistingID
            }
        }

        public enum Failure: Error {
            case workspaceRequired
            case invalidCount
            case identifierOverflow
        }

        public static let purpose = """
        Inspect the active accounting project using AccountingCompiler and
        suggest contiguous new entry IDs. Read-only, not a reservation.
        """
        public static let risk: ActionRisk = .observe
        public init() {}

        private static func validate(_ input: Input) throws {
            guard (1...100).contains(input.count) else {
                throw Failure.invalidCount
            }
        }

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

        public func preflight(
            _ input: Input,
            in context: ToolContext
        ) async throws -> ToolPreflight {
            try Self.validate(input)
            try Self.authorize(context)
            guard let workspace = context.workspace else {
                throw Failure.workspaceRequired
            }
            return .init(
                tool: Self.definition.identifier,
                risk: Self.definition.risk,
                summary: "Inspect accounting entries and suggest fresh IDs",
                access: .init(
                    targets: ["entries", "config/settings.ec"],
                    roots: [workspace.rootIdentifier.rawValue],
                    capabilities: [.scan, .read]
                ),
                sideEffects: []
            )
        }

        public func call(
            _ input: Input,
            in context: ToolContext
        ) async throws -> Output {
            try Self.validate(input)
            try Self.authorize(context)
            guard let workspace = context.workspace else {
                throw Failure.workspaceRequired
            }
            // Carry the execution-scoped workspace through every compiler read.
            // Never reopen the project through the trusted URL-only initializer.
            let project = EntryCompilerProject(workspace: workspace)
            let settings = try EntryCompilerSettingsLoader.load(
                from: project,
                trace: false
            )
            let used = try IDScanner.usedIDs(
                project: project,
                settings: settings,
                kind: .entry,
                allowCollisions: false
            )
            let highest = used.last ?? 0
            guard highest <= Int.max - input.count else {
                throw Failure.identifierOverflow
            }
            return .init(
                ids: (1...input.count).map { highest + $0 },
                existingEntryCount: used.count,
                highestExistingID: highest
            )
        }
    }
}
