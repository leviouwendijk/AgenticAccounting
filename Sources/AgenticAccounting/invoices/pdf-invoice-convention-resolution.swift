import Foundation

/// Checks that inferred selections exactly belong to the deterministic parse
/// alternatives and that cited support comes from the supplied PDF evidence.
/// A validated selection is still a model proposal, not arithmetic proof.
public struct PDFInvoiceConventionResolution: Sendable, Hashable, Codable {
    public typealias Normalization = PDFInvoiceFinancialNormalization
    public typealias Inference = Accounting.Inferences.InferInvoiceConventions

    public struct Selection: Sendable, Hashable, Codable {
        public let candidateIndex: Int
        public let interpretation: Normalization.Interpretation
        /// Actual source-bound candidates, never model-created references.
        public let supportingEvidence: [Normalization.Candidate]
        public let rationale: String
    }

    public enum Failure: Error, Sendable, Equatable {
        case input_mismatch
        case source_mismatch
        case invalid_candidate_index(Int)
        case non_ambiguous_selection(Int)
        case duplicate_candidate(Int)
        case unsupported_interpretation(Int)
        case no_support(Int)
        case invalid_support(Int)
        case repeated_support(Int)
        case missing_rationale(Int)
        case missing_disposition(Int)
    }

    public let normalization: Normalization
    public let selections: [Selection]
    public let unresolvedCandidateIndices: [Int]
    public let inferenceWarnings: [String]

    public init(
        normalization: Normalization,
        input: Inference.Input,
        proposal: Inference.Output
    ) throws {
        guard input == Inference.Input(normalization: normalization) else {
            throw Failure.input_mismatch
        }
        guard proposal.sourceFingerprint == normalization.sourceFingerprint else {
            throw Failure.source_mismatch
        }

        let ambiguous = Set(normalization.candidates.indices.filter {
            normalization.candidates[$0].status == .ambiguous
        })
        var handled = Set<Int>()
        var accepted: [Selection] = []

        for selection in proposal.selections {
            let index = selection.candidateIndex
            guard normalization.candidates.indices.contains(index) else {
                throw Failure.invalid_candidate_index(index)
            }
            guard ambiguous.contains(index) else {
                throw Failure.non_ambiguous_selection(index)
            }
            guard handled.insert(index).inserted else {
                throw Failure.duplicate_candidate(index)
            }
            guard let interpretation = normalization.candidates[index].alternatives.first(where: {
                $0.convention.rawValue == selection.convention && $0.value == selection.value
            }) else {
                throw Failure.unsupported_interpretation(index)
            }
            guard !selection.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Failure.missing_rationale(index)
            }
            guard !selection.supportingCandidateIndices.isEmpty else {
                throw Failure.no_support(index)
            }

            var seenSupport = Set<Int>()
            var evidence: [Normalization.Candidate] = []
            for support in selection.supportingCandidateIndices {
                guard support != index, normalization.candidates.indices.contains(support),
                      !normalization.candidates[support].source.verifiedCitations.isEmpty else {
                    throw Failure.invalid_support(support)
                }
                guard seenSupport.insert(support).inserted else {
                    throw Failure.repeated_support(support)
                }
                evidence.append(normalization.candidates[support])
            }
            accepted.append(.init(
                candidateIndex: index,
                interpretation: interpretation,
                supportingEvidence: evidence,
                rationale: selection.rationale
            ))
        }

        for index in proposal.unresolvedCandidateIndices {
            guard normalization.candidates.indices.contains(index) else {
                throw Failure.invalid_candidate_index(index)
            }
            guard ambiguous.contains(index) else {
                throw Failure.non_ambiguous_selection(index)
            }
            guard handled.insert(index).inserted else {
                throw Failure.duplicate_candidate(index)
            }
        }
        guard handled == ambiguous else {
            if let missing = ambiguous.subtracting(handled).min() {
                throw Failure.missing_disposition(missing)
            }
            throw Failure.input_mismatch
        }

        self.normalization = normalization
        self.selections = accepted
        self.unresolvedCandidateIndices = proposal.unresolvedCandidateIndices
        self.inferenceWarnings = proposal.warnings
    }
}
