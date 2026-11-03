import Agentic
import AgenticAccounting
import AgenticPDF
import CoreGraphics
import CoreText
import Foundation
import Path
import Testing
import Workspace

enum PDFInvoiceSourceVerificationRegression {
    private enum Failure: Error {
        case fixture(String)
    }

    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "accounting-pdf-verification-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("invoice.pdf")
        try makePDF("INVOICE INV-2026-041 TOTAL 100.00").write(to: source)

        let context = try makeContext(root: directory, capabilities: [.read])
        let summary = try await PDF.Tools.ReadDocument().call(.init(path: "invoice.pdf"), in: context)
        let page = try await PDF.Tools.InspectPage().call(.init(
            path: "invoice.pdf", pageIndex: 0,
            expectedFingerprint: summary.sourceFingerprint
        ), in: context)
        guard let line = page.lines.first(where: {
            $0.text?.contains("INV-2026-041") == true && $0.reference != nil
        }) else { throw Failure.fixture("invoice reference") }

        typealias Inference = Accounting.Inferences.ExtractPDFInvoice
        let evidence = Inference.Input(sourceFingerprint: summary.sourceFingerprint, lines: [line])
        let claim = Inference.Output.Citation(lineID: line.id, quote: "INV-2026-041")
        let proposal = Inference.Output(
            kind: .invoice,
            candidates: [.init(
                field: .invoice_number,
                rawValue: "INV-2026-041",
                normalizedValue: "unverified proposal",
                citations: [claim]
            )],
            unresolved: ["Document coverage not established"],
            warnings: []
        )
        let input = Accounting.Tools.VerifyPDFInvoiceEvidence.Input(evidence: evidence, proposal: proposal)
        let tool = Accounting.Tools.VerifyPDFInvoiceEvidence()
        try Expect.equal(
            Accounting.Tools.VerifyPDFInvoiceEvidence.definition.identifier.rawValue,
            "accounting_verify_pdf_invoice_evidence",
            "Tool identifier"
        )
        let preflight = try await tool.preflight(input, in: context)
        try Expect.equal(preflight.tool, Accounting.Tools.VerifyPDFInvoiceEvidence.definition.identifier,
                         "Preflight must identify the accounting wrapper")
        try Expect.equal(preflight.risk, .observe, "Verification is read-only")
        try Expect.equal(preflight.access.capabilities.contains(.read), true, "PDF read access in preflight")

        let result = try await tool.call(input, in: context)
        try Expect.equal(result.verifiedCitationCount, 1, "All citations verified")
        try Expect.equal(result.candidates[0].verifiedCitations[0].quote, "INV-2026-041", "Exact PDF quote")
        try Expect.equal(result.candidates[0].proposal.normalizedValue,
                         "unverified proposal", "No automatic financial normalization")
        try Expect.equal(result.unresolved, ["Document coverage not established"], "Coverage remains unknown")
        let encoded = try JSONEncoder().encode(result)
        try Expect.equal(try JSONDecoder().decode(Accounting.Tools.VerifyPDFInvoiceEvidence.Output.self, from: encoded),
                         result, "Verification result JSON roundtrip")

        let multi = Inference.Output(
            kind: .invoice,
            candidates: [.init(
                field: .invoice_number,
                rawValue: "INV-2026-041",
                citations: Array(repeating: claim, count: 129)
            )],
            unresolved: [], warnings: []
        )
        let batched = try await tool.call(.init(evidence: evidence, proposal: multi), in: context)
        try Expect.equal(batched.verifiedCitationCount, 129, "More than 128 verified without cropping")
        try Expect.equal(batched.candidates[0].verifiedCitations.count, 129, "Every citation retained")

        var rejectedUnauthorized = false
        do {
            let scanOnly = try makeContext(root: directory, capabilities: [.scan])
            _ = try await tool.preflight(input, in: scanOnly)
        } catch { rejectedUnauthorized = true }
        try Expect.equal(rejectedUnauthorized, true, "No read authorization bypass")

        let invented = Inference.Output(
            kind: .invoice,
            candidates: [.init(
                field: .invoice_number,
                rawValue: "INV-2026-041",
                citations: [.init(lineID: "invented", quote: "INV-2026-041")]
            )],
            unresolved: [], warnings: []
        )
        var rejectedFabrication = false
        do { _ = try await tool.call(.init(evidence: evidence, proposal: invented), in: context) }
        catch PDFInvoiceCitationResolution.Failure.missing_line { rejectedFabrication = true }
        try Expect.equal(rejectedFabrication, true, "Fabricated citation rejected")

        try makePDF("REVISED INVOICE INV-2026-041 TOTAL 100.00").write(to: source, options: .atomic)
        var rejectedStale = false
        do { _ = try await tool.call(input, in: context) }
        catch PDF.Tools.VerifyTextEvidence.Failure.source_mismatch { rejectedStale = true }
        try Expect.equal(rejectedStale, true, "Changed document cannot verify old claims")
    }

    private static func makeContext(
        root: URL,
        capabilities: Set<WorkspaceCapability>
    ) throws -> ToolContext {
        let installed = PathAccessRoot(
            id: .project,
            label: "Invoice fixture",
            scope: try PathAccessScope(root: root, policy: .defaults.workspace),
            isDefault: true
        )
        let grant = try WorkspaceGrant(
            id: WorkspaceGrantIdentifier("invoice-verification-fixture"),
            rootIdentifier: .project,
            capabilities: capabilities
        )
        let workspace = try Workspace(root: installed, grants: [grant])
        return ToolContext(workspace: try workspace.context(
            execution: .init(io: .blocking, mutations: .immediate)
        ))
    }

    private static func makePDF(_ source: String) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw Failure.fixture("PDF consumer")
        }
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let pdf = CGContext(consumer: consumer, mediaBox: &bounds, nil) else {
            throw Failure.fixture("PDF context")
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let text = NSAttributedString(string: source, attributes: [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font
        ])
        pdf.beginPDFPage(nil)
        pdf.textPosition = CGPoint(x: 60, y: 690)
        CTLineDraw(CTLineCreateWithAttributedString(text), pdf)
        pdf.endPDFPage()
        pdf.closePDF()
        return data as Data
    }
}
