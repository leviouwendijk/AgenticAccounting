import Agentic
import Foundation
import IO
import Path
import Workspace

/// Small on-disk project fixture for exercising the actual agent tool.
struct NextEntryIDsWorkspaceFixture {
    let root: URL

    init() throws {
        let manager = FileManager.default
        root = manager.temporaryDirectory.appendingPathComponent(
            "agentic-accounting-ids-\(UUID().uuidString)", isDirectory: true
        )
        let config = root.appendingPathComponent("config", isDirectory: true)
        let month = root.appendingPathComponent("entries/2026/2/4", isDirectory: true)
        try manager.createDirectory(at: config, withIntermediateDirectories: true)
        try manager.createDirectory(at: month, withIntermediateDirectories: true)
        try """
        settings {
            entry {
                default_timezone = Europe/Amsterdam
            }
            aggregation {
                chart {
                    find rgs
                    version {
                        major = 3
                        minor = 8
                    }
                }
                include_previous_periods = true
            }
        }
        """.write(
            to: config.appendingPathComponent("settings.ec"),
            atomically: true, encoding: .utf8
        )
        try """
        entry { id = 41 date = 2026-04-12 }
        entry { id = 46 date = 2026-04-13 }
        """.write(
            to: month.appendingPathComponent("main.ec"),
            atomically: true, encoding: .utf8
        )
    }

    func context(capabilities: Set<WorkspaceCapability>) throws -> ToolContext {
        let rootID = PathAccessRootIdentifier(rawValue: "project")
        let installed = PathAccessRoot(
            id: rootID,
            label: "Accounting test ledger",
            scope: try PathAccessScope(root: root, policy: .defaults.workspace),
            isDefault: true
        )
        let grant = try WorkspaceGrant(
            id: WorkspaceGrantIdentifier("agentic-accounting-test-grant"),
            rootIdentifier: rootID,
            capabilities: capabilities
        )
        let workspace = try Workspace(root: installed, grants: [grant])
        return ToolContext(workspace: try workspace.context(
            execution: .init(io: .blocking, mutations: .immediate)
        ))
    }

    mutating func installEscapingSymlink() throws {
        let manager = FileManager.default
        let outside = root.deletingLastPathComponent().appendingPathComponent(
            "agentic-accounting-outside-\(UUID().uuidString).ec"
        )
        try "entry { id = 9000 date = 2026-04-12 }".write(
            to: outside, atomically: true, encoding: .utf8
        )
        // The outside fixture is deleted when this fixture is cleaned up.
        try manager.createSymbolicLink(
            at: root.appendingPathComponent("entries/2026/2/4/escaping.ec"),
            withDestinationURL: outside
        )
        escapedFile = outside
    }

    private(set) var escapedFile: URL? = nil

    func cleanup() {
        let manager = FileManager.default
        try? manager.removeItem(at: root)
        if let escapedFile { try? manager.removeItem(at: escapedFile) }
    }
}
