import Agentic
import AgenticAccounting
import AgenticPDF
import CoreGraphics
import CoreText
import Foundation
import Path
import Testing
import Workspace

private enum InvoiceEngineTestFailure: Error {
    case unexpectedTool
    case unexpectedInference
    case noInvoiceLine
    case pdfCreation
}

private struct InvoiceEngineToolAdapter: ProgramToolInvoking {
    let context: ToolContext

    func invoke<Input: Encodable & Sendable, Output: Decodable & Sendable>(
        _ identifier: ToolIdentifier, input: Input, as output: Output.Type
    ) async throws -> Output {
        let payload = try JSONEncoder().encode(input)
        let encoded: Data
        switch identifier {
        case PDF.Tools.ReadDocument.definition.identifier:
            let decoded = try JSONDecoder().decode(PDF.Tools.ReadDocument.Input.self, from: payload)
            encoded = try JSONEncoder().encode(try await PDF.Tools.ReadDocument().call(decoded, in: context))
        case PDF.Tools.InspectPage.definition.identifier:
            let decoded = try JSONDecoder().decode(PDF.Tools.InspectPage.Input.self, from: payload)
            encoded = try JSONEncoder().encode(try await PDF.Tools.InspectPage().call(decoded, in: context))
        case Accounting.Tools.VerifyPDFInvoiceEvidence.definition.identifier:
            let decoded = try JSONDecoder().decode(Accounting.Tools.VerifyPDFInvoiceEvidence.Input.self, from: payload)
            encoded = try JSONEncoder().encode(try await Accounting.Tools.VerifyPDFInvoiceEvidence().call(decoded, in: context))
        default:
            throw InvoiceEngineTestFailure.unexpectedTool
        }
        return try JSONDecoder().decode(Output.self, from: encoded)
    }
}

private actor InvoiceEngineInferenceAdapter: InferenceInvoking {
    private var invoked: [String] = []

    func infer<ProgramType: Program, InferenceType: Inference>(
        _ site: InferenceSite<ProgramType, InferenceType>, input: InferenceType.Input
    ) async throws -> InferenceType.Output {
        invoked.append(site.inference.rawValue)
        guard site.inference == Accounting.Inferences.ExtractPDFInvoice.definition.identifier else {
            throw InvoiceEngineTestFailure.unexpectedInference
        }
        let typed = try JSONDecoder().decode(
            Accounting.Inferences.ExtractPDFInvoice.Input.self,
            from: JSONEncoder().encode(input)
        )
        guard let line = typed.lines.first(where: { $0.text?.contains("INV-041") == true }) else {
            throw InvoiceEngineTestFailure.noInvoiceLine
        }
        let output = Accounting.Inferences.ExtractPDFInvoice.Output(
            kind: .invoice,
            candidates: [
                .init(field: .invoice_number, rawValue: "INV-041",
                      citations: [.init(lineID: line.id, quote: "INV-041")]),
                .init(field: .gross_amount, rawValue: "100.00",
                      citations: [.init(lineID: line.id, quote: "100.00")])
            ],
            unresolved: ["VAT treatment not established"], warnings: []
        )
        return try JSONDecoder().decode(InferenceType.Output.self, from: JSONEncoder().encode(output))
    }

    func calls() -> [String] { invoked }
}

enum PDFInvoiceEngineRegression {
    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "accounting-invoice-engine-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("invoice.pdf")
        try makePDF(["INVOICE INV-041 TOTAL 100.00", "TERMS PAGE TWO"]).write(to: file)
        let tools = try InvoiceEngineToolAdapter(context: context(root: directory, capabilities: [.read]))
        let inferences = InvoiceEngineInferenceAdapter()
        let program = Accounting.Programs.ProcessPDFInvoice()
        let result = try await program.run(
            .init(path: "invoice.pdf"),
            in: ProgramContext(inference: inferences, tools: tools)
        )
        try Expect.equal(result.coverage.pageCount, 2, "Read every page")
        try Expect.equal(result.coverage.metadataComplete, true, "Page metadata complete")
        try Expect.equal(result.coverage.allSelectedLinesCollected, true, "All selected page lines enumerated")
        try Expect.equal(result.coverage.hasUnavailableText, false, "Two text pages")
        try Expect.equal(result.verification?.verifiedCitationCount, 2, "Both citations rechecked against PDF")
        try Expect.equal(result.normalization?.candidates[1].value, "100", "Deterministic decimal parsing")
        try Expect.equal(result.conventionResolution == nil, true, "No unnecessary convention inference")
        try Expect.equal(result.vatBandResolution == nil, true, "No VAT grouping without VAT fields")
        try Expect.equal(await inferences.calls(),
                         [Accounting.Inferences.ExtractPDFInvoice.definition.identifier.rawValue],
                         "Only extraction inference invoked")
        try Expect.equal(result.unresolved, ["VAT treatment not established"], "Unresolved evidence retained")
        let data = try JSONEncoder().encode(result)
        try Expect.equal(try JSONDecoder().decode(PDFInvoiceProcessingResult.self, from: data), result,
                         "Complete PDF evidence roundtrip")
        try Expect.equal(Accounting.Programs.ProcessPDFInvoice.definition.identifier.rawValue.isEmpty, false,
                         "Program definition registered")
        try Expect.equal(Accounting.Inferences.AssociateInvoiceVATBands.definition.identifier.rawValue.isEmpty, false,
                         "VAT inference registered")

        var denied = false
        do {
            let scanOnly = try InvoiceEngineToolAdapter(context: context(root: directory, capabilities: [.scan]))
            _ = try await program.run(.init(path: "invoice.pdf"),
                                      in: ProgramContext(inference: inferences, tools: scanOnly))
        } catch { denied = true }
        try Expect.equal(denied, true, "Source read permission enforced inside program")
    }

    private static func context(root: URL, capabilities: Set<WorkspaceCapability>) throws -> ToolContext {
        let root = PathAccessRoot(id: .project, label: "Invoice program fixture",
                                  scope: try PathAccessScope(root: root, policy: .defaults.workspace),
                                  isDefault: true)
        let grant = try WorkspaceGrant(id: WorkspaceGrantIdentifier("invoice-engine-fixture"),
                                       rootIdentifier: .project, capabilities: capabilities)
        let workspace = try Workspace(root: root, grants: [grant])
        return ToolContext(workspace: try workspace.context(execution: .init(io: .blocking, mutations: .immediate)))
    }

    private static func makePDF(_ pages: [String]) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { throw InvoiceEngineTestFailure.pdfCreation }
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let pdf = CGContext(consumer: consumer, mediaBox: &bounds, nil) else {
            throw InvoiceEngineTestFailure.pdfCreation
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        for content in pages {
            let text = NSAttributedString(string: content, attributes: [
                NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font
            ])
            pdf.beginPDFPage(nil)
            pdf.textPosition = CGPoint(x: 60, y: 690)
            CTLineDraw(CTLineCreateWithAttributedString(text), pdf)
            pdf.endPDFPage()
        }
        pdf.closePDF()
        return data as Data
    }
}
