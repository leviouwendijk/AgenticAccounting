import AgenticPDF
import Foundation

/// Checks an inference's claims against the supplied line observations.
/// This is not an authenticity check of the current PDF bytes: the resulting
/// references still require resolution against an authorized PDF snapshot.
public struct PDFInvoiceCitationResolution: Sendable, Hashable, Codable {
    public typealias Inference = Accounting.Inferences.ExtractPDFInvoice

    public struct Citation: Sendable, Hashable, Codable {
        public let lineID: String
        public let quote: String
        /// Original PDF line reference; not yet re-resolved against PDF bytes.
        public let lineReference: PDFEvidenceReference
        /// Quote offsets within the referenced page text snapshot (UTF-16).
        public let startUTF16: Int
        public let endUTF16: Int
    }

    public struct Candidate: Sendable, Hashable, Codable {
        /// Remains a proposal. In particular, normalizedValue is not verified.
        public let proposal: Inference.Output.Candidate
        public let citations: [Citation]
    }

    public enum Failure: Error, Sendable, Equatable {
        case empty_evidence
        case duplicate_line(String)
        case source_mismatch(String)
        case mixed_documents
        case no_source_binding
        case missing_citations(Inference.Output.Field)
        case missing_line(String)
        case missing_reference(String)
        case invalid_reference(String)
        case missing_text(String)
        case empty_quote(String)
        case unsupported_quote(String)
        case ambiguous_quote(String)
        case unsupported_raw_value(Inference.Output.Field)
    }

    public let rootID: String
    public let path: String
    public let sourceFingerprint: String
    public let proposedKind: Inference.Output.Kind
    public let candidates: [Candidate]
    public let unresolved: [String]
    public let warnings: [String]

    /// Throws rather than creating partially resolved citations.
    public init(evidence input: Inference.Input, proposal: Inference.Output) throws {
        guard !input.lines.isEmpty else { throw Failure.empty_evidence }

        var byID: [String: PDFLineEvidence] = [:]
        var document: (rootID: String, path: String)?
        for line in input.lines {
            guard !line.id.isEmpty, byID.updateValue(line, forKey: line.id) == nil else {
                throw Failure.duplicate_line(line.id)
            }
            guard let reference = line.reference else { continue }
            guard !input.sourceFingerprint.isEmpty,
                  reference.sourceFingerprint == input.sourceFingerprint else {
                throw Failure.source_mismatch(line.id)
            }
            guard !reference.rootID.isEmpty, !reference.path.isEmpty else {
                throw Failure.invalid_reference(line.id)
            }
            guard line.snapshotID == reference.snapshotID,
                  line.snapshotFingerprint == reference.snapshotFingerprint,
                  line.startUTF16 == reference.startUTF16,
                  line.endUTF16 == reference.endUTF16 else {
                throw Failure.invalid_reference(line.id)
            }
            if let document {
                guard document.rootID == reference.rootID,
                      document.path == reference.path else {
                    throw Failure.mixed_documents
                }
            } else {
                document = (reference.rootID, reference.path)
            }
        }
        guard let document else { throw Failure.no_source_binding }

        var resolved: [Candidate] = []
        for candidate in proposal.candidates {
            guard !candidate.citations.isEmpty else {
                throw Failure.missing_citations(candidate.field)
            }
            var citations: [Citation] = []
            for citation in candidate.citations {
                guard let line = byID[citation.lineID] else {
                    throw Failure.missing_line(citation.lineID)
                }
                guard let reference = line.reference else {
                    throw Failure.missing_reference(line.id)
                }
                guard let text = line.text else {
                    throw Failure.missing_text(line.id)
                }
                guard reference.startUTF16 >= 0,
                      reference.endUTF16 >= reference.startUTF16,
                      reference.endUTF16 - reference.startUTF16 == text.utf16.count else {
                    throw Failure.invalid_reference(line.id)
                }
                guard !citation.quote.isEmpty else {
                    throw Failure.empty_quote(line.id)
                }

                let source = text as NSString
                let first = source.range(of: citation.quote, options: .literal)
                guard first.location != NSNotFound else {
                    throw Failure.unsupported_quote(line.id)
                }
                let following = NSRange(
                    location: first.location + 1,
                    length: source.length - first.location - 1
                )
                guard source.range(of: citation.quote, options: .literal, range: following).location == NSNotFound else {
                    throw Failure.ambiguous_quote(line.id)
                }
                citations.append(.init(
                    lineID: line.id,
                    quote: citation.quote,
                    lineReference: reference,
                    startUTF16: reference.startUTF16 + first.location,
                    endUTF16: reference.startUTF16 + first.location + first.length
                ))
            }
            guard !candidate.rawValue.isEmpty,
                  citations.contains(where: {
                    ($0.quote as NSString).range(of: candidate.rawValue, options: .literal).location != NSNotFound
                  }) else {
                throw Failure.unsupported_raw_value(candidate.field)
            }
            resolved.append(.init(proposal: candidate, citations: citations))
        }

        self.rootID = document.rootID
        self.path = document.path
        self.sourceFingerprint = input.sourceFingerprint
        self.proposedKind = proposal.kind
        self.candidates = resolved
        self.unresolved = proposal.unresolved
        self.warnings = proposal.warnings
    }
}
