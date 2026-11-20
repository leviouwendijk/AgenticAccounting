import AgenticAccounting
import Foundation
import Testing

enum PDFInvoiceArithmeticRegression {
    typealias Assessment = PDFInvoiceArithmeticAssessment
    typealias Normalization = PDFInvoiceFinancialNormalization

    private static func fixture(_ fields: [(String, String)]) throws -> Normalization {
        let fingerprint = "fnv1a64:fixture"
        let candidates: [[String: Any]] = fields.enumerated().map { index, field in
            let (kind, raw) = field
            let lineID = "line-\(index)"
            let reference: [String: Any] = [
                "rootID": "project", "path": "invoice.pdf",
                "sourceFingerprint": fingerprint, "pageIndex": 0,
                "snapshotID": "native", "snapshotFingerprint": "fnv1a64:page",
                "startUTF16": 0, "endUTF16": raw.utf16.count
            ]
            return [
                "proposal": [
                    "field": kind,
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
            "sourceFingerprint": fingerprint,
            "proposedKind": "invoice",
            "candidates": candidates,
            "verifiedCitationCount": candidates.count,
            "unresolved": ["Document coverage not established"],
            "warnings": []
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let source = try JSONDecoder().decode(
            Accounting.Tools.VerifyPDFInvoiceEvidence.Output.self,
            from: data
        )
        return Normalization(source: source)
    }

    static func run() throws {
        let complete = try fixture([
            ("net_amount", "100.00"),
            ("vat_total", "21.00"),
            ("gross_amount", "121.00"),
            ("vat_base", "80.00"),
            ("vat_rate", "21%"),
            ("vat_amount", "16.80"),
            ("vat_base", "20.00"),
            ("vat_rate", "21%"),
            ("vat_amount", "4.20")
        ])
        let bands: [Assessment.VATBand] = [
            .init(baseIndex: 3, rateIndex: 4, amountIndex: 5),
            .init(baseIndex: 6, rateIndex: 7, amountIndex: 8)
        ]
        let assessed = try Assessment(
            normalization: complete,
            proposedBands: bands,
            claimedCompleteBandSet: true,
            roundingScale: 2
        )
        try Expect.equal(assessed.checks.map(\.kind), [
            .invoice_balance, .vat_band, .vat_band, .vat_bases_sum, .vat_amounts_sum
        ], "All declared relationships assessed")
        try Expect.equal(assessed.checks.map(\.status),
                         Array(repeating: .exact, count: 5), "Two-band invoice exact")
        try Expect.equal(assessed.checks.map(\.premise), [
            .extracted_totals, .proposed_band_association, .proposed_band_association,
            .claimed_band_coverage, .claimed_band_coverage
        ], "Arithmetic premise is never hidden")
        try Expect.equal(assessed.checks[0].expected, "121", "Net plus VAT expected")
        try Expect.equal(assessed.checks[0].actual, "121", "Gross actual")
        try Expect.equal(assessed.checks[1].candidateIndices, [3, 4, 5], "Band provenance")
        try Expect.equal(assessed.normalization.candidates[5].source.verifiedCitations.count,
                         1, "Original verified citations retained")
        let encoded = try JSONEncoder().encode(assessed)
        try Expect.equal(
            try JSONDecoder().decode(Assessment.self, from: encoded), assessed,
            "Assessment JSON roundtrip"
        )

        let partial = try Assessment(normalization: complete, proposedBands: [bands[0]])
        try Expect.equal(partial.checks.map(\.kind), [.invoice_balance, .vat_band],
                         "No automatic whole-invoice grouping from partial bands")
        try Expect.equal(partial.claimedCompleteBandSet, false, "Incomplete by default")

        let mismatch = try fixture([
            ("net_amount", "100.00"), ("vat_total", "21.00"),
            ("gross_amount", "122.00")
        ])
        let bad = try Assessment(normalization: mismatch)
        try Expect.equal(bad.checks[0].status, .mismatch, "Wrong gross rejected")
        try Expect.equal(bad.checks[0].difference, "1", "Signed discrepancy")

        let ambiguous = try fixture([
            ("net_amount", "1,234"), ("vat_total", "21.00"),
            ("gross_amount", "1255.00")
        ])
        try Expect.equal(try Assessment(normalization: ambiguous).checks[0].status,
                         .ambiguous, "Model convention selection not silently used")
        let repeated = try fixture([
            ("net_amount", "100.00"), ("net_amount", "100.00"),
            ("vat_total", "21.00"), ("gross_amount", "121.00")
        ])
        try Expect.equal(try Assessment(normalization: repeated).checks[0].status,
                         .ambiguous, "Repeated summary fields not silently collapsed")

        let rounded = try fixture([
            ("vat_base", "2.10"), ("vat_rate", "21%"),
            ("vat_amount", "0.44")
        ])
        let oneBand = [Assessment.VATBand(baseIndex: 0, rateIndex: 1, amountIndex: 2)]
        let explicitRounding = try Assessment(normalization: rounded,
                                              proposedBands: oneBand, roundingScale: 2)
        try Expect.equal(explicitRounding.checks[1].status, .rounded,
                         "VAT amount consistent only after explicit scale-2 rounding")
        try Expect.equal(explicitRounding.checks[1].expected, "0.441", "Exact expected tax")
        try Expect.equal(explicitRounding.checks[1].actual, "0.44", "Document tax")
        try Expect.equal(try Assessment(normalization: rounded,
                                        proposedBands: oneBand).checks[1].status,
                         .mismatch, "No automatic rounding assumption")
        try Expect.equal(try Assessment(normalization: rounded).checks[0].status,
                         .unavailable, "Missing invoice totals not manufactured")
        try Expect.equal(try Assessment(normalization: rounded,
                                        proposedBands: oneBand,
                                        claimedCompleteBandSet: true).checks.last?.status,
                         .unavailable, "Incomplete total remains unavailable")

        func fails(
            _ bands: [Assessment.VATBand],
            normalization: Normalization = complete,
            scale: Int? = nil,
            as expected: Assessment.Failure
        ) throws {
            do {
                _ = try Assessment(normalization: normalization,
                                   proposedBands: bands, roundingScale: scale)
                try Expect.equal(true, false, "Must reject \(expected)")
            } catch let actual as Assessment.Failure {
                try Expect.equal(actual, expected, "Specific invalid association")
            }
        }
        try fails([.init(baseIndex: 50, rateIndex: 4, amountIndex: 5)],
                  as: .invalid_candidate_index(50))
        try fails([.init(baseIndex: 4, rateIndex: 3, amountIndex: 5)],
                  as: .incorrect_field(4))
        try fails([bands[0], .init(baseIndex: 3, rateIndex: 7, amountIndex: 8)],
                  as: .repeated_base(3))
        try fails([bands[0], .init(baseIndex: 6, rateIndex: 7, amountIndex: 5)],
                  as: .repeated_amount(5))
        try fails([], scale: 9, as: .invalid_rounding_scale(9))
    }
}
