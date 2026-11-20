import Foundation

struct ReceiptParser {
    private let datePattern = #"(?<!\d)(\d{4}-\d{1,2}-\d{1,2}|\d{1,2}[./-]\d{1,2}[./-]\d{4})(?!\d)"#

    func parse(_ input: [OCRTextLine]) -> ReceiptData {
        let lines = input
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                if abs($0.top - $1.top) > 0.008 {
                    return $0.top > $1.top
                }
                return $0.left < $1.left
            }

        let merchant = findMerchant(in: lines)
        let date = findDate(in: lines)
        let total = findTotal(in: lines)
        let vat = findVAT(in: lines)
        let fuelLineAmount = findFuelLineAmount(in: lines)
        let recognizedDiscount = findDiscount(in: lines)
        let inferredDiscount = recognizedDiscount == nil
            ? inferDiscount(fuelLineAmount: fuelLineAmount, total: total)
            : nil
        let discount = recognizedDiscount ?? inferredDiscount
        let quantity = findQuantity(in: lines)
        let fuelType = findFuelType(in: lines)
        let fuelBrand = findFuelBrand(in: lines)
        let receiptNumber = findReceiptNumber(in: lines)

        var confidence: [String: Double] = [:]
        if let merchant { confidence["merchant"] = merchant.confidence }
        if let date { confidence["date"] = date.confidence }
        if let total { confidence["total"] = total.confidence }
        if let vat { confidence["vat"] = vat.confidence }
        if let fuelLineAmount { confidence["fuelAmount"] = fuelLineAmount.confidence }
        if let discount { confidence["discount"] = discount.confidence }
        if let quantity { confidence["quantity"] = quantity.confidence }
        if let fuelType { confidence["fuelType"] = fuelType.confidence }
        if let fuelBrand { confidence["fuelBrand"] = fuelBrand.confidence }
        if let receiptNumber { confidence["receiptNumber"] = receiptNumber.confidence }
        if inferredDiscount != nil, let total, total.currency == "EUR" {
            confidence["expenseAmount"] = total.confidence
        } else if let grossConfidence = fuelLineAmount?.confidence
                    ?? (total?.currency == "EUR" ? total?.confidence : nil) {
            confidence["expenseAmount"] = discount.map { min(grossConfidence, $0.confidence) } ?? grossConfidence
        }

        return ReceiptData(
            merchant: merchant?.value,
            receiptNumber: receiptNumber?.value,
            date: date?.value,
            totalAmount: total?.amount,
            vatAmount: vat?.amount,
            currency: total?.currency
                ?? fuelLineAmount?.currency
                ?? findCurrency(in: lines.map(\.text).joined(separator: " ")),
            fuelLineAmount: fuelLineAmount?.amount,
            fuelLineCurrency: fuelLineAmount?.currency,
            discountAmount: discount?.amount,
            discountCurrency: discount?.currency,
            discountWasInferred: inferredDiscount != nil,
            quantityLiters: quantity?.value,
            fuelBrand: fuelBrand?.value,
            fuelType: fuelType?.value,
            confidence: confidence
        )
    }

    private func findMerchant(in lines: [OCRTextLine]) -> Match<String>? {
        let knownMerchants: [(patterns: [String], value: String)] = [
            (["shell", "шел"], "Shell"),
            (["lidl", "лидл"], "Lidl"),
            (["kaufland", "кауфланд"], "Kaufland"),
            (["billa", "билла"], "Billa"),
            (["omv"], "OMV")
        ]

        for line in lines.prefix(14) {
            let normalized = folded(line.text)
            if let merchant = knownMerchants.first(where: { entry in
                entry.patterns.contains(where: normalized.contains)
            }) {
                return Match(value: merchant.value, confidence: min(0.99, line.confidence + 0.12))
            }
        }

        for line in lines.prefix(6) {
            let candidate = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = folded(candidate)
            guard candidate.rangeOfCharacter(from: .letters) != nil,
                  !containsAny(normalized, [
                    "receipt", "invoice", "fiscal", "бон", "дата", "date",
                    "бул.", "ул.", "sofia", "софия", "eik", "vat"
                  ]) else {
                continue
            }
            return Match(value: candidate, confidence: max(0.35, line.confidence * 0.65))
        }

        return nil
    }

    private func findDate(in lines: [OCRTextLine]) -> Match<Date>? {
        let hasCyrillic = lines.contains { $0.text.range(of: #"[А-Яа-я]"#, options: .regularExpression) != nil }

        for line in lines {
            guard let rawDate = firstCapture(datePattern, in: line.text),
                  let date = parseDate(rawDate, preferDayFirst: hasCyrillic) else {
                continue
            }
            return Match(value: date, confidence: min(0.99, line.confidence + 0.1))
        }
        return nil
    }

    private func findTotal(in lines: [OCRTextLine]) -> TotalMatch? {
        let labelPattern = #"(?i)\b(grand\s*total|total|amount\s*(?:due|paid)?|payment|обща\s+сума|сума\s+за\s+плащане)\b"#
        let amountPattern = #"(?<!\d)(\d{1,3}(?:[ .]\d{3})*(?:[,.]\d{1,3})?|\d+(?:[,.]\d{1,3})?)(?!\d)"#
        var candidates: [TotalMatch] = []

        for (index, line) in lines.enumerated() {
            let normalized = folded(line.text)
            guard normalized.range(of: labelPattern, options: .regularExpression) != nil,
                  !containsAny(normalized, ["vat", "tax", "dds", "ддс", "change", "ресто"]) else {
                continue
            }

            let labelCurrency = findCurrency(in: line.text)
            let labelScore: Double
            if containsAny(normalized, ["евро", "eur", "€"]) {
                labelScore = 1.0
            } else if containsAny(normalized, ["grand total", "обща сума", "total"]) {
                labelScore = 0.82
            } else {
                labelScore = 0.68
            }

            for offset in 0...1 where index + offset < lines.count {
                let valueLine = lines[index + offset]
                guard firstCapture(datePattern, in: valueLine.text) == nil else {
                    continue
                }
                let values = captures(amountPattern, in: normalizeNumericOCR(valueLine.text))
                for rawValue in values {
                    guard let amount = parseDecimal(rawValue), amount > 0 else { continue }
                    let currency = labelCurrency ?? findCurrency(in: valueLine.text)
                    let distancePenalty = Double(offset) * 0.045
                    let confidence = max(0.25, min(0.99, labelScore * line.confidence - distancePenalty))
                    candidates.append(TotalMatch(amount: amount, currency: currency, confidence: confidence))
                }
            }
        }

        return candidates.max {
            totalScore($0) < totalScore($1)
        }
    }

    private func findVAT(in lines: [OCRTextLine]) -> TotalMatch? {
        let labelPattern = #"(?i)\b(vat(?:\s+amount)?|tax|dds|ддс|данък)\b"#
        let amountPattern = #"(?<!\d)(\d{1,3}(?:[ .]\d{3})*(?:[,.]\d{1,3})?|\d+(?:[,.]\d{1,3})?)(?!\d)"#
        var candidates: [TotalMatch] = []

        for (index, line) in lines.enumerated() {
            guard folded(line.text).range(of: labelPattern, options: .regularExpression) != nil else { continue }
            for offset in 0...1 where index + offset < lines.count {
                let valueLine = lines[index + offset]
                guard firstCapture(datePattern, in: valueLine.text) == nil else {
                    continue
                }
                for rawValue in captures(amountPattern, in: normalizeNumericOCR(valueLine.text)) {
                    guard let amount = parseDecimal(rawValue), amount >= 0 else { continue }
                    let confidence = max(0.25, min(0.95, line.confidence * 0.85 - Double(offset) * 0.04))
                    candidates.append(TotalMatch(
                        amount: amount,
                        currency: findCurrency(in: line.text),
                        confidence: confidence
                    ))
                }
            }
        }

        return candidates.max { $0.confidence < $1.confidence }
    }

    private func findFuelLineAmount(in lines: [OCRTextLine]) -> TotalMatch? {
        let fuelPattern = ["v-power", "vpower", "бензин", "petrol", "gasoline", "diesel", "дизел", "autogas", "lpg"]
        let amountPattern = #"(?<![\d.,])(\d{1,3}(?:[ .]\d{3})*(?:[,.]\d{2,3})|\d+(?:[,.]\d{2,3}))(?!\d)"#

        for (index, line) in lines.enumerated() where containsAny(folded(line.text), fuelPattern) {
            let nearbyLines = lines.enumerated()
                .filter { abs($0.element.top - line.top) <= 0.018 }
                .sorted { $0.element.left < $1.element.left }

            let amountLine = nearbyLines.reversed().first {
                !captures(amountPattern, in: normalizeNumericOCR($0.element.text)).isEmpty
            } ?? (captures(amountPattern, in: normalizeNumericOCR(line.text)).isEmpty ? nil : (index, line))
            guard let amountLine,
                  let rawValue = captures(amountPattern, in: normalizeNumericOCR(amountLine.element.text)).last
                    ?? firstCapture(amountPattern, in: normalizeNumericOCR(line.text)),
                  let amount = parseDecimal(rawValue),
                  amount > 0 else {
                continue
            }

            let confidence = min(line.confidence, amountLine.element.confidence)
            return TotalMatch(
                amount: amount,
                currency: findCurrency(in: amountLine.element.text) ?? findCurrency(in: line.text),
                confidence: confidence
            )
        }
        return nil
    }

    private func findDiscount(in lines: [OCRTextLine]) -> TotalMatch? {
        let labelPattern = #"(?i)\b(discounts?|отстъпк(?:а|и)|намаление)\b"#
        let amountPattern = #"(?<!\d)(\d{1,3}(?:[ .]\d{3})*(?:[,.]\d{1,3})?|\d+(?:[,.]\d{1,3})?)(?!\d)"#
        var candidates: [TotalMatch] = []

        for (index, line) in lines.enumerated() {
            guard folded(line.text).range(of: labelPattern, options: .regularExpression) != nil else { continue }
            for offset in 0...1 where index + offset < lines.count {
                let valueLine = lines[index + offset]
                for rawValue in captures(amountPattern, in: normalizeNumericOCR(valueLine.text)) {
                    guard let amount = parseDecimal(rawValue), amount >= 0 else { continue }
                    let confidence = max(0.25, min(0.95, line.confidence * 0.9 - Double(offset) * 0.04))
                    candidates.append(TotalMatch(
                        amount: amount,
                        currency: findCurrency(in: valueLine.text) ?? findCurrency(in: line.text),
                        confidence: confidence
                    ))
                }
            }
        }

        return candidates.max { $0.confidence < $1.confidence }
    }

    private func inferDiscount(
        fuelLineAmount: TotalMatch?,
        total: TotalMatch?
    ) -> TotalMatch? {
        guard let fuelLineAmount,
              let total,
              total.currency == "EUR",
              fuelLineAmount.currency == nil || fuelLineAmount.currency == "EUR" else {
            return nil
        }

        let difference = fuelLineAmount.amount - total.amount
        guard difference > .zero,
              difference <= fuelLineAmount.amount * Decimal(25) / Decimal(100) else {
            return nil
        }

        return TotalMatch(
            amount: difference,
            currency: "EUR",
            confidence: min(fuelLineAmount.confidence, total.confidence)
        )
    }

    private func totalScore(_ match: TotalMatch) -> Double {
        match.confidence + (match.currency == "EUR" ? 0.16 : 0)
    }

    private func findQuantity(in lines: [OCRTextLine]) -> Match<Decimal>? {
        let quantityPattern = #"(?i)(\d{1,3}(?:[.,]\d{3})+|\d+(?:[.,]\d{1,3})?)\s*(?:x|×)\s*\d+(?:[.,]\d{1,3})"#
        let litersPattern = #"(?i)(\d{1,3}(?:[.,]\d{3})+|\d+(?:[.,]\d{1,3})?)\s*(?:lit(?:er|re)?s?|l|лит(?:ра|ри)?|л)(?![a-zа-я])"#

        for (index, line) in lines.enumerated() {
            let numericText = normalizeNumericOCR(line.text)
            let raw = firstCapture(quantityPattern, in: numericText)
                ?? firstCapture(litersPattern, in: numericText)
            guard let raw, let quantity = parseDecimal(raw), quantity > 0 else { continue }

            let adjacentFuelText = lines[max(0, index - 1)...min(lines.count - 1, index + 1)]
                .map(\.text)
                .joined(separator: " ")
            let confidenceBoost = containsAny(folded(adjacentFuelText), [
                "бензин", "petrol", "gasoline", "diesel", "дизел", "v-power"
            ]) ? 0.12 : 0.02
            return Match(value: quantity, confidence: min(0.96, line.confidence * 0.82 + confidenceBoost))
        }
        return nil
    }

    private func findFuelType(in lines: [OCRTextLine]) -> Match<String>? {
        for line in lines {
            let normalized = folded(line.text)
            let value: String?
            if containsAny(normalized, ["diesel", "дизел", "дизелово"]) {
                value = "Diesel"
            } else if containsAny(normalized, ["petrol", "gasoline", "бензин", "benzin"]) {
                value = "Petrol"
            } else if containsAny(normalized, ["autogas", "lpg", "пропан-бутан"]) {
                value = "LPG"
            } else {
                value = nil
            }

            if let value {
                return Match(value: value, confidence: min(0.95, line.confidence * 0.9 + 0.05))
            }
        }
        return nil
    }

    private func findFuelBrand(in lines: [OCRTextLine]) -> Match<String>? {
        let fuelKeywords = [
            "diesel", "дизел", "petrol", "gasoline", "бензин", "benzin",
            "v-power", "vpower", "ultimate", "maxxmotion", "ecto"
        ]

        for line in lines {
            let normalized = folded(line.text)
            guard containsAny(normalized, fuelKeywords) else { continue }

            var brand = line.text
            for pattern in [
                #"(?i)\b(?:shell|omv|lukoil|lidl|kaufland|billa)\b"#,
                #"(?i)шел(?:л)?"#,
                #"(?i)\b(?:diesel|petrol|gasoline|benzin)\b"#
            ] {
                brand = replacing(pattern, in: brand, with: " ")
            }
            for pattern in [
                #"(?i)бензин"#,
                #"(?i)дизелово?"#,
                #"(?i)пропан[- ]?бутан"#
            ] {
                brand = replacing(pattern, in: brand, with: " ")
            }

            brand = brand
                .replacingOccurrences(of: #"[^\p{L}\p{N}]+$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^[^\p{L}\p{N}]+"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !brand.isEmpty, brand.count <= 100 {
                return Match(value: brand, confidence: max(0.35, line.confidence * 0.75))
            }
        }
        return nil
    }

    private func findReceiptNumber(in lines: [OCRTextLine]) -> Match<String>? {
        let labelPattern = #"(?i)(?:receipt(?:\s*(?:no|number))?|invoice(?:\s*(?:no|number))?|document(?:\s*(?:no|number))?|фискален\s+бон|фактура|документ\s*(?:№|номер|no)?)"#
        let numberPattern = #"(?i)\b([A-Z0-9][A-Z0-9/-]{3,19})\b"#

        for (index, line) in lines.enumerated() {
            guard folded(line.text).range(of: labelPattern, options: .regularExpression) != nil else { continue }
            for offset in 0...2 where index + offset < lines.count {
                let candidates = captures(numberPattern, in: lines[index + offset].text)
                    .filter { $0.rangeOfCharacter(from: .decimalDigits) != nil }
                if let number = candidates.first {
                    return Match(value: number, confidence: min(0.92, lines[index + offset].confidence * 0.85))
                }
            }
        }
        return nil
    }

    private func findCurrency(in text: String) -> String? {
        let normalized = folded(text)
        if containsAny(normalized, ["eur", "€", "евро"]) { return "EUR" }
        if containsAny(normalized, ["bgn", "лв", "лева", "лев"]) { return "BGN" }
        if containsAny(normalized, ["usd", "$", "долар"]) { return "USD" }
        if containsAny(normalized, ["gbp", "£", "паунд"]) { return "GBP" }
        return nil
    }

    private func parseDate(_ value: String, preferDayFirst: Bool) -> Date? {
        let components = value.split(whereSeparator: { $0 == "." || $0 == "/" || $0 == "-" })
            .compactMap { Int($0) }
        guard components.count == 3 else { return nil }

        let year: Int
        let month: Int
        let day: Int
        if components[0] > 999 {
            (year, month, day) = (components[0], components[1], components[2])
        } else {
            let first = components[0]
            let second = components[1]
            year = components[2]
            if first > 12 {
                (day, month) = (first, second)
            } else if second > 12 {
                (month, day) = (first, second)
            } else if preferDayFirst {
                (day, month) = (first, second)
            } else {
                (month, day) = (first, second)
            }
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        var dateComponents = DateComponents()
        dateComponents.year = year
        dateComponents.month = month
        dateComponents.day = day
        guard let date = calendar.date(from: dateComponents),
              calendar.component(.day, from: date) == day,
              calendar.component(.month, from: date) == month,
              calendar.component(.year, from: date) == year else {
            return nil
        }
        return date
    }

    private func parseDecimal(_ raw: String) -> Decimal? {
        var value = raw
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00a0}", with: "")

        let comma = value.lastIndex(of: ",")
        let dot = value.lastIndex(of: ".")
        if let comma, let dot {
            let decimalSeparator = comma > dot ? "," : "."
            let groupingSeparator = decimalSeparator == "," ? "." : ","
            value = value.replacingOccurrences(of: groupingSeparator, with: "")
            if decimalSeparator == "," {
                value = value.replacingOccurrences(of: ",", with: ".")
            }
        } else if let separator = comma ?? dot {
            let fractionCount = value.distance(from: value.index(after: separator), to: value.endIndex)
            if fractionCount == 0 || fractionCount > 3 {
                value = value.replacingOccurrences(of: ",", with: "")
                    .replacingOccurrences(of: ".", with: "")
            } else {
                value = value.replacingOccurrences(of: ",", with: ".")
            }
        }

        return Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
    }

    private func captures(_ pattern: String, in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let range = Range(NSRange(text.startIndex..., in: text), in: text) else {
            return []
        }
        return expression.matches(in: text, range: NSRange(range, in: text)).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[captureRange])
        }
    }

    private func firstCapture(_ pattern: String, in text: String) -> String? {
        captures(pattern, in: text).first
    }

    private func normalizeNumericOCR(_ text: String) -> String {
        let pattern = #"(?<![\p{L}\p{N}])([0-9OoОо]+(?:[.,][0-9OoОо]+)*)(?![\p{L}\p{N}])"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }

        let mutableText = NSMutableString(string: text)
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let tokenRange = Range(match.range(at: 1), in: text) else { continue }
            let normalized = text[tokenRange]
                .replacingOccurrences(of: "O", with: "0")
                .replacingOccurrences(of: "o", with: "0")
                .replacingOccurrences(of: "О", with: "0")
                .replacingOccurrences(of: "о", with: "0")
            mutableText.replaceCharacters(in: match.range(at: 1), with: normalized)
        }
        return mutableText as String
    }

    private func folded(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private func containsAny(_ value: String, _ candidates: [String]) -> Bool {
        candidates.contains { value.contains(folded($0)) }
    }

    private func replacing(_ pattern: String, in value: String, with replacement: String) -> String {
        value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
}

private struct Match<Value> {
    let value: Value
    let confidence: Double
}

private struct TotalMatch {
    let amount: Decimal
    let currency: String?
    let confidence: Double
}
