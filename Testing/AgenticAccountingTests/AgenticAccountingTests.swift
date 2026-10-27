import AgenticAccounting
import Testing

@Test func financial_ratios_use_native_accounting_builder() throws {
    let output = try Accounting.Tools.FinancialRatios.evaluate(.init(
        assets: "1000", equity: "400", liabilities: "600",
        net_turnover: "500", cost_of_revenue: "200",
        operating_expenses: "100", net_income: "100"
    ))
    #expect(output.has_analysis)
    #expect(output.metrics.first(where: { $0.key == "equity_ratio" })?.value == "0.4")
    #expect(output.metrics.first(where: { $0.key == "debt_ratio" })?.value == "0.6")
    #expect(output.metrics.first(where: { $0.key == "debt_to_equity" })?.value == "1.5")
    #expect(output.metrics.first(where: { $0.key == "gross_margin" })?.value == "0.6")
    #expect(output.metrics.first(where: { $0.key == "operating_margin" })?.value == "0.4")
    #expect(output.metrics.first(where: { $0.key == "net_margin" })?.value == "0.2")
    #expect(output.unavailable.contains("current_ratio"))
    #expect(Accounting.Tools.FinancialRatios.definition.identifier.rawValue == "financial_ratios")
}

@Test func absent_and_zero_denominator_ratios_are_not_zero() throws {
    let output = try Accounting.Tools.FinancialRatios.evaluate(.init(
        assets: "0", equity: "0", liabilities: "100", net_income: "10"
    ))
    #expect(output.has_analysis)
    #expect(output.unavailable.contains("equity_ratio"))
    #expect(output.unavailable.contains("debt_to_equity"))
    #expect(output.unavailable.contains("return_on_assets"))
    #expect(output.metrics.first(where: { $0.key == "equity_ratio" }) == nil)
}

@Test func missing_inputs_and_invalid_decimal_rejected() throws {
    let empty = try Accounting.Tools.FinancialRatios.evaluate(.init(
        assets: "0", equity: "0", liabilities: "0"
    ))
    #expect(!empty.has_analysis)
    #expect(empty.metrics.isEmpty)
    do {
        _ = try Accounting.Tools.FinancialRatios.evaluate(.init(
            assets: "not-a-decimal", equity: "400", liabilities: "600"
        ))
        Issue.record("Invalid decimal should throw")
    } catch {
        // Expected rejection.
    }
}
