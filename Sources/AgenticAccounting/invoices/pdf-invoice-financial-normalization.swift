import Agentic
import AgenticPDF
import Foundation
import Macros
import Math
import Schema

/// Interprets source-verified invoice candidates without reclassifying their evidence.
/// An instance is a deterministic analysis of the supplied verification output,
/// not independent proof that the supplied output came from a tool invocation.
@JSONSchema
public struct PDFInvoiceFinancialNormalization: HashableProduct {
    public typealias Field = Accounting.Inferences.ExtractPDFInvoice.Output.Field
    public typealias Source = Accounting.Tools.VerifyPDFInvoiceEvidence.Output

    @JSONSchema
    public enum Convention: String, HashableProduct {
        case decimal_comma
        case decimal_dot
        case day_month_year
        case month_day_year
        case iso_date
        case currency_code
    }

    @JSONSchema
    public enum Status: String, HashableProduct {
        case resolved
        case ambiguous
        case invalid
        case not_applicable
    }

    @JSONSchema
    public struct Interpretation: HashableProduct {
        public let convention: Convention
        public let value: String

        public init(convention: Convention, value: String) {
            self.convention = convention
            self.value = value
        }
    }

    @JSONSchema
    public struct Issue: HashableProduct {
        @JSONSchema
        public enum Kind: String, HashableProduct {
            case ambiguous_value
            case invalid_value
            case proposal_mismatch
            case conflicting_field
        }

        public let kind: Kind
        public let candidateIndex: Int?
        public let field: Field
    }

    @JSONSchema
    public struct Candidate: HashableProduct {
        /// The proposal and every source-verified citation are preserved intact.
        public let source: Source.Candidate
        public let status: Status
        /// A unique value only, never an arbitrarily chosen locale interpretation.
        public let value: String?
        public let alternatives: [Interpretation]
        /// Compares the model's normalizedValue to the deterministic value, if unique.
        public let proposalMatches: Bool?
    }

    public let sourceFingerprint: String
    public let candidates: [Candidate]
    /// Styles supported by at least one uniquely parseable source candidate.
    /// This is evidence for a later notation inference, not a document-wide rule.
    public let observedConventions: [Convention]
    /// Contradictory singleton document-level fields, not multi-band VAT fields.
    public let conflictingFields: [Field]
    public let issues: [Issue]
    public let unresolved: [String]
    public let warnings: [String]

    public init(source: Source) {
        sourceFingerprint = source.sourceFingerprint
        let parsedCandidates = source.candidates.map { record in
            let options = Self.interpretations(
                rawValue: record.proposal.rawValue,
                field: record.proposal.field
            )
            let isApplicable = Self.isApplicable(record.proposal.field)
            let values = Set(options.map(\.value))
            let status: Status
            if !isApplicable {
                status = .not_applicable
            } else if values.isEmpty {
                status = .invalid
            } else if values.count == 1 {
                status = .resolved
            } else {
                status = .ambiguous
            }
            let value = status == .resolved ? options.first?.value : nil
            return Candidate(
                source: record,
                status: status,
                value: value,
                alternatives: options,
                proposalMatches: value.flatMap { Self.matchesProposal(
                    record.proposal.normalizedValue,
                    value: $0,
                    field: record.proposal.field
                ) }
            )
        }

        candidates = parsedCandidates
        observedConventions = [
            Convention.decimal_comma, .decimal_dot, .day_month_year, .month_day_year
        ].filter { convention in
            parsedCandidates.contains { candidate in
                candidate.status == .resolved &&
                candidate.alternatives.count == 1 &&
                candidate.alternatives.first?.convention == convention
            }
        }

        let singletonFields: [Field] = [.invoice_date, .due_date, .currency, .gross_amount]
        let conflicts = singletonFields.filter { field in
            Set(parsedCandidates.compactMap { candidate in
                candidate.source.proposal.field == field ? candidate.value : nil
            }).count > 1
        }
        conflictingFields = conflicts
        var findings: [Issue] = []
        for (index, candidate) in parsedCandidates.enumerated() {
            let kind: Issue.Kind?
            switch candidate.status {
            case .ambiguous: kind = .ambiguous_value
            case .invalid: kind = .invalid_value
            case .resolved, .not_applicable:
                kind = candidate.proposalMatches == false ? .proposal_mismatch : nil
            }
            if let kind {
                findings.append(.init(
                    kind: kind,
                    candidateIndex: index,
                    field: candidate.source.proposal.field
                ))
            }
        }
        for field in conflicts {
            findings.append(.init(kind: .conflicting_field, candidateIndex: nil, field: field))
        }
        issues = findings
        unresolved = source.unresolved
        warnings = source.warnings
    }

    public static func interpretations(rawValue: String, field: Field) -> [Interpretation] {
        switch field {
        case .net_amount, .vat_base, .vat_amount, .vat_total, .gross_amount:
            return numberInterpretations(rawValue, percentage: false)
        case .vat_rate:
            return numberInterpretations(rawValue, percentage: true)
        case .invoice_date, .due_date:
            return dateInterpretations(rawValue)
        case .currency:
            return currencyInterpretations(rawValue)
        default:
            return []
        }
    }

    private static func isApplicable(_ field: Field) -> Bool {
        switch field {
        case .net_amount, .vat_base, .vat_amount, .vat_total, .gross_amount,
             .vat_rate, .invoice_date, .due_date, .currency:
            true
        default:
            false
        }
    }

    private static func numberInterpretations(
        _ raw: String,
        percentage: Bool
    ) -> [Interpretation] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !percentage || trimmed.hasSuffix("%") else { return [] }
        let numeric = percentage
            ? String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmed
        return [Convention.decimal_comma, .decimal_dot].compactMap { convention in
            guard let parsed = parseNumber(numeric, convention: convention) else { return nil }
            let value = percentage ? parsed / Decimal(100) : parsed
            return Interpretation(
                convention: convention,
                value: NSDecimalNumber(decimal: value).stringValue
            )
        }
    }

    private static func parseNumber(_ raw: String, convention: Convention) -> Decimal? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var negative = false
        if text.hasPrefix("("), text.hasSuffix(")") {
            negative = true
            text = String(text.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.hasPrefix("-") || text.hasPrefix("+") {
            guard !negative else { return nil }
            negative = text.hasPrefix("-")
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // An amount may carry a symbol or an ISO code; removing the label does
        // not prove the invoice's currency. Currency is analyzed separately.
        let affixes = ["EUR", "USD", "GBP", "CHF", "CAD", "AUD", "JPY", "€", "£", "$", "¥"]
        if let prefix = affixes.first(where: { text.hasPrefix($0) }) {
            text = String(text.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let suffix = affixes.first(where: { text.hasSuffix($0) }) {
            text = String(text.dropLast(suffix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { return nil }

        let decimal: Character = convention == .decimal_comma ? "," : "."
        let grouping: Character = convention == .decimal_comma ? "." : ","
        let sections = text.split(separator: decimal, omittingEmptySubsequences: false)
        guard sections.count <= 2, let first = sections.first, !first.isEmpty else { return nil }
        let integer = String(first)
        let groups = integer.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == grouping || $0 == " " || $0 == "'" || $0 == "\u{00a0}" || $0 == "\u{202f}" }
        )
        guard !groups.isEmpty, !groups.contains(where: { $0.isEmpty }),
              groups.allSatisfy({ asciiDigits(String($0)) }) else { return nil }
        if groups.count > 1 {
            guard (1...3).contains(groups[0].count),
                  groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
        }
        let whole = groups.joined()
        var literal = whole
        if sections.count == 2 {
            let fraction = String(sections[1])
            guard !fraction.isEmpty, asciiDigits(fraction) else { return nil }
            literal += "." + fraction
        }
        if negative { literal = "-" + literal }
        return try? DecimalArithmetic.parse(literal)
    }

    private static func asciiDigits(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
    }

    private static func dateInterpretations(_ raw: String) -> [Interpretation] {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let separators: [Character] = ["-", "/", "."]
        let present = separators.filter { value.contains($0) }
        guard present.count == 1 else { return [] }
        let parts = value.split(separator: present[0], omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ asciiDigits(String($0)) }),
              let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]) else {
            return []
        }
        if parts[0].count == 4 && present[0] == "-",
           let iso = canonicalDay(year: a, month: b, day: c) {
            return [.init(convention: .iso_date, value: iso)]
        }
        guard parts[2].count == 4, parts[0].count <= 2, parts[1].count <= 2 else {
            return []
        }
        var results: [Interpretation] = []
        if let dmy = canonicalDay(year: c, month: b, day: a) {
            results.append(.init(convention: .day_month_year, value: dmy))
        }
        if let mdy = canonicalDay(year: c, month: a, day: b) {
            results.append(.init(convention: .month_day_year, value: mdy))
        }
        return results
    }

    private static func canonicalDay(year: Int, month: Int, day: Int) -> String? {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else {
            return nil
        }
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        guard let date = calendar.date(from: components) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func currencyInterpretations(_ raw: String) -> [Interpretation] {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let known: Set<String> = [
            "EUR", "USD", "GBP", "CHF", "JPY", "CAD", "AUD", "NZD", "SEK", "NOK",
            "DKK", "PLN", "CZK", "HUF", "CNY", "INR", "ZAR", "TRY", "RON"
        ]
        if known.contains(code) { return [.init(convention: .currency_code, value: code)] }
        switch code {
        case "€": return [.init(convention: .currency_code, value: "EUR")]
        case "£": return [.init(convention: .currency_code, value: "GBP")]
        default: return [] // $, ¥, kr etc. are not unambiguous ISO currency identifiers.
        }
    }

    private static func matchesProposal(_ proposal: String?, value: String, field: Field) -> Bool? {
        guard let proposal else { return nil }
        switch field {
        case .net_amount, .vat_base, .vat_amount, .vat_total, .gross_amount, .vat_rate:
            guard let expected = try? DecimalArithmetic.parse(proposal),
                  let actual = try? DecimalArithmetic.parse(value) else { return false }
            return expected == actual
        case .currency:
            return proposal.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == value
        default:
            return proposal == value
        }
    }
}
