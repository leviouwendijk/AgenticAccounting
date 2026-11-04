import Agentic
import AgenticIO
import AgenticPDF
import Schema

public extension Accounting.Agents {
    @Agent
    enum InvoicePoster {
        public typealias Input = String
        public typealias Output = String

        public static let purpose = """
        Investigate invoices, prepare validated draft entries and publish only
        after explicit human confirmation and governed mutation approval.
        Verify the full ledger and report any unresolved post-write effects.
        """

        public static let instructions: Instructions = [
            .instruction(Accounting.Instructions.EvidenceAssessment.definition),
            .instruction(Accounting.Instructions.SourceInterpretation.definition),
            .instruction(Accounting.Instructions.EntryAuthoring.definition)
        ]

        private static let scope = AgentCapabilityScope(
            tools: .init(members: [
                PDF.Tools.ReadDocument.self,
                PDF.Tools.InspectPage.self,
                PDF.Tools.VerifyTextEvidence.self,
                Accounting.Tools.VerifyPDFInvoiceEvidence.self,
                Accounting.Tools.EntryContext.self,
                Accounting.Tools.NextEntryIDs.self,
                Accounting.Tools.FindReferences.self,
                Accounting.Tools.ResolveReferences.self,
                Accounting.Tools.ValidateEntryDraft.self,
                Accounting.Tools.SearchEntries.self,
                Accounting.Tools.ReadEntries.self,
                Accounting.Tools.SearchTransactions.self,
                Accounting.Tools.ReadTransactions.self,
                Accounting.Tools.CompileEntries.self,
                SystemIO.Tools.MutateFiles.self
            ]),
            programs: .init(members: [
                Accounting.Programs.ProcessPDFInvoice.self,
                Accounting.Programs.PrepareInvoiceEntry.self,
                Accounting.Programs.PublishInvoiceEntry.self
            ]),
            inferences: .init(members: [
                Accounting.Inferences.ExtractPDFInvoice.self,
                Accounting.Inferences.InferInvoiceConventions.self,
                Accounting.Inferences.AssociateInvoiceVATBands.self,
                Accounting.Inferences.DraftInvoiceEntry.self
            ])
        )

        public static let capabilities = AgentCapabilities(available: scope, visible: scope)
    }
}
