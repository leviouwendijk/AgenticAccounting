import Accounting
import AccountingCompiler
import Agentic
import AgenticIO
import Foundation
import Workspace

struct AccountingReferenceCatalog {
    enum Failure: Error {
        case workspaceRequired
    }

    let settings: EntryCompilerSettings
    let accounts: AccountStore?
    let entities: EntityStore?

    static func authorize(
        _ context: ToolContext,
        toolName: String,
        accounts: Bool,
        entities: Bool
    ) throws -> WorkspaceContext {
        guard let workspace = context.workspace else {
            throw Failure.workspaceRequired
        }
        _ = try FileToolAccess.authorize(
            workspace: workspace,
            rootID: workspace.rootIdentifier,
            path: "config/settings.ec",
            capability: .read,
            toolName: toolName,
            type: .file
        )
        if accounts {
            _ = try FileToolAccess.authorize(
                workspace: workspace,
                rootID: workspace.rootIdentifier,
                path: "config/resources",
                capability: .scan,
                toolName: toolName,
                type: .directory
            )
        }
        if entities {
            _ = try FileToolAccess.authorize(
                workspace: workspace,
                rootID: workspace.rootIdentifier,
                path: "config/entities",
                capability: .scan,
                toolName: toolName,
                type: .directory
            )
        }
        return workspace
    }

    static func targets(accounts: Bool, entities: Bool) -> [String] {
        ["config/settings.ec"]
            + (accounts ? ["config/resources"] : [])
            + (entities ? ["config/entities"] : [])
    }

    static func load(
        _ context: ToolContext,
        toolName: String,
        accounts: Bool,
        entities: Bool
    ) throws -> Self {
        let workspace = try authorize(
            context, toolName: toolName, accounts: accounts, entities: entities
        )
        let project = EntryCompilerProject(workspace: workspace)
        let settings = try EntryCompilerSettingsLoader.load(from: project, trace: false)
        let loadedAccounts = accounts
            ? try AccountStoreLoader.load(from: project, settings: settings)
            : nil
        let loadedEntities = entities
            ? try EntityStoreLoader.load(from: project, settings: settings, trace: false)
            : nil
        return Self(settings: settings, accounts: loadedAccounts, entities: loadedEntities)
    }
}
