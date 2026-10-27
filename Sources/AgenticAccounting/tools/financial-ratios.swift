import Accounting
import AccountingCompiler
import Agentic
import Foundation
import Macros
import Math
import Schema

public extension Accounting.Tools {
    @Tool("financial_ratios")
    struct FinancialRatios: Tool {
        @JSONSchema
        public struct Input: HashableSource {
            public let assets: String
            public let equity: String
            public let liabilities: String
            public let net_turnover: String?
            public let cost_of_revenue: String?
            public let operating_expenses: String?
            public let depreciation_expenses: String?
            public let financial_result: String?
            public let net_income: String?
            public let liquid_assets: String?
            public let short_term_securities: String?
            public let receivables: String?
            public let accrued_current_assets: String?
            public let inventory: String?
            public let work_in_progress: String?
            public let current_liabilities: String?
            public let accrued_current_liabilities: String?
            public let scale: Int?

            public init(
                assets: String, equity: String, liabilities: String,
                net_turnover: String? = nil, cost_of_revenue: String? = nil,
                operating_expenses: String? = nil, depreciation_expenses: String? = nil,
                financial_result: String? = nil, net_income: String? = nil,
                liquid_assets: String? = nil, short_term_securities: String? = nil,
                receivables: String? = nil, accrued_current_assets: String? = nil,
                inventory: String? = nil, work_in_progress: String? = nil,
                current_liabilities: String? = nil,
                accrued_current_liabilities: String? = nil,
                scale: Int? = nil
            ) {
                self.assets = assets
                self.equity = equity
                self.liabilities = liabilities
                self.net_turnover = net_turnover
                self.cost_of_revenue = cost_of_revenue
                self.operating_expenses = operating_expenses
                self.depreciation_expenses = depreciation_expenses
                self.financial_result = financial_result
                self.net_income = net_income
                self.liquid_assets = liquid_assets
                self.short_term_securities = short_term_securities
                self.receivables = receivables
                self.accrued_current_assets = accrued_current_assets
                self.inventory = inventory
                self.work_in_progress = work_in_progress
                self.current_liabilities = current_liabilities
                self.accrued_current_liabilities = accrued_current_liabilities
                self.scale = scale
            }
        }

        @JSONSchema
        public struct Metric: HashableResult {
            public let key: String
            public let value: String
            public init(key: String, value: String) {
                self.key = key
                self.value = value
            }
        }

        @JSONSchema
        public struct Output: HashableResult {
            public let has_analysis: Bool
            public let metrics: [Metric]
            public let unavailable: [String]
            public init(has_analysis: Bool, metrics: [Metric], unavailable: [String]) {
                self.has_analysis = has_analysis
                self.metrics = metrics
                self.unavailable = unavailable
            }
        }

        public static let purpose = "Calculate accounting-defined financial ratios from supplied statement inputs using AccountingCompiler.FinancialRatiosBuilder. Values are dimensionless fractions, not percentages; absent and zero-denominator ratios remain unavailable. Read-only; does not access or modify ledgers."
        public static let risk: ActionRisk = .observe
        public init() {}

        private static func parse_optional(_ raw: String?) throws -> Decimal? {
            try raw.map(DecimalArithmetic.parse)
        }

        public static func validate(_ input: Input) throws {
            guard (0...16).contains(input.scale ?? 12) else {
                throw DecimalArithmetic.Failure.invalidScale(input.scale ?? 12)
            }
            _ = try DecimalArithmetic.parse(input.assets)
            _ = try DecimalArithmetic.parse(input.equity)
            _ = try DecimalArithmetic.parse(input.liabilities)
            for value in [
                input.net_turnover, input.cost_of_revenue, input.operating_expenses,
                input.depreciation_expenses, input.financial_result, input.net_income,
                input.liquid_assets, input.short_term_securities, input.receivables,
                input.accrued_current_assets, input.inventory, input.work_in_progress,
                input.current_liabilities, input.accrued_current_liabilities
            ] {
                _ = try parse_optional(value)
            }
        }

        public static func evaluate(_ input: Input) throws -> Output {
            try validate(input)
            let values = FinancialRatioInputs(
                assets: try DecimalArithmetic.parse(input.assets),
                equity: try DecimalArithmetic.parse(input.equity),
                liabilities: try DecimalArithmetic.parse(input.liabilities),
                netTurnover: try parse_optional(input.net_turnover),
                costOfRevenue: try parse_optional(input.cost_of_revenue),
                operatingExpenses: try parse_optional(input.operating_expenses),
                depreciationExpenses: try parse_optional(input.depreciation_expenses),
                financialResult: try parse_optional(input.financial_result),
                netIncome: try parse_optional(input.net_income),
                liquidAssets: try parse_optional(input.liquid_assets),
                shortTermSecurities: try parse_optional(input.short_term_securities),
                receivables: try parse_optional(input.receivables),
                accruedCurrentAssets: try parse_optional(input.accrued_current_assets),
                inventory: try parse_optional(input.inventory),
                workInProgress: try parse_optional(input.work_in_progress),
                currentLiabilities: try parse_optional(input.current_liabilities),
                accruedCurrentLiabilities: try parse_optional(input.accrued_current_liabilities)
            )
            guard let ratios = FinancialRatiosBuilder.build(from: values) else {
                return .init(has_analysis: false, metrics: [], unavailable: [])
            }
            let pairs: [(String, Decimal?)] = [
                ("equity_ratio", ratios.equityRatio),
                ("debt_ratio", ratios.debtRatio),
                ("debt_to_equity", ratios.debtToEquity),
                ("equity_multiplier", ratios.equityMultiplier),
                ("current_ratio", ratios.currentRatio),
                ("quick_ratio", ratios.quickRatio),
                ("gross_margin", ratios.grossMargin),
                ("operating_margin", ratios.operatingMargin),
                ("net_margin", ratios.netMargin),
                ("return_on_assets", ratios.returnOnAssets),
                ("return_on_equity", ratios.returnOnEquity)
            ]
            let scale = input.scale ?? 12
            var metrics: [Metric] = []
            var unavailable: [String] = []
            for (key, number) in pairs {
                if let number {
                    let rounded = try DecimalArithmetic.round(number, scale: scale)
                    metrics.append(.init(key: key, value: DecimalArithmetic.string(rounded)))
                } else {
                    unavailable.append(key)
                }
            }
            return .init(has_analysis: true, metrics: metrics, unavailable: unavailable)
        }

        public func preflight(_ input: Input, in _: ToolContext) async throws -> ToolPreflight {
            try Self.validate(input)
            return .init(
                tool: Self.definition.identifier,
                risk: Self.definition.risk,
                summary: "Analyze supplied accounting statement ratios",
                sideEffects: []
            )
        }

        public func call(_ input: Input, in _: ToolContext) async throws -> Output {
            try Self.evaluate(input)
        }
    }
}
