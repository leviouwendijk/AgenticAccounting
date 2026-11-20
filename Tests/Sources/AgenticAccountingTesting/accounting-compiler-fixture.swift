import Accounting
import Foundation

extension NextEntryIDsWorkspaceFixture {
    func installCompilableLedger() throws {
        let fm = FileManager.default
        let entityURL = root.appendingPathComponent(
            "config/entities/fixtures/general/definition.ec"
        )
        try fm.createDirectory(at: entityURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try "entity { use alias compiler_fixture }".write(
            to: entityURL, atomically: true, encoding: .utf8
        )

        let entryURL = root.appendingPathComponent("entries/2026/2/4/main.ec")
        try Self.validEntry(id: 41).write(to: entryURL, atomically: true,
                                          encoding: .utf8)
        try fm.createDirectory(at: root.appendingPathComponent("transactions"),
                               withIntermediateDirectories: true)

        let chart = try CompiledChart(
            name: "AgenticAccounting synthetic chart",
            version: .init(major: 3, minor: 8),
            nodes: [
                try RGSNode(
                    id: 1, codes: .init(code: "BLimBanRba"),
                    labels: .init(short: "Bank", long: "Bank"),
                    direction: .debit, level: 3, temporality: .instant,
                    side: .balance, omslagId: nil, directionSign: nil,
                    xlsx: nil, xbrl: nil
                ),
                try RGSNode(
                    id: 2, codes: .init(code: "WOmzNodOdh"),
                    labels: .init(short: "Revenue", long: "Revenue"),
                    direction: .credit, level: 3, temporality: .duration,
                    side: .profitLoss, omslagId: nil, directionSign: nil,
                    xlsx: nil, xbrl: nil
                ),
                try RGSNode(
                    id: 3, codes: .init(code: "WNerKapKap"),
                    labels: .init(short: "Net income", long: "Net income"),
                    direction: .credit, level: 3, temporality: .duration,
                    side: .profitLoss, omslagId: nil, directionSign: nil,
                    xlsx: nil, xbrl: nil
                ),
                try RGSNode(
                    id: 4, codes: .init(code: "BEivKapOndAow"),
                    labels: .init(short: "Equity", long: "Equity"),
                    direction: .credit, level: 3, temporality: .instant,
                    side: .balance, omslagId: nil, directionSign: nil,
                    xlsx: nil, xbrl: nil
                ),
                try RGSNode(
                    id: 5, codes: .init(code: "BEivKapOndBeg"),
                    labels: .init(short: "Opening equity", long: "Opening equity"),
                    direction: .credit, level: 3, temporality: .instant,
                    side: .balance, omslagId: nil, directionSign: nil,
                    xlsx: nil, xbrl: nil
                ),
                try RGSNode(
                    id: 6, codes: .init(code: "BLim"),
                    labels: .init(short: "Liquid assets", long: "Liquid assets"),
                    direction: nil, level: 2, temporality: .instant,
                    side: .balance, omslagId: nil, directionSign: nil,
                    xlsx: nil, xbrl: nil
                ),
                try RGSNode(
                    id: 7, codes: .init(code: "BEiv"),
                    labels: .init(short: "Equity root", long: "Equity root"),
                    direction: .credit, level: 2, temporality: .instant,
                    side: .balance, omslagId: nil, directionSign: nil,
                    xlsx: nil, xbrl: nil
                ),
                try RGSNode(
                    id: 8, codes: .init(code: "B"),
                    labels: .init(short: "Balance sheet", long: "Balance sheet"),
                    direction: nil, level: 1, temporality: .instant,
                    side: .balance, omslagId: nil, directionSign: nil,
                    xlsx: nil, xbrl: nil
                ),
                try RGSNode(
                    id: 9, codes: .init(code: "W"),
                    labels: .init(short: "Income statement", long: "Income statement"),
                    direction: nil, level: 1, temporality: .duration,
                    side: .profitLoss, omslagId: nil, directionSign: nil,
                    xlsx: nil, xbrl: nil
                ),
                try RGSNode(
                    id: 10, codes: .init(code: "WOmz"),
                    labels: .init(short: "Turnover", long: "Turnover"),
                    direction: nil, level: 2, temporality: .duration,
                    side: .profitLoss, omslagId: nil, directionSign: nil,
                    xlsx: nil, xbrl: nil
                ),
                try RGSNode(
                    id: 11, codes: .init(code: "WNerKap"),
                    labels: .init(short: "Net income group", long: "Net income group"),
                    direction: nil, level: 2, temporality: .duration,
                    side: .profitLoss, omslagId: nil, directionSign: nil,
                    xlsx: nil, xbrl: nil
                ),
            ]
        )
        let chartURL = root.appendingPathComponent("config/resources/rgs/v3_8.json")
        try fm.createDirectory(at: chartURL.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try JSONEncoder().encode(chart).write(to: chartURL, options: .atomic)
    }

    static func validEntry(id: Int, debit: String = "25.00",
                           credit: String = "25.00",
                           account: String = "WOmzNodOdh") -> String {
        """
        entry {
            id = \(id)
            date = 2026-04-12
            for (compiler_fixture) in (BLimBanRba) {
                debit = \(debit)
            }
            for (compiler_fixture) in (\(account)) {
                credit = \(credit)
            }
        }
        """
    }
}
