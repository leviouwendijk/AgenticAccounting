import AgenticAccounting
import AgenticPDF
import Foundation
import Testing

enum PDFInvoiceCitationRegression {
    typealias Inference = Accounting.Inferences.ExtractPDFInvoice
    typealias Resolution = PDFInvoiceCitationResolution

    private enum Failure: Error { case missing_citation }

    private static func line(
        id: String,
        text: String,
        fingerprint: String = "fnv1a64:document",
        path: String = "invoices/sample.pdf",
        anchored: Bool = true
    ) throws -> PDFLineEvidence {
        let start = 10
        var json: [String: Any] = [
            "id": id,
            "text": text,
            "origin": "native"
        ]
        if anchored {
            let reference: [String: Any] = [
                "rootID": "project",
                "path": path,
                "sourceFingerprint": fingerprint,
                "pageIndex": 0,
                "snapshotID": "native",
                "snapshotFingerprint": "fnv1a64:page",
                "startUTF16": start,
                "endUTF16": start + text.utf16.count
            ]
            json["reference"] = reference
            json["snapshotID"] = reference["snapshotID"]
            json["snapshotFingerprint"] = reference["snapshotFingerprint"]
            json["startUTF16"] = reference["startUTF16"]
            json["endUTF16"] = reference["endUTF16"]
        }
        return try JSONDecoder().decode(
            PDFLineEvidence.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
    }

    private static func proposal(
        field: Inference.Output.Field = .invoice_number,
        rawValue: String = "INV-2026-041",
        citations: [Inference.Output.Citation] = [
            .init(lineID: "page:0/line:0", quote: "INV-2026-041")
        ]
    ) -> Inference.Output {
        .init(
            kind: .invoice,
            candidates: [.init(
                field: field,
                rawValue: rawValue,
                normalizedValue: "unverified normalization",
                citations: citations
            )],
            unresolved: ["Coverage not established"],
            warnings: []
        )
    }

    private static func rejected(
        _ input: Inference.Input,
        _ output: Inference.Output
    ) -> Resolution.Failure? {
        do {
            _ = try Resolution(evidence: input, proposal: output)
            return nil
        } catch let failure as Resolution.Failure {
            return failure
        } catch {
            return nil
        }
    }

    static func run() throws {
        let lineText = "Invoice INV-2026-041"
        let first = try line(id: "page:0/line:0", text: lineText)
        let input = Inference.Input(
            sourceFingerprint: "fnv1a64:document",
            lines: [first]
        )
        let output = proposal()
        let resolved = try Resolution(evidence: input, proposal: output)
        guard let citation = resolved.candidates.first?.citations.first else {
            throw Failure.missing_citation
        }
        let offset = (lineText as NSString).range(of: "INV-2026-041").location
        try Expect.equal(citation.startUTF16, 10 + offset, "Quote begins at source-bound UTF-16 offset")
        try Expect.equal(citation.endUTF16, 10 + offset + "INV-2026-041".utf16.count, "Quote covers exact cited substring")
        try Expect.equal(citation.lineReference.path, "invoices/sample.pdf", "Workspace path retained")
        try Expect.equal(resolved.proposedKind, .invoice, "Kind remains proposed")
        try Expect.equal(resolved.unresolved, ["Coverage not established"], "No completeness claim")
        let data = try JSONEncoder().encode(resolved)
        let roundtrip = try JSONDecoder().decode(Resolution.self, from: data)
        try Expect.equal(roundtrip, resolved, "Resolved spans roundtrip")

        let missing = proposal(citations: [
            .init(lineID: "invented", quote: "INV-2026-041")
        ])
        try Expect.equal(rejected(input, missing), .missing_line("invented"), "Reject fabricated ID")
        try Expect.equal(rejected(input, proposal(citations: [])),
                         .missing_citations(.invoice_number), "No unsupported candidate")
        try Expect.equal(rejected(input, proposal(rawValue: "invented")),
                         .unsupported_raw_value(.invoice_number), "Raw value must appear in cited quote")
        try Expect.equal(rejected(input, proposal(citations: [
            .init(lineID: "page:0/line:0", quote: "not in PDF")
        ])), .unsupported_quote("page:0/line:0"), "No invented quote")

        let repeatLine = try line(id: "page:0/line:0", text: "Invoice INV Invoice INV")
        let repeatInput = Inference.Input(sourceFingerprint: "fnv1a64:document", lines: [repeatLine])
        try Expect.equal(rejected(repeatInput, proposal(rawValue: "INV", citations: [
            .init(lineID: "page:0/line:0", quote: "INV")
        ])), .ambiguous_quote("page:0/line:0"), "Repeated quote needs disambiguation")

        let unanchored = try line(id: "page:0/line:1", text: "Fee", anchored: false)
        let combined = Inference.Input(sourceFingerprint: "fnv1a64:document", lines: [first, unanchored])
        try Expect.equal(rejected(combined, proposal(rawValue: "Fee", citations: [
            .init(lineID: "page:0/line:1", quote: "Fee")
        ])), .missing_reference("page:0/line:1"), "Do not cite an unanchored line")

        let noCandidates = Inference.Output(
            kind: .undetermined,
            candidates: [],
            unresolved: ["Missing required source information"],
            warnings: []
        )
        let emptyResolution = try Resolution(evidence: input, proposal: noCandidates)
        try Expect.equal(emptyResolution.candidates.isEmpty, true, "No invented invoice claims")
        try Expect.equal(emptyResolution.unresolved.count, 1, "Unresolved evidence retained")

        let absent = try line(id: "page:0/line:0", text: lineText, anchored: false)
        try Expect.equal(rejected(.init(sourceFingerprint: "fnv1a64:document", lines: [absent]), output),
                         .no_source_binding, "No fabricated source binding")
        let inconsistent = try line(id: "page:0/line:0", text: lineText, fingerprint: "fnv1a64:other")
        try Expect.equal(rejected(.init(sourceFingerprint: "fnv1a64:document", lines: [inconsistent]), output),
                         .source_mismatch("page:0/line:0"), "Reject mismatched document")
        try Expect.equal(rejected(.init(sourceFingerprint: "fnv1a64:document", lines: [first, first]), output),
                         .duplicate_line("page:0/line:0"), "Reject ambiguous line IDs")
        let other = try line(id: "page:0/line:1", text: "Total EUR 100", path: "invoices/other.pdf")
        try Expect.equal(rejected(.init(sourceFingerprint: "fnv1a64:document", lines: [first, other]), output),
                         .mixed_documents, "Reject mixed workspace sources")
        try Expect.equal(rejected(.init(sourceFingerprint: "fnv1a64:document", lines: []), output),
                         .empty_evidence, "Empty input is not verifiable")
    }
}
