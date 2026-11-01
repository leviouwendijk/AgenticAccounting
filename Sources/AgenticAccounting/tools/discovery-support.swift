import Accounting
import AccountingCompiler
import Agentic
import AgenticIO
import Foundation
import Macros
import Primitives
import Schema
import Search
import Workspace

public extension Accounting.Tools {
    enum Discovery {
        @JSONSchema
        public struct IDs: HashableSource {
            public let values: [Int]
            public let from: Int?
            public let to: Int?

            public init(
                values: [Int] = [],
                from: Int? = nil,
                to: Int? = nil
            ) {
                self.values = values
                self.from = from
                self.to = to
            }
        }

        @JSONSchema
        public struct Period: HashableSource {
            public let kind: String
            public let anchor: String?
            public let from: String?
            public let to: String?
            public let toDate: Bool

            public init(
                kind: String,
                anchor: String? = nil,
                from: String? = nil,
                to: String? = nil,
                toDate: Bool = false
            ) {
                self.kind = kind
                self.anchor = anchor
                self.from = from
                self.to = to
                self.toDate = toDate
            }
        }

        @JSONSchema
        public struct Page: HashableSource {
            public let limit: Int
            public let offset: Int

            public init(
                limit: Int = 30,
                offset: Int = 0
            ) {
                self.limit = limit
                self.offset = offset
            }
        }
    }
}

enum AccountingDiscoverySupport {
    enum Failure: Error {
        case missingWorkspace
        case invalidIDs
        case tooManyIDs
        case invalidPage
        case invalidPeriod
    }

    static func identifiers(
        _ selection: Accounting.Tools.Discovery.IDs,
        maximum: Int = 100
    ) throws -> [Int] {
        guard maximum > 0 else {
            throw Failure.tooManyIDs
        }

        var result: [Int] = []
        var seen: Set<Int> = []

        for value in selection.values {
            guard value >= 0 else {
                throw Failure.invalidIDs
            }
            if seen.insert(value).inserted {
                result.append(value)
            }
        }

        if selection.from != nil || selection.to != nil {
            guard let from = selection.from,
                  let to = selection.to,
                  from >= 0,
                  to >= from,
                  to - from < maximum else {
                throw Failure.invalidIDs
            }

            for value in from...to where seen.insert(value).inserted {
                result.append(value)
            }
        }

        guard !result.isEmpty else {
            throw Failure.invalidIDs
        }
        guard result.count <= maximum else {
            throw Failure.tooManyIDs
        }
        return result
    }

    static func rangePredicate(
        _ selection: Accounting.Tools.Discovery.IDs?
    ) throws -> StructuredPredicate? {
        guard let selection else {
            return nil
        }

        guard selection.values.allSatisfy({ $0 >= 0 }) else {
            throw Failure.invalidIDs
        }

        var predicates = selection.values.map {
            StructuredPredicate.equal(field: "id", value: .integer(Int64($0)))
        }

        if selection.from != nil || selection.to != nil {
            let from = selection.from ?? 0
            let to = selection.to ?? Int.max
            guard from >= 0, from <= to else {
                throw Failure.invalidIDs
            }
            predicates.append(
                .between(
                    field: "id",
                    lower: .integer(Int64(from)),
                    upper: .integer(Int64(to))
                )
            )
        }

        guard !predicates.isEmpty else {
            throw Failure.invalidIDs
        }
        return .any(predicates)
    }

    static func periodPredicate(
        _ input: Accounting.Tools.Discovery.Period?,
        timeZone: TimeZone
    ) throws -> StructuredPredicate? {
        guard let input else {
            return nil
        }
        guard let kind = PeriodKind(rawValue: input.kind),
              kind != .lifetime,
              !(input.anchor != nil && (input.from != nil || input.to != nil)),
              (kind == .custom) == (input.from != nil || input.to != nil),
              !(kind == .custom && input.toDate) else {
            throw Failure.invalidPeriod
        }

        let resolved = try PeriodSlicer.resolve(
            shape: PeriodShape(
                kind: kind,
                rangeToDate: input.toDate
            ),
            anchor: input.anchor,
            customFrom: input.from,
            customTo: input.to,
            timeZone: timeZone
        )
        let window = resolved.windows.window
        return .between(
            field: "date",
            lower: .date(window.from ?? .distantPast),
            upper: .date(window.to ?? .distantFuture)
        )
    }

    static func authorize(
        _ context: ToolContext,
        toolName: String,
        directory: String
    ) throws -> WorkspaceContext {
        guard let workspace = context.workspace else {
            throw Failure.missingWorkspace
        }
        _ = try FileToolAccess.authorize(
            workspace: workspace,
            rootID: workspace.rootIdentifier,
            path: "config/settings.ec",
            capability: .read,
            toolName: toolName,
            type: .file
        )
        _ = try FileToolAccess.authorize(
            workspace: workspace,
            rootID: workspace.rootIdentifier,
            path: directory,
            capability: .scan,
            toolName: toolName,
            type: .directory
        )
        return workspace
    }

    static func preflight(
        context: ToolContext,
        identifier: String,
        definition: ToolDefinition,
        directory: String,
        summary: String
    ) throws -> ToolPreflight {
        let workspace = try authorize(
            context,
            toolName: identifier,
            directory: directory
        )
        return .init(
            tool: definition.identifier,
            risk: definition.risk,
            summary: summary,
            access: .init(
                targets: ["config/settings.ec", directory],
                roots: [workspace.rootIdentifier.rawValue],
                capabilities: [.read, .scan]
            ),
            sideEffects: []
        )
    }

    static func entries(
        _ context: ToolContext,
        toolName: String
    ) throws -> (records: [Entry], settings: EntryCompilerSettings) {
        let workspace = try authorize(
            context,
            toolName: toolName,
            directory: "entries"
        )
        let project = EntryCompilerProject(workspace: workspace)
        let settings = try EntryCompilerSettingsLoader.load(
            from: project,
            trace: false
        )
        let records = try EntryCompilerEntriesLoader.load(
            from: project,
            settings: settings,
            allowCollisions: true,
            trace: false,
            verbose: false
        )
        return (records, settings)
    }

    static func transactions(
        _ context: ToolContext,
        toolName: String
    ) throws -> (records: [Transaction], settings: EntryCompilerSettings) {
        let workspace = try authorize(
            context,
            toolName: toolName,
            directory: "transactions"
        )
        let project = EntryCompilerProject(workspace: workspace)
        let settings = try EntryCompilerSettingsLoader.load(
            from: project,
            trace: false
        )
        let store = try EntryCompilerTransactionsLoader.load(
            from: project,
            verbose: false,
            trace: false
        )
        return (store.all, settings)
    }

    static func search(
        fields: [[String: [StructuredValue]]],
        predicates: [StructuredPredicate],
        schema: [StructuredField],
        ordering: [StructuredOrdering],
        page: Accounting.Tools.Discovery.Page
    ) throws -> StructuredQueryResult<Int> {
        guard (1...100).contains(page.limit),
              page.offset >= 0 else {
            throw Failure.invalidPage
        }
        let records = fields.enumerated().map {
            StructuredRecord(id: $0.offset, fields: $0.element)
        }
        return try StructuredQueryEngine.execute(
            StructuredQuery(
                predicate: .all(predicates),
                ordering: ordering,
                offset: page.offset,
                limit: page.limit
            ),
            in: records,
            schema: StructuredSchema(fields: schema)
        )
    }

    static func filterText(
        _ query: String?,
        fields: [String]
    ) -> StructuredPredicate? {
        guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            return nil
        }
        return .any(fields.map {
            .text(field: $0, query: query, strategy: .contains)
        })
    }

    static func append(
        _ text: String?,
        field: String,
        to fields: inout [String: [StructuredValue]]
    ) {
        guard let text, !text.isEmpty else {
            return
        }
        fields[field, default: []].append(.text(text))
    }

    static func exactText(
        _ values: [String],
        field: String
    ) -> StructuredPredicate? {
        guard !values.isEmpty else {
            return nil
        }
        return .oneOf(
            field: field,
            values: values.map { .text($0) }
        )
    }

    static func day(_ specification: DateSpecification) -> Date? {
        guard case .absolute(let date) = specification else {
            return nil
        }
        return date
    }
}
