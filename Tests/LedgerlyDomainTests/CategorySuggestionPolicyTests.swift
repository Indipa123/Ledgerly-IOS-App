import Testing
@testable import LedgerlyDomain

struct CategorySuggestionPolicyTests {
    @Test func vagueBankingDescriptionsDoNotBecomeCategories() {
        #expect(!CategorySuggestionPolicy.accepts(kindPrefix: "income", title: "Bank transfer received",
                                                  label: "income|Gift", confidence: 0.90,
                                                  secondConfidence: 0.01))
        #expect(!CategorySuggestionPolicy.accepts(kindPrefix: "income", title: "Cash deposit",
                                                  label: "income|Salary", confidence: 0.90,
                                                  secondConfidence: 0.01))
        #expect(CategorySuggestionPolicy.hasDistinctiveDescription("Client paid design invoice"))
    }

    @Test func lowConfidenceWrongKindAndCloseRivalsAbstain() {
        let title = "Client paid design invoice"
        #expect(!CategorySuggestionPolicy.accepts(kindPrefix: "income", title: title,
                                                  label: "expense|Shopping", confidence: 0.9,
                                                  secondConfidence: 0.1))
        #expect(!CategorySuggestionPolicy.accepts(kindPrefix: "income", title: title,
                                                  label: "income|Freelance", confidence: 0.29,
                                                  secondConfidence: 0.01))
        #expect(!CategorySuggestionPolicy.accepts(kindPrefix: "income", title: title,
                                                  label: "income|Freelance", confidence: 0.60,
                                                  secondConfidence: 0.36))
        #expect(CategorySuggestionPolicy.accepts(kindPrefix: "income", title: title,
                                                 label: "income|Freelance", confidence: 0.60,
                                                 secondConfidence: 0.35))
    }
}
