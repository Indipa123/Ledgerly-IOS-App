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
                "Services/AppLockService.swift", "Services/AuthSession.swift",
                "Services/CloudLedgerSync.swift"
            ],
            sources: [
                "Models/LedgerEntry.swift",
                "Models/CloudRecord.swift",
                "Models/LedgerCalculations.swift",
                "Models/AppLockTiming.swift",
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
