import Foundation
import Math

/// Checks arithmetic relations among deterministically normalized PDF claims.
/// Proposed VAT band associations and claimed coverage are not independently
/// established by these calculations. Nothing here determines VAT treatment.
public struct PDFInvoiceArithmeticAssessment: Sendable, Hashable, Codable {
    public typealias Normalization = PDFInvoiceFinancialNormalization
    public typealias Field = Normalization.Field

    /// Indices of one proposed VAT band within Normalization.candidates.
    /// The associations must be established separately from arithmetic.
    public struct VATBand: Sendable, Hashable, Codable {
        public let baseIndex: Int
        public let rateIndex: Int
        public let amountIndex: Int

        public init(baseIndex: Int, rateIndex: Int, amountIndex: Int) {
            self.baseIndex = baseIndex
            self.rateIndex = rateIndex
            self.amountIndex = amountIndex
        }
    }

    public enum Kind: String, Sendable, Hashable, Codable {
        case invoice_balance
        case vat_band
        case vat_bases_sum
        case vat_amounts_sum
    }

    public enum Status: String, Sendable, Hashable, Codable {
        case exact
        case rounded
        case mismatch
        case ambiguous
        case unavailable
    }

    public enum Premise: String, Sendable, Hashable, Codable {
        case extracted_totals
        case proposed_band_association
        case claimed_band_coverage
    }

    public struct Check: Sendable, Hashable, Codable {
        public let premise: Premise
        public let kind: Kind
        public let bandIndex: Int?
        public let status: Status
        public let candidateIndices: [Int]
        public let expected: String?
        public let actual: String?
        /// actual - expected, using decimal arithmetic.
        public let difference: String?
    }

    public enum Failure: Error, Sendable, Equatable {
        case invalid_candidate_index(Int)
        case incorrect_field(Int)
        case repeated_base(Int)
        case repeated_amount(Int)
        case invalid_rounding_scale(Int)
    }

    public let normalization: Normalization
    public let proposedBands: [VATBand]
    /// Caller assertion only; not proof that all VAT bands were extracted.
    public let claimedCompleteBandSet: Bool
    /// Optional hypothetical decimal rounding scale, not a legal tax rule.
    public let roundingScale: Int?
    public let checks: [Check]

    public init(
        normalization: Normalization,
        proposedBands: [VATBand] = [],
        claimedCompleteBandSet: Bool = false,
        roundingScale: Int? = nil
    ) throws {
        if let roundingScale, !(0...8).contains(roundingScale) {
            throw Failure.invalid_rounding_scale(roundingScale)
        }
        var usedBases = Set<Int>()
        var usedAmounts = Set<Int>()
        for band in proposedBands {
            try Self.checkField(band.baseIndex, expected: .vat_base, in: normalization)
            try Self.checkField(band.rateIndex, expected: .vat_rate, in: normalization)
            try Self.checkField(band.amountIndex, expected: .vat_amount, in: normalization)
            guard usedBases.insert(band.baseIndex).inserted else {
                throw Failure.repeated_base(band.baseIndex)
            }
            guard usedAmounts.insert(band.amountIndex).inserted else {
                throw Failure.repeated_amount(band.amountIndex)
            }
        }

        self.normalization = normalization
        self.proposedBands = proposedBands
        self.claimedCompleteBandSet = claimedCompleteBandSet
        self.roundingScale = roundingScale

        let net = Self.field(.net_amount, in: normalization)
        let vat = Self.field(.vat_total, in: normalization)
        let gross = Self.field(.gross_amount, in: normalization)

        var results = [Self.evaluate(
            kind: .invoice_balance,
            premise: .extracted_totals,
            bandIndex: nil,
            parts: [net, vat, gross],
            roundingScale: nil
        ) { values in
            (values[0] + values[1], values[2])
        }]

        for (bandIndex, band) in proposedBands.enumerated() {
            let components = [
                Self.candidate(band.baseIndex, in: normalization),
                Self.candidate(band.rateIndex, in: normalization),
                Self.candidate(band.amountIndex, in: normalization)
            ]
            results.append(Self.evaluate(
                kind: .vat_band,
                premise: .proposed_band_association,
                bandIndex: bandIndex,
                parts: components,
                roundingScale: roundingScale
            ) { values in
                (values[0] * values[1], values[2])
            })
        }

        if claimedCompleteBandSet {
            let bases = proposedBands.map { Self.candidate($0.baseIndex, in: normalization) }
            let amounts = proposedBands.map { Self.candidate($0.amountIndex, in: normalization) }
            results.append(Self.evaluate(
                kind: .vat_bases_sum,
                premise: .claimed_band_coverage,
                bandIndex: nil,
                parts: bases + [net],
                roundingScale: nil,
                minimumPartCount: 2
            ) { values in
                (values.dropLast().reduce(Decimal.zero, +), values[values.count - 1])
            })
            results.append(Self.evaluate(
                kind: .vat_amounts_sum,
                premise: .claimed_band_coverage,
                bandIndex: nil,
                parts: amounts + [vat],
                roundingScale: nil,
                minimumPartCount: 2
            ) { values in
                (values.dropLast().reduce(Decimal.zero, +), values[values.count - 1])
            })
        }
        checks = results
    }

    private struct Part {
        let indices: [Int]
        let value: Decimal?
        let ambiguous: Bool
    }

    private static func checkField(
        _ index: Int,
        expected: Field,
        in normalization: Normalization
    ) throws {
        guard normalization.candidates.indices.contains(index) else {
            throw Failure.invalid_candidate_index(index)
        }
        guard normalization.candidates[index].source.proposal.field == expected else {
            throw Failure.incorrect_field(index)
        }
    }

    private static func candidate(_ index: Int, in normalization: Normalization) -> Part {
        let candidate = normalization.candidates[index]
        return Part(
            indices: [index],
            value: candidate.status == .resolved
                ? candidate.value.flatMap { try? DecimalArithmetic.parse($0) }
                : nil,
            ambiguous: candidate.status == .ambiguous
        )
    }

    private static func field(_ field: Field, in normalization: Normalization) -> Part {
        let indices = normalization.candidates.indices.filter {
            normalization.candidates[$0].source.proposal.field == field
        }
        guard indices.count == 1, let index = indices.first else {
            return Part(indices: indices, value: nil, ambiguous: indices.count > 1)
        }
        return candidate(index, in: normalization)
    }

    private static func evaluate(
        kind: Kind,
        premise: Premise,
        bandIndex: Int?,
        parts: [Part],
        roundingScale: Int?,
        minimumPartCount: Int = 3,
        calculate: ([Decimal]) -> (expected: Decimal, actual: Decimal)
    ) -> Check {
        let indices = parts.flatMap(\.indices)
        guard parts.count >= minimumPartCount else {
            return Check(premise: premise, kind: kind, bandIndex: bandIndex, status: .unavailable,
                         candidateIndices: indices, expected: nil, actual: nil, difference: nil)
        }
        guard !parts.contains(where: \.ambiguous) else {
            return Check(premise: premise, kind: kind, bandIndex: bandIndex, status: .ambiguous,
                         candidateIndices: indices, expected: nil, actual: nil, difference: nil)
        }
        let numbers = parts.compactMap(\.value)
        guard numbers.count == parts.count else {
            return Check(premise: premise, kind: kind, bandIndex: bandIndex, status: .unavailable,
                         candidateIndices: indices, expected: nil, actual: nil, difference: nil)
        }
        let result = calculate(numbers)
        let difference = result.actual - result.expected
        let status: Status
        if difference == .zero {
            status = .exact
        } else if let roundingScale {
            var unrounded = result.expected
            var rounded = Decimal()
            NSDecimalRound(&rounded, &unrounded, roundingScale, .plain)
            status = rounded == result.actual ? .rounded : .mismatch
        } else {
            status = .mismatch
        }
        return Check(
            premise: premise,
            kind: kind,
            bandIndex: bandIndex,
            status: status,
            candidateIndices: indices,
            expected: NSDecimalNumber(decimal: result.expected).stringValue,
            actual: NSDecimalNumber(decimal: result.actual).stringValue,
            difference: NSDecimalNumber(decimal: difference).stringValue
        )
    }
}
