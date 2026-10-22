// Run on macOS with:
// swiftc -module-cache-path /private/tmp/ledgerly-swift-module-cache \
//   Tools/EvaluateSeedClassifier/main.swift \
//   'Ledgerly IOS App/Ledgerly IOS App/Models/CategorySuggestionPolicy.swift' \
//   -o /private/tmp/ledgerly-evaluate-seed
// TMPDIR=/private/tmp/ledgerly-coreml-tmp /private/tmp/ledgerly-evaluate-seed
// The first fixed sample was used to choose the policy; the final sample was added
// afterward and must not be used to tune it.
import CoreML
import Foundation
import NaturalLanguage

let holdout: [(String, [String])] = [
    ("expense|Food & Drink", ["breakfast at the cafe", "dinner takeaway order", "lunch at restaurant"]),
    ("expense|Groceries", ["weekly supermarket run", "fruit and vegetables", "keells food shopping"]),
    ("expense|Transport", ["bus fare to colombo", "fuel for my car", "pickme trip home"]),
    ("expense|Bills & Utilities", ["paid the electricity account", "mobile data reload", "home internet payment"]),
    ("expense|Rent", ["paid my landlord", "october apartment lease", "boarding house payment"]),
    ("expense|Education", ["paid university semester fee", "books for class", "exam application payment"]),
    ("expense|Health", ["medicine from pharmacy", "doctor visit fee", "dental clinic appointment"]),
    ("expense|Shopping", ["bought a new shirt", "headphones from electronics shop", "shoes from mall"]),
    ("expense|Entertainment", ["tickets for a movie", "monthly spotify plan", "gaming subscription"]),
    ("expense|Personal Care", ["trim at the barber", "beauty products", "shampoo and skincare"]),
    ("expense|Gifts & Donations", ["donated to a fundraiser", "birthday present for sister", "temple charity gift"]),
    ("income|Salary", ["employer paid wages", "monthly salary received", "payroll credit to account"]),
    ("income|Freelance", ["client paid design invoice", "consulting contract income", "payment for side project"]),
    ("income|Business", ["revenue from my shop", "customer paid for order", "income from product sales"]),
    ("income|Bonus", ["yearly performance incentive", "quarterly bonus received", "extra reward from employer"]),
    ("income|Gift", ["birthday cash from aunt", "money from my parents", "family gave me a gift"])
]

// These descriptions have no unambiguous category in the bundled taxonomy.
let unknown: [(String, String)] = [
    ("expense", "Digital TECHLABS"), ("expense", "bank transfer"),
    ("expense", "receipt payment"), ("expense", "insurance premium"),
    ("expense", "loan repayment"), ("expense", "government tax"),
    ("expense", "John Smith"), ("expense", "cash withdrawal"),
    ("income", "bank transfer received"), ("income", "investment dividend"),
    ("income", "tax refund"), ("income", "cash deposit")
]

let finalKnown: [(String, String)] = [
    ("expense|Food & Drink", "coffee at barista"),
    ("expense|Groceries", "vegetables from the market"),
    ("expense|Transport", "train ride to galle"),
    ("expense|Bills & Utilities", "dialog broadband bill"),
    ("expense|Rent", "payment for rented flat"),
    ("expense|Education", "tuition for maths class"),
    ("expense|Health", "tablets from the chemist"),
    ("expense|Shopping", "purchased a laptop"),
    ("expense|Entertainment", "cinema entry for friday"),
    ("expense|Personal Care", "face cream and haircut"),
    ("expense|Gifts & Donations", "charity collection at office"),
    ("income|Salary", "wages credited by employer"),
    ("income|Freelance", "invoice settled by design client"),
    ("income|Business", "revenue from customer orders"),
    ("income|Bonus", "performance incentive from work"),
    ("income|Gift", "gift cash for birthday")
]
let finalUnknown: [(String, String)] = [
    ("expense", "ATM withdrawal"), ("expense", "internal account transfer"),
    ("expense", "insurance policy renewal"), ("expense", "loan instalment"),
    ("income", "dividend credit"), ("income", "refund from merchant"),
    ("income", "balance adjustment"), ("expense", "interest charged")
]

let source = URL(fileURLWithPath: "Ledgerly IOS App/Ledgerly IOS App/Assets/SeedCategoryClassifier.mlmodel")
let compiled = try MLModel.compileModel(at: source)
let model = try NLModel(contentsOf: compiled)

struct Result {
    let expected: String
    let phrase: String
    let predicted: String
    let confidence: Double
    let margin: Double
}

func predict(_ examples: [(String, String)]) -> [Result] {
    examples.map { label, phrase in
        let kind = String(label.split(separator: "|")[0])
        let ranked = model.predictedLabelHypotheses(for: "\(kind) \(phrase.lowercased())", maximumCount: 2)
            .sorted { $0.value > $1.value }
        return Result(expected: label, phrase: phrase,
                      predicted: ranked.first?.key ?? "",
                      confidence: ranked.first?.value ?? 0,
                      margin: (ranked.first?.value ?? 0) - (ranked.dropFirst().first?.value ?? 0))
    }
}
let results = predict(holdout.flatMap { label, phrases in phrases.map { (label, $0) } })
let unknownResults = predict(unknown.map { ("\($0.0)|unknown", $0.1) })
let finalResults = predict(finalKnown)
let finalUnknownResults = predict(finalUnknown.map { ("\($0.0)|unknown", $0.1) })

func accepts(_ result: Result) -> Bool {
    let kind = String(result.expected.split(separator: "|")[0])
    return CategorySuggestionPolicy.accepts(
        kindPrefix: kind, title: result.phrase, label: result.predicted,
        confidence: result.confidence, secondConfidence: result.confidence - result.margin)
}

func summary(_ heading: String, known: [Result], unknown: [Result]) {
    let accepted = known.filter(accepts)
    let correct = accepted.filter { $0.predicted == $0.expected }.count
    let unknownAccepted = unknown.filter(accepts)
    print("\(heading): \(known.count) known, \(unknown.count) unknown")
    print("Known: \(correct)/\(accepted.count) suggestions correct; \(accepted.count)/\(known.count) covered")
    print("Unknown: \(unknownAccepted.count)/\(unknown.count) suggested")
}
summary("Threshold selection sample", known: results, unknown: unknownResults)
summary("Final test sample", known: finalResults, unknown: finalUnknownResults)
print(String(format: "Gate: confidence ≥ %.2f, top-two margin ≥ %.2f, distinctive description",
             CategorySuggestionPolicy.minimumConfidence, CategorySuggestionPolicy.minimumMargin))
print("\nFinal test predictions:")
for result in finalResults + finalUnknownResults {
    print(String(format: "%@ | %@ -> %@ (%.3f, margin %.3f)%@",
                 result.expected, result.phrase, result.predicted, result.confidence,
                 result.margin, accepts(result) ? " SUGGESTED" : " ABSTAINED"))
}
