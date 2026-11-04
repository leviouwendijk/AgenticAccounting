import AgenticAccounting
import Foundation
import Testing

enum PDFInvoiceConventionRegression {
    typealias Inference = Accounting.Inferences.InferInvoiceConventions
    typealias Normalization = PDFInvoiceFinancialNormalization
    typealias Resolution = PDFInvoiceConventionResolution

    private static func fixture() throws -> Normalization {
        // Pure contract fixture: independent of an actual PDF read. Source
        // authenticity is exercised by the existing source-verification tests.
        let sourceFingerprint = "fnv1a64:fixture"
        let records: [(String, String)] = [
            ("gross_amount", "1,234"),
            ("vat_amount", "1234.56")
        ]
        let candidates: [[String: Any]] = records.enumerated().map { index, pair in
            let (field, raw) = pair
            let lineID = "fixture-line-\(index)"
            let reference: [String: Any] = [
                "rootID": "project", "path": "fixture.pdf",
                "sourceFingerprint": sourceFingerprint, "pageIndex": 0,
                "snapshotID": "native", "snapshotFingerprint": "fnv1a64:page",
                "startUTF16": 0, "endUTF16": raw.utf16.count
            ]
            return [
                "proposal": [
                    "field": field,
                    "rawValue": raw,
                    "citations": [["lineID": lineID, "quote": raw]]
                ],
                "verifiedCitations": [[
                    "lineID": lineID,
                    "lineReference": reference,
                    "quote": raw,
                    "startUTF16": 0,
                    "endUTF16": raw.utf16.count
                ]]
            ]
        }
        let json: [String: Any] = [
            "sourceFingerprint": sourceFingerprint,
            "proposedKind": "invoice",
            "candidates": candidates,
            "verifiedCitationCount": records.count,
            "unresolved": ["Invoice completeness unknown"],
            "warnings": []
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let source = try JSONDecoder().decode(
            Accounting.Tools.VerifyPDFInvoiceEvidence.Output.self, from: data
        )
        return Normalization(source: source)
    }

    static func run() throws {
        let normalized = try fixture()
        try Expect.equal(normalized.candidates[0].status, .ambiguous, "Ambiguous amount retained")
        try Expect.equal(normalized.candidates[1].status, .resolved, "Independent support value")
        let input = Inference.Input(normalization: normalized)
        try Expect.equal(input.evidence.count, 2, "Every candidate presented")
        try Expect.equal(input.evidence[0].alternatives.map(\.value), ["1.234", "1234"], "Only existing alternatives")
        try Expect.equal(input.evidence[1].citations.count, 1, "Source-bound support passed through")
        let encoded = try JSONEncoder().encode(input)
        try Expect.equal(try JSONDecoder().decode(Inference.Input.self, from: encoded), input,
                         "Typed inference input JSON roundtrip")
        try Expect.equal(Inference.definition.identifier.rawValue.isEmpty, false,
                         "Inference definition exists")

        func result(
            _ value: String,
            convention: String = "decimal_dot",
            supports: [Int] = [1],
            indices: [Int] = [],
            fingerprint: String? = nil,
            rationale: String = "Another amount uses this notation"
        ) -> Inference.Output {
            .init(
                sourceFingerprint: fingerprint ?? normalized.sourceFingerprint,
                selections: [.init(
                    candidateIndex: 0,
                    convention: convention,
                    value: value,
                    supportingCandidateIndices: supports,
                    rationale: rationale
                )],
                unresolvedCandidateIndices: indices
            )
        }

        let accepted = try Resolution(normalization: normalized, input: input,
                                      proposal: result("1234"))
        try Expect.equal(accepted.selections[0].interpretation.value, "1234", "Chosen value is an existing option")
        try Expect.equal(accepted.selections[0].supportingEvidence[0].source.verifiedCitations,
                         normalized.candidates[1].source.verifiedCitations,
                         "Support uses original PDF citations")
        try Expect.equal(accepted.normalization.candidates[0].status, .ambiguous,
                         "Model selection does not rewrite deterministic status")
        let checked = try JSONEncoder().encode(accepted)
        try Expect.equal(try JSONDecoder().decode(Resolution.self, from: checked), accepted,
                         "Resolution JSON roundtrip")

        let unresolved = try Resolution(normalization: normalized, input: input, proposal: .init(
            sourceFingerprint: normalized.sourceFingerprint,
            selections: [],
            unresolvedCandidateIndices: [0]
        ))
        try Expect.equal(unresolved.unresolvedCandidateIndices, [0], "Explicit deferral accepted")

        func fails(_ proposal: Inference.Output, as expected: Resolution.Failure) throws {
            do {
                _ = try Resolution(normalization: normalized, input: input, proposal: proposal)
                try Expect.equal(true, false, "Must reject \(expected)")
            } catch let found as Resolution.Failure {
                try Expect.equal(found, expected, "Specific failure classification")
            }
        }
        try fails(result("9999"), as: .unsupported_interpretation(0))
        try fails(result("1234", convention: "decimal_comma"), as: .unsupported_interpretation(0))
        try fails(result("1234", supports: []), as: .no_support(0))
        try fails(result("1234", supports: [0]), as: .invalid_support(0))
        try fails(result("1234", supports: [10]), as: .invalid_support(10))
        try fails(result("1234", supports: [1, 1]), as: .repeated_support(1))
        try fails(result("1234", fingerprint: "other"), as: .source_mismatch)
        try fails(result("1234", indices: [0]), as: .duplicate_candidate(0))
        try fails(result("1234", rationale: "  "), as: .missing_rationale(0))
        try fails(.init(sourceFingerprint: normalized.sourceFingerprint,
                        selections: [], unresolvedCandidateIndices: []),
                  as: .missing_disposition(0))
        try fails(.init(sourceFingerprint: normalized.sourceFingerprint,
                        selections: [.init(candidateIndex: 1, convention: "decimal_dot",
                                           value: "1234.56", supportingCandidateIndices: [0],
                                           rationale: "Not ambiguous")],
                        unresolvedCandidateIndices: [0]),
                  as: .non_ambiguous_selection(1))

        guard var payload = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              var evidence = payload["evidence"] as? [[String: Any]] else {
            throw Resolution.Failure.input_mismatch
        }
        evidence[0]["rawValue"] = "fabricated raw text"
        payload["evidence"] = evidence
        let altered = try JSONDecoder().decode(
            Inference.Input.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
        do {
            _ = try Resolution(normalization: normalized, input: altered,
                               proposal: result("1234"))
            try Expect.equal(true, false, "Changed inference input must fail")
        } catch Resolution.Failure.input_mismatch {
            // Expected.
        }
    }
}
