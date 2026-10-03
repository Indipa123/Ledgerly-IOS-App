import SwiftUI
import UIKit

enum Palette {
    static let cranberry = Color(red: 0.77, green: 0.20, blue: 0.34)
    static let plum = Color(red: 0.39, green: 0.14, blue: 0.27)
    static let ink = Color.primary
    static let cream = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.08, green: 0.07, blue: 0.10, alpha: 1)
            : UIColor(red: 1, green: 0.973, blue: 0.957, alpha: 1)
    })
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let mint = Color(red: 0.12, green: 0.62, blue: 0.48)
    static let coral = Color(red: 0.91, green: 0.29, blue: 0.41)
}
