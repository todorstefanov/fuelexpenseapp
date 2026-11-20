import Foundation
import CoreGraphics

struct ReceiptData {
    let merchant: String?
    let receiptNumber: String?
    let date: Date?
    let totalAmount: Decimal?
    let vatAmount: Decimal?
    let currency: String?
    let fuelLineAmount: Decimal?
    let fuelLineCurrency: String?
    let discountAmount: Decimal?
    let discountCurrency: String?
    let discountWasInferred: Bool
    let quantityLiters: Decimal?
    let fuelBrand: String?
    let fuelType: String?
    let confidence: [String: Double]

    var hasRecognizedFields: Bool {
        merchant != nil
            || date != nil
            || totalAmount != nil
            || fuelLineAmount != nil
            || discountAmount != nil
            || quantityLiters != nil
            || fuelBrand != nil
            || fuelType != nil
            || receiptNumber != nil
            || vatAmount != nil
    }

    var webFormValues: [String: String] {
        var values: [String: String] = [:]

        if let date, confidence["date", default: 0] >= 0.55 {
            values["expense_date"] = Self.dateInputFormatter.string(from: date)
        }
        if let quantityLiters, confidence["quantity", default: 0] >= 0.55 {
            let rounded = Self.rounded(quantityLiters, scale: 3)
            if rounded >= Decimal(1) / Decimal(1000) {
                values["quantity"] = Self.fixedScaleString(rounded, scale: 3)
            }
        }
        if let expenseAmountEUR,
           confidence["expenseAmount", default: 0] >= 0.65 {
            values["price"] = Self.fixedScaleString(expenseAmountEUR, scale: 2)
        }
        if let merchant,
           merchant.count <= 150,
           confidence["merchant", default: 0] >= 0.55 {
            values["gas_station"] = merchant
        }
        if let fuelBrand,
           fuelBrand.count <= 100,
           confidence["fuelBrand", default: 0] >= 0.55 {
            values["fuel_brand"] = fuelBrand
        }
        if let fuelType,
           fuelType.count <= 100,
           confidence["fuelType", default: 0] >= 0.55 {
            values["fuel_type"] = fuelType
        }

        return values
    }

    var reviewLines: [String] {
        var lines: [String] = []
        if let merchant { lines.append("Station: \(merchant)") }
        if let date { lines.append("Date: \(Self.dateInputFormatter.string(from: date))") }
        if let quantityLiters {
            lines.append("Quantity: \(Self.fixedScaleString(quantityLiters, scale: 3)) L")
        }
        if let fuelLineAmount {
            let amount = Self.fixedScaleString(fuelLineAmount, scale: 2)
            lines.append("Fuel amount: \(amount)\(fuelLineCurrency.map { " \($0)" } ?? "")")
        }
        if let discountAmount {
            let amount = Self.fixedScaleString(discountAmount, scale: 2)
            let label = discountWasInferred ? "Estimated discount" : "Discount"
            lines.append("\(label): \(amount)\(discountCurrency.map { " \($0)" } ?? "")")
        }
        if let expenseAmountEUR {
            lines.append("Amount entered as EUR: \(Self.fixedScaleString(expenseAmountEUR, scale: 2))")
        }
        if let totalAmount {
            let amount = Self.fixedScaleString(totalAmount, scale: 2)
            lines.append("Total: \(amount)\(currency.map { " \($0)" } ?? "")")
        }
        if let vatAmount {
            let amount = Self.fixedScaleString(vatAmount, scale: 2)
            lines.append("VAT: \(amount)\(currency.map { " \($0)" } ?? "")")
        }
        if let fuelBrand { lines.append("Fuel product: \(fuelBrand)") }
        if let fuelType { lines.append("Fuel type: \(fuelType)") }
        if let receiptNumber { lines.append("Receipt number: \(receiptNumber)") }
        return lines
    }

    var expenseAmountEUR: Decimal? {
        let grossAmount: Decimal
        let currencyForGross: String?
        if let fuelLineAmount {
            // The expense form uses the fuel-line amount as the EUR input, without currency conversion.
            grossAmount = fuelLineAmount
            currencyForGross = fuelLineCurrency
        } else if let totalAmount, currency == "EUR" {
            grossAmount = totalAmount
            currencyForGross = currency
        } else {
            return nil
        }

        if discountAmount != nil {
            if let currencyForGross, let discountCurrency, currencyForGross != discountCurrency {
                return nil
            }
            if fuelLineAmount == nil, discountCurrency != nil, discountCurrency != "EUR" {
                return nil
            }
        }

        let netAmount = grossAmount - (discountAmount ?? .zero)
        return netAmount >= .zero ? netAmount : nil
    }

    private static let dateInputFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func rounded(_ value: Decimal, scale: Int) -> Decimal {
        var source = value
        var result = Decimal()
        NSDecimalRound(&result, &source, scale, .plain)
        return result
    }

    private static func fixedScaleString(_ value: Decimal, scale: Int) -> String {
        let roundedValue = NSDecimalNumber(decimal: rounded(value, scale: scale)).stringValue
        let fractionCount = roundedValue.split(separator: ".", omittingEmptySubsequences: false)
            .dropFirst()
            .first?
            .count ?? 0
        let trailingZeros = String(repeating: "0", count: max(0, scale - fractionCount))
        if fractionCount == 0 {
            return scale == 0 ? roundedValue : "\(roundedValue).\(trailingZeros)"
        }
        return roundedValue + trailingZeros
    }
}

struct OCRTextLine {
    let text: String
    let confidence: Double
    let top: CGFloat
    let left: CGFloat
}

enum ReceiptScanError: LocalizedError {
    case unsupportedImage
    case noText
    case noReceiptFields

    var errorDescription: String? {
        switch self {
        case .unsupportedImage:
            return "This image could not be opened. Try another photo or image."
        case .noText:
            return "No readable text was found. Try a sharper, brighter photo."
        case .noReceiptFields:
            return "Receipt details could not be recognized. Try another photo or enter the fields manually."
        }
    }
}
