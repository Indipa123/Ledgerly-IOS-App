// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LedgerlyDomain",
    platforms: [.macOS(.v14)],
    products: [.library(name: "LedgerlyDomain", targets: ["LedgerlyDomain"])],
    targets: [
        .target(
            name: "LedgerlyDomain",
            path: "Ledgerly IOS App/Ledgerly IOS App",
            exclude: [
                "App", "Assets", "ViewModels", "Views",
                "Services/AuthSession.swift",
                "Services/CloudLedgerSync.swift",
                "Services/CloudLibraryController.swift", "Services/AccountPhotoStore.swift", "Services/LedgerNotificationService.swift",
                "Services/FirebaseAccountDeletionClient.swift",
                "Services/CurrentLocationService.swift",
                "Services/PlaceArrivalMonitor.swift",
                "Services/PermissionOverviewService.swift",
                "Services/PlaceAutocompleteService.swift",
                "Services/SeedCategoryModel.swift",
                "Services/ShoppingTripStore.swift",
                "Services/ShoppingActivityManager.swift",
                "Services/BudgetWidgetPublisher.swift",
                "Models/ShoppingActivityAttributes.swift",
                "Models/QuickAddShoppingItemIntent.swift",
                "Services/ReceiptRecognitionService.swift", "Services/ReceiptImageStore.swift"
            ],
            sources: [
                "Models/LedgerEntry.swift",
                "Models/LifeEvent.swift",
                "Models/SplitBill.swift",
                "Models/ShoppingTrip.swift",
                "Models/BudgetWidgetSnapshot.swift",
                "Models/EmailChangeWorkflow.swift",
                "Models/AccountDeletionWorkflow.swift",
                "Models/StatementReconciliation.swift",
                "Models/ReconciliationMatcher.swift",
                "Models/CategoryBudget.swift",
                "Models/CloudRecord.swift",
                "Models/LedgerCalculations.swift",
                "Models/AppLockTiming.swift",
                "Services/AppLockService.swift",
                "Models/LedgerReminder.swift",
                "Models/BudgetAlertPreferences.swift",
                "Models/ReceiptSuggestions.swift",
                "Models/ReceiptReviewDraft.swift",
                "Models/ReceiptPageArchive.swift",
                "Models/CloudLibraryRecord.swift",
                "Models/InsightCalculations.swift",
                "Models/LedgerPlace.swift",
                "Models/CategoryMemory.swift",
                "Models/CategoryHistory.swift",
                "Models/CategoryEvaluation.swift",
                "Models/PersonalCategoryLearning.swift",
                "Models/PersonalCategoryCalibration.swift",
                "Models/PersonalCategoryEvaluationExport.swift",
                "Models/PersonalRetrainingPolicy.swift",
                "Services/PersonalCategoryTrainer.swift",
                "Models/CategorySuggestionPolicy.swift",
                "Models/TransactionReport.swift",
                "Services/ReportPDFRenderer.swift",
                "Services/ReportExportFile.swift",
                "Models/PlaceSearchMatching.swift",
                "Models/PlaceArrivalPolicy.swift",
                "Models/PlaceVisit.swift",
                "Models/PlaceNotificationPreferences.swift",
                "Services/CoreDataModel.swift",
                "Services/LedgerRepository.swift"
            ]
        ),
        .testTarget(
            name: "LedgerlyDomainTests",
            dependencies: ["LedgerlyDomain"]
        )
    ]
)
