import Agentic
import AgenticAccounting
import Foundation
import Testing

public enum InvoiceBookingRegression {
    public static func run() async throws {
        try Expect.equal(InvoiceEntryPath.isValid("entries/2026/4/11/invoice-41.ec"), true,
                         "Canonical path accepted")
        try Expect.equal(InvoiceEntryPath.isValid("entries/2026/3/11/invoice.ec"), false,
                         "Incorrect quarter rejected")
        try Expect.equal(InvoiceEntryPath.isValid("entries/2026/4/11/../../ledger.ec"), false,
                         "Traversal rejected")
        let coverage = PDFInvoiceCoverage(sourceFingerprint: "fnv1a64:fixture", pageCount: 1, pages: [])
        let invoice = PDFInvoiceProcessingResult(coverage: coverage)
        let result = try await Accounting.Programs.PrepareInvoiceEntry().run(
            .init(
                invoice: invoice,
                targetPath: "entries/2026/4/11/invoice-41.ec",
                accountQuery: "expense",
                entityQuery: "supplier"
            ),
            in: ProgramContext()
        )
        try Expect.equal(result.reviewable, false, "Unverified invoice not draftable")
        try Expect.equal(result.source, nil, "No fabricated entry")
        try Expect.equal(Accounting.Inferences.DraftInvoiceEntry.definition.identifier.rawValue.isEmpty,
                         false, "Inference registered")
        let sample: [String: Any] = [
            "sourceFingerprint": "fnv1a64:fixture", "proposedKind": "invoice",
            "verifiedCitationCount": 0, "unresolved": [], "warnings": [],
            "candidates": [
                ["proposal": ["field": "gross_amount", "rawValue": "121.00", "citations": []],
                 "verifiedCitations": []],
                ["proposal": ["field": "currency", "rawValue": "EUR", "citations": []],
                 "verifiedCitations": []]
            ]
        ]
        let verified = try JSONDecoder().decode(
            Accounting.Tools.VerifyPDFInvoiceEvidence.Output.self,
            from: JSONSerialization.data(withJSONObject: sample)
        )
        let extraction = Accounting.Inferences.ExtractPDFInvoice.Output(
            kind: .invoice,
            candidates: [.init(field: .invoice_number, rawValue: "INV-41", citations: [])],
            unresolved: [], warnings: []
        )
        let interpreted = PDFInvoiceProcessingResult(
            coverage: coverage, extraction: extraction, verification: verified,
            normalization: PDFInvoiceFinancialNormalization(source: verified)
        )
        let matches = InvoicePaymentMatching.candidates(
            invoice: interpreted,
            payments: [
                .init(
                    sourceID: "bank-1",
                    sourceFingerprint: "bank-digest",
                    sourceKind: "bank",
                    grossAmount: "-121.00",
                    currency: "EUR",
                    reference: "INV-41"
                ),
                .init(
                    sourceID: "bank-2",
                    sourceFingerprint: "bank-digest",
                    sourceKind: "bank",
                    grossAmount: "-50.00",
                    currency: "EUR"
                ),
                .init(
                    sourceID: "bank-3",
                    sourceFingerprint: "bank-digest",
                    sourceKind: "bank",
                    grossAmount: "-121.00",
                    currency: "USD"
                )
            ]
        )
        try Expect.equal(matches.count, 1, "Matching currency and amount required")
        try Expect.equal(matches[0].referenceAgrees, true, "Reference corroboration")
        try Expect.equal(matches[0].status, "candidate_reference_and_amount",
                         "Not declared a settled payment")
        let scope = Accounting.Agents.InvoiceReviewer.capabilities.visible
        try Expect.equal(scope.programs.members.contains(
            Accounting.Programs.PrepareInvoiceEntry.definition.identifier
        ), true, "Preparation program exposed")
        try Expect.equal(scope.tools.members.contains(
            Accounting.Tools.ValidateEntryDraft.definition.identifier
        ), true, "Validation available")
    }
}
