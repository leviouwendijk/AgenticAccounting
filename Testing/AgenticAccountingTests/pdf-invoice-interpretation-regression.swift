import AgenticAccounting
import Foundation
import Testing

private enum PDFInvoiceEngineFixture {
    static func normalize(_ fields: [(String, String)]) throws -> PDFInvoiceFinancialNormalization {
        let fingerprint = "fnv1a64:fixture"
        let candidates: [[String: Any]] = fields.enumerated().map { index, field in
            let (kind, raw) = field
            let lineID = "fixture-line-\(index)"
            let reference: [String: Any] = [
                "rootID": "project", "path": "fixture.pdf", "sourceFingerprint": fingerprint,
                "pageIndex": 0, "snapshotID": "native", "snapshotFingerprint": "fnv1a64:page",
                "startUTF16": 0, "endUTF16": raw.utf16.count
            ]
            return [
                "proposal": ["field": kind, "rawValue": raw,
                             "citations": [["lineID": lineID, "quote": raw]]],
                "verifiedCitations": [["lineID": lineID, "lineReference": reference,
                                       "quote": raw, "startUTF16": 0, "endUTF16": raw.utf16.count]]
            ]
        }
        let source: [String: Any] = [
            "sourceFingerprint": fingerprint, "proposedKind": "invoice",
            "candidates": candidates, "verifiedCitationCount": candidates.count,
            "unresolved": [], "warnings": []
        ]
        return PDFInvoiceFinancialNormalization(source: try JSONDecoder().decode(
            Accounting.Tools.VerifyPDFInvoiceEvidence.Output.self,
            from: JSONSerialization.data(withJSONObject: source)
        ))
    }
}

enum PDFInvoiceInterpretationRegression {
    typealias Associator = Accounting.Inferences.AssociateInvoiceVATBands

    static func run() throws {
        let source = try PDFInvoiceEngineFixture.normalize([
            ("net_amount", "100.00"), ("vat_total", "21.00"), ("gross_amount", "121.00"),
            ("vat_base", "80.00"), ("vat_rate", "21%"), ("vat_amount", "16.80"),
            ("vat_base", "20.00"), ("vat_amount", "4.20")
        ])
        let input = Associator.Input(normalization: source)
        let proposal = Associator.Output(
            sourceFingerprint: source.sourceFingerprint,
            bands: [
                .init(baseIndex: 3, rateIndex: 4, amountIndex: 5, rationale: "VAT row one"),
                .init(baseIndex: 6, rateIndex: 4, amountIndex: 7, rationale: "VAT row two")
            ],
            unassignedBaseIndices: [], unassignedAmountIndices: [],
            claimedCompleteBandSet: true
        )
        let checked = try PDFInvoiceVATBandResolution(normalization: source, input: input, proposal: proposal)
        try Expect.equal(checked.proposedBands.count, 2, "Shared rate reference allowed")
        let assessed = try PDFInvoiceArithmeticAssessment(
            normalization: source, proposedBands: checked.proposedBands,
            claimedCompleteBandSet: checked.proposal.claimedCompleteBandSet,
            roundingScale: 2
        )
        try Expect.equal(assessed.checks.allSatisfy { $0.status == .exact }, true,
                         "Explicitly associated VAT rows reconcile")
        let encoded = try JSONEncoder().encode(checked)
        try Expect.equal(try JSONDecoder().decode(PDFInvoiceVATBandResolution.self, from: encoded), checked,
                         "Band resolution preserves source evidence")

        func mustFail(_ output: Associator.Output) throws {
            var failed = false
            do { _ = try PDFInvoiceVATBandResolution(normalization: source, input: input, proposal: output) }
            catch { failed = true }
            try Expect.equal(failed, true, "Invalid band assignment must fail")
        }
        try mustFail(.init(sourceFingerprint: source.sourceFingerprint,
                           bands: [proposal.bands[0]], unassignedBaseIndices: [],
                           unassignedAmountIndices: [], claimedCompleteBandSet: false))
        try mustFail(.init(sourceFingerprint: source.sourceFingerprint,
                           bands: [.init(baseIndex: 4, rateIndex: 3, amountIndex: 5,
                                         rationale: "incorrect roles")],
                           unassignedBaseIndices: [6], unassignedAmountIndices: [7],
                           claimedCompleteBandSet: false))
        try mustFail(.init(sourceFingerprint: source.sourceFingerprint,
                           bands: [proposal.bands[0], proposal.bands[0]],
                           unassignedBaseIndices: [6], unassignedAmountIndices: [7],
                           claimedCompleteBandSet: false))
        try mustFail(.init(sourceFingerprint: "changed", bands: proposal.bands,
                           unassignedBaseIndices: [], unassignedAmountIndices: [],
                           claimedCompleteBandSet: true))

        let unique = try PDFInvoiceEngineFixture.normalize([
            ("net_amount", "1,234"), ("vat_total", "21.00"), ("gross_amount", "1255.00")
        ])
        let solved = try PDFInvoiceArithmeticDisambiguation(normalization: unique)
        try Expect.equal(solved.status, .unique_solution, "One mathematically consistent number interpretation")
        try Expect.equal(solved.uniqueChoices.first?.value, "1234", "Unique alternative retained")
        try Expect.equal(unique.candidates[0].status, .ambiguous, "Original normalization unchanged")

        let conflicting = try PDFInvoiceEngineFixture.normalize([
            ("net_amount", "1,234"), ("vat_total", "21.00"), ("gross_amount", "1256.00")
        ])
        try Expect.equal(try PDFInvoiceArithmeticDisambiguation(normalization: conflicting).status,
                         .no_consistent_solution, "Contradictory totals are reported")
        let multiple = try PDFInvoiceEngineFixture.normalize([
            ("net_amount", "1,234"), ("vat_total", "0.00"), ("gross_amount", "1,234")
        ])
        try Expect.equal(try PDFInvoiceArithmeticDisambiguation(normalization: multiple).status,
                         .multiple_solutions, "Multiple consistent meanings remain unresolved")
        try Expect.equal(try PDFInvoiceArithmeticDisambiguation(
            normalization: multiple, maximumCombinations: 2
        ).status, .bounded, "Combinatorial bound never truncates silently")
        let unavailable = try PDFInvoiceEngineFixture.normalize([("vat_base", "1,234")])
        try Expect.equal(try PDFInvoiceArithmeticDisambiguation(normalization: unavailable).status,
                         .unavailable, "Missing equations cannot determine a value")
    }
}
