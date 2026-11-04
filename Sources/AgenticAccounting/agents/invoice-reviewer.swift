import Agentic
import AgenticPDF
import Schema

public extension Accounting.Agents {
    @Agent
    enum InvoiceReviewer {
        public typealias Input = String
        public typealias Output = String
        public static let purpose = """
        Read-only invoice investigation and validated entry preparation.
        Execute ProcessPDFInvoice, then PrepareInvoiceEntry with supplied
        financial evidence. Never post entries or mutate accounting sources.
        """
        public static let instructions: Instructions = [
            .instruction(Accounting.Instructions.EvidenceAssessment.definition),
            .instruction(Accounting.Instructions.SourceInterpretation.definition)
        ]
        private static let scope = AgentCapabilityScope(
            tools: .init(members: [
                PDF.Tools.ReadDocument.self,
                PDF.Tools.InspectPage.self,
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
                Accounting.Tools.CompileEntries.self
            ]),
            programs: .init(members: [
                Accounting.Programs.ProcessPDFInvoice.self,
                Accounting.Programs.PrepareInvoiceEntry.self
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
