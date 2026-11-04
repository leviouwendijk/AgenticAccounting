import Agentic
import Foundation
import Macros
import Math
import Schema

/// Explores deterministic numeric alternatives under explicit arithmetic premises.
/// Consistency is not proof that a textual interpretation or band association is correct.
@JSONSchema
public struct PDFInvoiceArithmeticDisambiguation: HashableProduct {
    public typealias Normalization = PDFInvoiceFinancialNormalization

    @JSONSchema
    public enum Status: String, HashableProduct {
        case unavailable
        case bounded
        case no_consistent_solution
        case unique_solution
        case multiple_solutions
    }

    @JSONSchema
    public struct Choice: HashableProduct {
        public let candidateIndex: Int
        public let value: String
    }

    public let normalization: Normalization
    public let status: Status
    public let solutionCount: Int
    /// Only populated when the solution is unique; otherwise all source alternatives survive.
    public let uniqueChoices: [Choice]
    public let checkedEquations: Int
    public let roundingScale: Int?

    public init(
        normalization: Normalization,
        proposedBands: [PDFInvoiceArithmeticAssessment.VATBand] = [],
        claimedCompleteBandSet: Bool = false,
        roundingScale: Int? = nil,
        maximumCombinations: Int = 4096
    ) throws {
        guard maximumCombinations > 0 else { throw Failure.invalid_limit }
        if let roundingScale, !(0...8).contains(roundingScale) { throw Failure.invalid_scale }
        self.normalization = normalization
        self.roundingScale = roundingScale

        // The pre-existing assessment checks all band indices and role constraints.
        _ = try PDFInvoiceArithmeticAssessment(
            normalization: normalization,
            proposedBands: proposedBands,
            claimedCompleteBandSet: claimedCompleteBandSet,
            roundingScale: roundingScale
        )

        let numeric: Set<Normalization.Field> = [
            .net_amount, .vat_total, .gross_amount, .vat_base, .vat_rate, .vat_amount
        ]
        let uncertain: [(Int, [String])] = normalization.candidates.enumerated().compactMap { index, candidate in
            guard numeric.contains(candidate.source.proposal.field), candidate.status == .ambiguous else { return nil }
            let values = Array(Set(candidate.alternatives.map(\.value))).sorted()
            return (index, values)
        }
        var possibilities = 1
        var overLimit = false
        for (_, options) in uncertain {
            if options.isEmpty || possibilities > maximumCombinations / options.count {
                overLimit = true
                break
            }
            possibilities *= options.count
        }
        if overLimit {
            status = .bounded
            solutionCount = 0
            uniqueChoices = []
            checkedEquations = 0
            return
        }

        let byField: [Normalization.Field: [Int]] = Dictionary(grouping: normalization.candidates.indices) {
            normalization.candidates[$0].source.proposal.field
        }
        let invoiceFields: [Normalization.Field] = [.net_amount, .vat_total, .gross_amount]
        let invoiceIndices = invoiceFields.compactMap { field -> Int? in
            guard let indices = byField[field], indices.count == 1 else { return nil }
            return indices[0]
        }
        let invoiceEquation = invoiceIndices.count == 3
        let equationCount = (invoiceEquation ? 1 : 0) + proposedBands.count +
            (claimedCompleteBandSet && !proposedBands.isEmpty ? 2 : 0)
        checkedEquations = equationCount
        guard equationCount > 0 else {
            status = .unavailable
            solutionCount = 0
            uniqueChoices = []
            return
        }

        func value(_ index: Int, choices: [Int: String]) -> Decimal? {
            let text = choices[index] ?? normalization.candidates[index].value
            return text.flatMap { try? DecimalArithmetic.parse($0) }
        }
        func equal(_ expected: Decimal, _ actual: Decimal) -> Bool {
            if expected == actual { return true }
            guard let roundingScale else { return false }
            var target = expected
            var rounded = Decimal()
            NSDecimalRound(&rounded, &target, roundingScale, .plain)
            return rounded == actual
        }
        func satisfies(_ choices: [Int: String]) -> Bool {
            if invoiceEquation {
                guard let n = value(invoiceIndices[0], choices: choices),
                      let t = value(invoiceIndices[1], choices: choices),
                      let g = value(invoiceIndices[2], choices: choices) else { return false }
                if n + t != g { return false }
            }
            for band in proposedBands {
                guard let base = value(band.baseIndex, choices: choices),
                      let rate = value(band.rateIndex, choices: choices),
                      let amount = value(band.amountIndex, choices: choices) else { return false }
                if !equal(base * rate, amount) { return false }
            }
            if claimedCompleteBandSet && !proposedBands.isEmpty {
                guard let netIndex = byField[.net_amount], netIndex.count == 1,
                      let totalIndex = byField[.vat_total], totalIndex.count == 1,
                      let net = value(netIndex[0], choices: choices),
                      let vat = value(totalIndex[0], choices: choices) else { return false }
                var bases = Decimal.zero
                var amounts = Decimal.zero
                for band in proposedBands {
                    guard let base = value(band.baseIndex, choices: choices),
                          let amount = value(band.amountIndex, choices: choices) else { return false }
                    bases += base
                    amounts += amount
                }
                if bases != net || amounts != vat { return false }
            }
            return true
        }

        var matches = 0
        var unique: [Int: String] = [:]
        func enumerate(_ depth: Int, _ selected: [Int: String]) {
            if depth == uncertain.count {
                if satisfies(selected) {
                    matches += 1
                    if matches == 1 { unique = selected }
                }
                return
            }
            let (index, values) = uncertain[depth]
            for option in values {
                var next = selected
                next[index] = option
                enumerate(depth + 1, next)
            }
        }
        enumerate(0, [:])
        solutionCount = matches
        if matches == 0 {
            status = .no_consistent_solution
            uniqueChoices = []
        } else if matches == 1 {
            status = .unique_solution
            uniqueChoices = unique.sorted { $0.key < $1.key }.map { Choice(candidateIndex: $0.key, value: $0.value) }
        } else {
            status = .multiple_solutions
            uniqueChoices = []
        }
    }

    public enum Failure: Error, Sendable {
        case invalid_limit
        case invalid_scale
    }
}
