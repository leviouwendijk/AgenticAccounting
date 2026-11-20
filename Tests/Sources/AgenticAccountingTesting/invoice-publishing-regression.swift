import Agentic
import AgenticAccounting
import AgenticIO
import Foundation
import Testing

public enum InvoicePublishingRegression {
    public static func run() async throws {
        let coverage = PDFInvoiceCoverage(sourceFingerprint: "fnv1a64:fixture", pageCount: 1, pages: [])
        let empty = AccountingInvoiceEntryDraft(
            invoice: PDFInvoiceProcessingResult(coverage: coverage),
            targetPath: "entries/2026/4/11/invoice-41.ec"
        )
        var rejected = false
        do {
            _ = try await Accounting.Programs.PublishInvoiceEntry().run(
                .init(draft: empty), in: ProgramContext()
            )
        } catch Accounting.Programs.PublishInvoiceEntry.Failure.unreviewable_draft {
            rejected = true
        }
        try Expect.equal(rejected, true, "Unreviewed draft blocked")
        try Expect.equal(try InvoiceEntryIDInspection.ids(
            in: "entry {\n id = 41\n id = 42\n }"
        ), [41, 42], "Entry IDs inspected")
        let scope = Accounting.Agents.InvoicePoster.capabilities.visible
        try Expect.equal(scope.programs.members.contains(
            Accounting.Programs.PublishInvoiceEntry.definition.identifier
        ), true, "Posting program exposed")
        try Expect.equal(scope.tools.members.contains(
            SystemIO.Tools.MutateFiles.definition.identifier
        ), true, "Governed mutation tool exposed")
        try Expect.equal(Accounting.Agents.InvoiceReviewer.capabilities.visible.tools.members.contains(
            SystemIO.Tools.MutateFiles.definition.identifier
        ), false, "Reviewer remains read-only")
    }
}
