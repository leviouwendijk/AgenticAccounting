import AgenticAccounting
import Testing

enum PDFInvoiceFinancialNormalizationRegression {
    typealias Normalizer = PDFInvoiceFinancialNormalization
    typealias Field = Accounting.Inferences.ExtractPDFInvoice.Output.Field

    private static func values(_ raw: String, field: Field) -> Set<String> {
        Set(Normalizer.interpretations(rawValue: raw, field: field).map(\.value))
    }

    static func run() throws {
        try Expect.equal(values("1.234,56", field: .gross_amount), ["1234.56"], "Dutch grouped decimal")
        try Expect.equal(values("1,234.56", field: .gross_amount), ["1234.56"], "International grouped decimal")
        try Expect.equal(values("1 234,56", field: .gross_amount), ["1234.56"], "Space grouping")
        try Expect.equal(values("1'234.56", field: .gross_amount), ["1234.56"], "Apostrophe grouping")
        try Expect.equal(values("€ 1.234,56", field: .gross_amount), ["1234.56"], "Currency prefix")
        try Expect.equal(values("$1,234.56", field: .gross_amount), ["1234.56"], "Currency prefix with decimal dot")
        try Expect.equal(values("(1.234,56)", field: .net_amount), ["-1234.56"], "Negative parentheses")
        try Expect.equal(values("1.234.567", field: .gross_amount), ["1234567"], "Grouped integer")
        try Expect.equal(values("1234,56", field: .gross_amount), ["1234.56"], "Ungrouped comma fraction")
        try Expect.equal(values("1234.56", field: .gross_amount), ["1234.56"], "Ungrouped dot fraction")
        try Expect.equal(values("1,234", field: .gross_amount), ["1.234", "1234"], "Ambiguous comma preserved")
        try Expect.equal(values("1.234", field: .gross_amount), ["1.234", "1234"], "Ambiguous dot preserved")
        try Expect.equal(values("1,23,45", field: .gross_amount).isEmpty, true, "Invalid grouping")
        try Expect.equal(values("0", field: .gross_amount), ["0"], "A real zero is retained")
        try Expect.equal(values("21%", field: .vat_rate), ["0.21"], "VAT percent becomes fraction")
        try Expect.equal(values("21", field: .vat_rate).isEmpty, true, "No invented percent sign")

        try Expect.equal(values("2026-11-03", field: .invoice_date), ["2026-11-03"], "ISO date")
        try Expect.equal(values("23-11-2026", field: .invoice_date), ["2026-11-23"], "Unambiguous Dutch date")
        try Expect.equal(values("11/23/2026", field: .invoice_date), ["2026-11-23"], "Unambiguous US date")
        try Expect.equal(values("03/11/2026", field: .invoice_date), ["2026-03-11", "2026-11-03"], "Date ambiguity")
        try Expect.equal(values("29/02/2024", field: .invoice_date), ["2024-02-29"], "Valid leap day")
        try Expect.equal(values("29/02/2025", field: .invoice_date).isEmpty, true, "Invalid leap day")
        try Expect.equal(values("31/04/2026", field: .invoice_date).isEmpty, true, "Invalid calendar day")
        try Expect.equal(values("EUR", field: .currency), ["EUR"], "ISO currency")
        try Expect.equal(values("€", field: .currency), ["EUR"], "Unambiguous currency symbol")
        try Expect.equal(values("$", field: .currency).isEmpty, true, "Ambiguous currency symbol")
        try Expect.equal(values("INV-2026-041", field: .invoice_number).isEmpty, true, "Non-financial field untouched")
    }
}
