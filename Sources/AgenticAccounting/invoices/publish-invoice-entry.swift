import Agentic
import AgenticIO
import AgenticPDF
import Foundation
import Macros
import Path
import Schema

@JSONSchema
public struct AccountingInvoicePostingResult: HashableResult {
    public let status: String
    public let sourceFingerprint: String
    public let targetPath: String
    public let mutation: SystemIO.Tools.MutateFiles.Output
    public let baselineEntryCount: Int
    public let verifiedEntryCount: Int?
    public let diagnostics: [String]

    public init(status: String, sourceFingerprint: String, targetPath: String,
                mutation: SystemIO.Tools.MutateFiles.Output, baselineEntryCount: Int,
                verifiedEntryCount: Int? = nil, diagnostics: [String] = []) {
        self.status = status
        self.sourceFingerprint = sourceFingerprint
        self.targetPath = targetPath
        self.mutation = mutation
        self.baselineEntryCount = baselineEntryCount
        self.verifiedEntryCount = verifiedEntryCount
        self.diagnostics = diagnostics
    }
}

public extension Accounting.Programs {
    @Program
    struct PublishInvoiceEntry {
        @JSONSchema
        public struct Input: HashableSource {
            public let draft: AccountingInvoiceEntryDraft

            public init(draft: AccountingInvoiceEntryDraft) { self.draft = draft }
        }

        public typealias Output = AccountingInvoicePostingResult
        public static let purpose = """
        Publish one validated P07 draft to a new .ec file after refreshed source,
        reference, ID, duplicate and compiler checks. Require user confirmation
        and the existing governed mutation tool. Recompile the full ledger and
        expose applied-but-unverified effects instead of retrying them blindly.
        """
        public enum Failure: Error, Sendable {
            case unreviewable_draft
            case unsupported_path
            case stale_pdf
            case stale_ids
            case invalid_draft
            case unresolved_references
            case duplicate_candidate
            case missing_evidence
            case not_approved
        }
        public init() {}

        public func run(_ input: Input, in context: ProgramContext) async throws -> Output {
            let draft = input.draft
            guard draft.reviewable, draft.issues.isEmpty,
                  let source = draft.source, !source.isEmpty,
                  draft.validation?.valid == true, draft.referenceResolution != nil else {
                throw Failure.unreviewable_draft
            }
            guard InvoiceEntryPath.isValid(draft.targetPath) else {
                throw Failure.unsupported_path
            }
            let citations = draft.invoice.verification?.candidates.flatMap(\.verifiedCitations) ?? []
            guard let reference = citations.first?.lineReference,
                  draft.invoice.coverage.sourceFingerprint == reference.sourceFingerprint else {
                throw Failure.missing_evidence
            }
            let checkedPDF: PDF.Tools.ReadDocument.Output = try await context.invoke(
                PDF.Tools.ReadDocument.definition.identifier,
                input: PDF.Tools.ReadDocument.Input(
                    rootID: PathAccessRootIdentifier(rawValue: reference.rootID),
                    path: reference.path,
                    recognition: reference.snapshotID == "vision", limit: 1,
                    expectedFingerprint: reference.sourceFingerprint
                ), as: PDF.Tools.ReadDocument.Output.self
            )
            guard checkedPDF.sourceFingerprint == reference.sourceFingerprint else {
                throw Failure.stale_pdf
            }
            for offset in stride(from: 0, to: citations.count, by: 128) {
                let claims = Array(citations[offset..<min(offset + 128, citations.count)])
                let verified: PDF.Tools.VerifyTextEvidence.Output = try await context.invoke(
                    PDF.Tools.VerifyTextEvidence.definition.identifier,
                    input: PDF.Tools.VerifyTextEvidence.Input(
                        rootID: PathAccessRootIdentifier(rawValue: reference.rootID),
                        path: reference.path,
                        expectedFingerprint: reference.sourceFingerprint,
                        recognition: claims.contains { $0.lineReference.snapshotID == "vision" },
                        claims: claims
                    ), as: PDF.Tools.VerifyTextEvidence.Output.self
                )
                guard verified.sourceFingerprint == reference.sourceFingerprint,
                      verified.verified == claims else { throw Failure.stale_pdf }
            }
            let fresh: Accounting.Tools.NextEntryIDs.Output = try await context.invoke(
                Accounting.Tools.NextEntryIDs.definition.identifier,
                input: Accounting.Tools.NextEntryIDs.Input(count: draft.suggestedIDs.count),
                as: Accounting.Tools.NextEntryIDs.Output.self
            )
            guard fresh.ids == draft.suggestedIDs else { throw Failure.stale_ids }
            let references = draft.proposedAccountReferences.map {
                Accounting.Tools.ResolveReferences.Reference(kind: "account", reference: $0)
            } + draft.proposedEntityReferences.map {
                Accounting.Tools.ResolveReferences.Reference(kind: "entity", reference: $0)
            }
            guard !references.isEmpty, references.count <= 50 else {
                throw Failure.unresolved_references
            }
            let resolved: Accounting.Tools.ResolveReferences.Output = try await context.invoke(
                Accounting.Tools.ResolveReferences.definition.identifier,
                input: Accounting.Tools.ResolveReferences.Input(references: references),
                as: Accounting.Tools.ResolveReferences.Output.self
            )
            guard resolved.results.count == references.count,
                  resolved.results.allSatisfy({ $0.status == "resolved" }) else {
                throw Failure.unresolved_references
            }
            guard let number = draft.invoice.extraction?.candidates.first(where: {
                $0.field == .invoice_number
            })?.rawValue, !number.isEmpty else { throw Failure.missing_evidence }
            let duplicates: Accounting.Tools.SearchEntries.Output = try await context.invoke(
                Accounting.Tools.SearchEntries.definition.identifier,
                input: Accounting.Tools.SearchEntries.Input(text: number, page: .init(limit: 30)),
                as: Accounting.Tools.SearchEntries.Output.self
            )
            guard duplicates.matchedCount == 0 else { throw Failure.duplicate_candidate }
            let baseline: Accounting.Tools.CompileEntries.Output = try await context.invoke(
                Accounting.Tools.CompileEntries.definition.identifier,
                input: Accounting.Tools.CompileEntries.Input(),
                as: Accounting.Tools.CompileEntries.Output.self
            )
            guard baseline.valid else { throw Failure.invalid_draft }
            let validated: Accounting.Tools.ValidateEntryDraft.Output = try await context.invoke(
                Accounting.Tools.ValidateEntryDraft.definition.identifier,
                input: Accounting.Tools.ValidateEntryDraft.Input(source: source),
                as: Accounting.Tools.ValidateEntryDraft.Output.self
            )
            let ids = try InvoiceEntryIDInspection.ids(in: source)
            guard validated.valid, validated.parsedEntryCount == 1,
                  validated.parsedEntryCount == ids.count,
                  Set(ids).count == ids.count,
                  ids.allSatisfy({ fresh.ids.contains($0) }),
                  source.contains(number) else { throw Failure.invalid_draft }

            let approval = try await context.ask(try UserInputRequest(
                prompt: "Approve creation of \(draft.targetPath) with \(ids.count) .ec entries from PDF \(reference.sourceFingerprint)? Type APPROVE to proceed.",
                reason: "Review the exact draft; no existing file may be overwritten.",
                metadata: ["path": draft.targetPath, "sourceFingerprint": reference.sourceFingerprint]
            ))
            guard case .text("APPROVE")? = approval.answer else {
                throw Failure.not_approved
            }

            // The host must execute the actual tool invocation with its mutation
            // preflight and risk approval. Do not directly call MutateFiles.call.
            let mutation: SystemIO.Tools.MutateFiles.Output = try await context.invoke(
                SystemIO.Tools.MutateFiles.definition.identifier,
                input: SystemIO.Tools.MutateFiles.Input(
                    reason: "Approved invoice from \(reference.sourceFingerprint)",
                    entries: [.init(kind: .create_text, path: draft.targetPath, content: source)]
                ), as: SystemIO.Tools.MutateFiles.Output.self
            )
            guard mutation.status == "applied", mutation.creates == 1 else {
                return .init(status: "not_confirmed_applied",
                             sourceFingerprint: reference.sourceFingerprint,
                             targetPath: draft.targetPath, mutation: mutation,
                             baselineEntryCount: baseline.entryCount,
                             diagnostics: ["Mutation staged or unknown; inspect recovery state before retry"])
            }
            do {
                let after: Accounting.Tools.CompileEntries.Output = try await context.invoke(
                    Accounting.Tools.CompileEntries.definition.identifier,
                    input: Accounting.Tools.CompileEntries.Input(),
                    as: Accounting.Tools.CompileEntries.Output.self
                )
                guard after.valid, after.entryCount == baseline.entryCount + ids.count else {
                    return .init(status: "applied_unverified",
                                 sourceFingerprint: reference.sourceFingerprint,
                                 targetPath: draft.targetPath, mutation: mutation,
                                 baselineEntryCount: baseline.entryCount,
                                 verifiedEntryCount: after.entryCount,
                                 diagnostics: ["Post-write ledger delta or compilation mismatch"])
                }
                return .init(status: "verified",
                             sourceFingerprint: reference.sourceFingerprint,
                             targetPath: draft.targetPath, mutation: mutation,
                             baselineEntryCount: baseline.entryCount,
                             verifiedEntryCount: after.entryCount)
            } catch {
                return .init(status: "applied_unverified",
                             sourceFingerprint: reference.sourceFingerprint,
                             targetPath: draft.targetPath, mutation: mutation,
                             baselineEntryCount: baseline.entryCount,
                             diagnostics: ["Post-write compilation error: \(error)"])
            }
        }
    }
}
