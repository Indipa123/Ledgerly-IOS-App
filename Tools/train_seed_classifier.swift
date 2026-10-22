// Run on macOS with: swift Tools/train_seed_classifier.swift
// Training examples are generic descriptors, never a user's transactions.
import CreateML
import Foundation

let examples: [(String, [String])] = [
    ("expense|Food & Drink", ["restaurant dinner", "cafe coffee", "bakery lunch", "pizza takeaway", "kottu dinner", "rice and curry lunch", "food delivery", "tea shop snack", "uber eats meal"]),
    ("expense|Groceries", ["keells supermarket", "cargills food city", "arpico supermarket", "grocery shopping", "vegetables and fruit market", "milk and eggs", "supermarket groceries", "fresh produce shop", "weekly groceries"]),
    ("expense|Transport", ["bus ticket", "train fare", "pickme ride", "uber taxi", "fuel station", "petrol refill", "parking fee", "highway toll", "three wheeler fare"]),
    ("expense|Bills & Utilities", ["electricity bill", "water bill", "mobile phone bill", "internet broadband", "dialog data package", "mobitel reload", "utility payment", "telephone bill", "wifi subscription"]),
    ("expense|Rent", ["monthly house rent", "apartment rent", "room rental", "boarding room rent", "landlord payment", "rent for october", "lease payment", "hostel rent", "flat rental"]),
    ("expense|Education", ["university tuition", "course fee", "school books", "exam registration", "online learning course", "textbook purchase", "lecture fee", "student supplies", "training workshop"]),
    ("expense|Health", ["doctor consultation", "pharmacy medicine", "hospital bill", "dental treatment", "medical lab test", "prescription medicine", "clinic appointment", "eye checkup", "healthcare payment"]),
    ("expense|Shopping", ["clothes shopping", "shoes purchase", "electronics store", "new headphones", "fashion boutique", "online shopping order", "homeware purchase", "computer accessories", "department store"]),
    ("expense|Entertainment", ["cinema ticket", "movie night", "concert ticket", "netflix subscription", "spotify premium", "gaming purchase", "music festival", "theatre show", "streaming service"]),
    ("expense|Personal Care", ["haircut salon", "barber shop", "skincare products", "shampoo and soap", "beauty salon", "spa treatment", "cosmetics purchase", "grooming supplies", "personal hygiene"]),
    ("expense|Gifts & Donations", ["birthday gift", "wedding gift", "charity donation", "temple donation", "present for friend", "fundraiser contribution", "gift shop", "donation to charity", "anniversary present"]),
    ("income|Salary", ["monthly salary", "salary payment", "payroll deposit", "wages for month", "employer salary", "monthly pay", "salary credit", "payday income", "employment earnings"]),
    ("income|Freelance", ["freelance project", "client invoice paid", "contract design work", "freelance writing", "consulting fee", "side gig payment", "contractor payment", "project commission", "independent work"]),
    ("income|Business", ["business sales", "shop revenue", "customer order payment", "store sales income", "business profit", "product sales", "trading revenue", "small business income", "service sales"]),
    ("income|Bonus", ["work bonus", "performance bonus", "year end bonus", "incentive payment", "annual bonus", "employee reward", "holiday bonus", "quarterly bonus", "extra payroll bonus"]),
    ("income|Gift", ["birthday money gift", "cash gift from family", "money from parents", "wedding gift money", "allowance from family", "gift received", "family transfer gift", "present money", "relative gave money"])
]

let texts = examples.flatMap { label, phrases in
    phrases.map { "\(label.components(separatedBy: "|")[0]) \($0)" }
}
let labels = examples.flatMap { label, phrases in
    Array(repeating: label, count: phrases.count)
}
let table = try MLDataTable(dictionary: ["text": texts, "label": labels])
let parameters = MLTextClassifier.ModelParameters(validation: .none, algorithm: .maxEnt(revision: 1))
let classifier = try MLTextClassifier(trainingData: table, textColumn: "text", labelColumn: "label", parameters: parameters)
let output = URL(fileURLWithPath: "Ledgerly IOS App/Ledgerly IOS App/Assets/SeedCategoryClassifier.mlmodel")
try classifier.write(to: output, metadata: .init(author: "Ledgerly", shortDescription: "Generic on-device category suggestions for first-time descriptions"))
print("Wrote \(output.path) from \(texts.count) generic examples")
