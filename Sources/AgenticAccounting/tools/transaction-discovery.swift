import Accounting
import Agentic
import Foundation
import Macros
import Primitives
import Schema
import Search

public extension Accounting.Tools {
    @Tool("accounting_search_transactions")
    struct SearchTransactions: Tool {
        @JSONSchema
        public struct Amount: HashableSource {
            public let from: String?
            public let to: String?

            public init(
                lower: String? = nil,
                upper: String? = nil
            ) {
                self.from = lower
                self.to = upper
            }
        }

        @JSONSchema
        public struct Input: HashableSource {
            public let ids: Discovery.IDs?
            public let text: String?
            public let sources: [String]
            public let statuses: [String]
            public let counterparty: String?
            public let currency: String?
            public let amount: Amount?
            public let period: Discovery.Period?
            public let page: Discovery.Page

            public init(
                ids: Discovery.IDs? = nil,
                text: String? = nil,
                sources: [String] = [],
                statuses: [String] = [],
                counterparty: String? = nil,
                currency: String? = nil,
                amount: Amount? = nil,
                period: Discovery.Period? = nil,
                page: Discovery.Page = .init()
            ) {
                self.ids = ids
                self.text = text
                self.sources = sources
                self.statuses = statuses
                self.counterparty = counterparty
                self.currency = currency
                self.amount = amount
                self.period = period
                self.page = page
            }
        }

        @JSONSchema
        public struct Hit: HashableResult {
            public let id: Int
            public let details: String?
            public let gross: String
            public let currency: String
            public let score: Int

            public init(
                id: Int,
                details: String?,
                gross: String,
                currency: String,
                score: Int
            ) {
                self.id = id
                self.details = details
                self.gross = gross
                self.currency = currency
                self.score = score
            }
        }

        @JSONSchema
        public struct Output: HashableResult {
            public let searchedCount: Int
            public let matchedCount: Int
            public let hits: [Hit]
            public let nextOffset: Int?

            public init(
                searchedCount: Int,
                matchedCount: Int,
                hits: [Hit],
                nextOffset: Int?
            ) {
                self.searchedCount = searchedCount
                self.matchedCount = matchedCount
                self.hits = hits
                self.nextOffset = nextOffset
            }
        }

        public enum Failure: Error {
            case invalidAmount
        }

        public static let purpose = """
        Search canonical transactions by ID range, text, source, status,
        counterparty, currency, exact decimal gross amount and accounting period.
        Structured comparisons are deterministic. No mutation or compilation.
        """
        public static let risk: ActionRisk = .observe
        public init() {}

        private static func amountPredicate(
            _ amount: Amount?
        ) throws -> StructuredPredicate? {
            guard let amount else {
                return nil
            }
            guard amount.from != nil || amount.to != nil else {
                throw Failure.invalidAmount
            }
            guard let from = amount.from,
                  let to = amount.to,
                  let lower = Decimal(
                    string: from,
                    locale: Locale(identifier: "en_US_POSIX")
                  ),
                  let upper = Decimal(
                    string: to,
                    locale: Locale(identifier: "en_US_POSIX")
                  ),
                  lower <= upper else {
                throw Failure.invalidAmount
            }
            return .between(
                field: "amount",
                lower: .decimal(lower),
                upper: .decimal(upper)
            )
        }

        public func preflight(
            _ input: Input,
            in context: ToolContext
        ) async throws -> ToolPreflight {
            _ = try Self.amountPredicate(input.amount)
            return try AccountingDiscoverySupport.preflight(
                context: context,
                identifier: Self.identifier.rawValue,
                definition: Self.definition,
                directory: "transactions",
                summary: "Search accounting transactions"
            )
        }

        public func call(
            _ input: Input,
            in context: ToolContext
        ) async throws -> Output {
            let loaded = try AccountingDiscoverySupport.transactions(
                context,
                toolName: Self.identifier.rawValue
            )
            let records = loaded.records.filter { $0.id != nil }.sorted {
                ($0.id ?? Int.max) < ($1.id ?? Int.max)
            }
            var predicates: [StructuredPredicate] = []

            if let ids = try AccountingDiscoverySupport.rangePredicate(input.ids) {
                predicates.append(ids)
            }
            if let text = AccountingDiscoverySupport.filterText(
                input.text,
                fields: ["details", "metadata", "counterparty"]
            ) {
                predicates.append(text)
            }
            if let sources = AccountingDiscoverySupport.exactText(
                input.sources,
                field: "source"
            ) {
                predicates.append(sources)
            }
            if let statuses = AccountingDiscoverySupport.exactText(
                input.statuses,
                field: "status"
            ) {
                predicates.append(statuses)
            }
            if let counterparty = input.counterparty {
                predicates.append(
                    .equal(field: "counterparty", value: .text(counterparty))
                )
            }
            if let currency = input.currency {
                predicates.append(
                    .equal(field: "currency", value: .text(currency))
                )
            }
            if let amount = try Self.amountPredicate(input.amount) {
                predicates.append(amount)
            }
            if let period = try AccountingDiscoverySupport.periodPredicate(
                input.period,
                timeZone: loaded.settings.entry.defaultTimezone
            ) {
                predicates.append(period)
            }

            let fields: [[String: [StructuredValue]]] = records.map { transaction in
                var fields: [String: [StructuredValue]] = [
                    "amount": [.decimal(transaction.amount.gross)],
                    "currency": [.text(transaction.amount.currency)],
                    "source": [.text(transaction.source.rawValue)],
                    "status": [.text(transaction.status.rawValue)]
                ]
                if let id = transaction.id {
                    fields["id"] = [.integer(Int64(id))]
                }
                if let date = AccountingDiscoverySupport.day(transaction.date) {
                    fields["date"] = [.date(date)]
                }
                AccountingDiscoverySupport.append(
                    transaction.details,
                    field: "details",
                    to: &fields
                )
                AccountingDiscoverySupport.append(
                    transaction.counterparty?.name,
                    field: "counterparty",
                    to: &fields
                )
                for (key, value) in transaction.metadata {
                    AccountingDiscoverySupport.append(
                        "\(key)=\(value)",
                        field: "metadata",
                        to: &fields
                    )
                }
                return fields
            }
            let result = try AccountingDiscoverySupport.search(
                fields: fields,
                predicates: predicates,
                schema: [
                    .init("id", kind: .integer),
                    .init("date", kind: .date),
                    .init("amount", kind: .decimal),
                    .init("currency", kind: .text),
                    .init("source", kind: .text),
                    .init("status", kind: .text),
                    .init("details", kind: .text),
                    .init("counterparty", kind: .text),
                    .init("metadata", kind: .text, multiple: true)
                ],
                ordering: [.field("id", ascending: true)],
                page: input.page
            )
            return .init(
                searchedCount: result.searchedCount,
                matchedCount: result.matchedCount,
                hits: result.hits.compactMap { hit in
                    let transaction = records[hit.id]
                    guard let id = transaction.id else {
                        return nil
                    }
                    return Hit(
                        id: id,
                        details: transaction.details,
                        gross: NSDecimalNumber(decimal: transaction.amount.gross).stringValue,
                        currency: transaction.amount.currency,
                        score: hit.score
                    )
                },
                nextOffset: result.nextOffset
            )
        }
    }

    @Tool("accounting_read_transactions")
    struct ReadTransactions: Tool {
        @JSONSchema
        public struct Input: HashableSource {
            public let ids: Discovery.IDs

            public init(
                ids: Discovery.IDs
            ) {
                self.ids = ids
            }
        }

        @JSONSchema
        public struct Record: HashableResult {
            public let id: Int
            public let value: JSONValue
            public let gross: String
            public let fee: String?
            public let net: String?

            public init(
                id: Int,
                value: JSONValue,
                gross: String,
                fee: String?,
                net: String?
            ) {
                self.id = id
                self.value = value
                self.gross = gross
                self.fee = fee
                self.net = net
            }
        }

        @JSONSchema
        public struct Output: HashableResult {
            public let records: [Record]
            public let missingIDs: [Int]

            public init(
                records: [Record],
                missingIDs: [Int]
            ) {
                self.records = records
                self.missingIDs = missingIDs
            }
        }

        public static let purpose = """
        Read complete canonical transaction records by IDs or inclusive ID range.
        Missing IDs are reported without discarding existing records. Amounts
        are also preserved as exact decimal strings. Duplicate transaction IDs
        are rejected by Accounting's canonical TransactionStore loader.
        """
        public static let risk: ActionRisk = .observe
        public init() {}

        public func preflight(
            _ input: Input,
            in context: ToolContext
        ) async throws -> ToolPreflight {
            _ = try AccountingDiscoverySupport.identifiers(input.ids)
            return try AccountingDiscoverySupport.preflight(
                context: context,
                identifier: Self.identifier.rawValue,
                definition: Self.definition,
                directory: "transactions",
                summary: "Read accounting transactions"
            )
        }

        public func call(
            _ input: Input,
            in context: ToolContext
        ) async throws -> Output {
            let ids = try AccountingDiscoverySupport.identifiers(input.ids)
            let loaded = try AccountingDiscoverySupport.transactions(
                context,
                toolName: Self.identifier.rawValue
            )
            let byID = Dictionary(
                uniqueKeysWithValues: loaded.records.compactMap { transaction in
                    transaction.id.map { ($0, transaction) }
                }
            )
            var records: [Record] = []
            var missing: [Int] = []
            for id in ids {
                guard let transaction = byID[id] else {
                    missing.append(id)
                    continue
                }
                records.append(
                    .init(
                        id: id,
                        value: try JSONCoding.default.value(transaction),
                        gross: NSDecimalNumber(decimal: transaction.amount.gross).stringValue,
                        fee: transaction.amount.fee.map {
                            NSDecimalNumber(decimal: $0).stringValue
                        },
                        net: transaction.amount.net.map {
                            NSDecimalNumber(decimal: $0).stringValue
                        }
                    )
                )
            }
            return .init(records: records, missingIDs: missing)
        }
    }
}
