import SwiftUI

struct LedgerIconDescriptor {
    let symbol: String
    let color: Color

    static func category(_ name: String, kind: EntryKind) -> Self {
        let value = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if value.contains("grocery") || value.contains("grocer") || value.contains("supermarket") {
            return .init(symbol: "cart.fill", color: Color(red: 0.34, green: 0.55, blue: 0.91))
        }
        if value.contains("food") || value.contains("dining") || value.contains("restaurant") {
            return .init(symbol: "fork.knife", color: Color(red: 0.88, green: 0.62, blue: 0.24))
        }
        if value.contains("coffee") || value.contains("cafe") {
            return .init(symbol: "cup.and.saucer.fill", color: Color(red: 0.71, green: 0.47, blue: 0.31))
        }
        if value.contains("transport") || value.contains("bus") || value.contains("travel") {
            return .init(symbol: "bus.fill", color: Color(red: 0.35, green: 0.52, blue: 0.86))
        }
        if value.contains("fuel") || value.contains("petrol") {
            return .init(symbol: "fuelpump.fill", color: Palette.coral)
        }
        if value.contains("bill") || value.contains("utilit") || value.contains("electric") {
            return .init(symbol: "bolt.fill", color: Color(red: 0.87, green: 0.60, blue: 0.22))
        }
        if value.contains("rent") || value.contains("home") || value.contains("house") {
            return .init(symbol: "house.fill", color: Palette.iconPlum)
        }
        if value.contains("educat") || value.contains("school") || value.contains("course") {
            return .init(symbol: "graduationcap.fill", color: Color(red: 0.40, green: 0.44, blue: 0.80))
        }
        if value.contains("health") || value.contains("medical") || value.contains("doctor") {
            return .init(symbol: "cross.case.fill", color: Palette.coral)
        }
        if value.contains("shop") || value.contains("cloth") {
            return .init(symbol: "bag.fill", color: Palette.cranberry)
        }
        if value.contains("entertain") || value.contains("movie") || value.contains("cinema") {
            return .init(symbol: "film.fill", color: Color(red: 0.58, green: 0.41, blue: 0.78))
        }
        if value.contains("personal") || value.contains("beauty") {
            return .init(symbol: "sparkles", color: Palette.cranberry)
        }
        if value.contains("gift") || value.contains("donat") {
            return .init(symbol: "gift.fill", color: Palette.coral)
        }
        if value.contains("salary") || value.contains("wage") || value.contains("payroll") {
            return .init(symbol: "banknote.fill", color: Palette.mint)
        }
        if value.contains("freelance") || value.contains("contract") {
            return .init(symbol: "laptopcomputer", color: Palette.mint)
        }
        if value.contains("business") {
            return .init(symbol: "briefcase.fill", color: Palette.mint)
        }
        if value.contains("bonus") {
            return .init(symbol: "star.fill", color: Palette.mint)
        }
        return kind == .income
            ? .init(symbol: "arrow.down.left", color: Palette.mint)
            : .init(symbol: "square.grid.2x2.fill", color: Palette.cranberry)
    }

    static func payment(_ kind: PaymentKind) -> Self {
        switch kind {
        case .cash: .init(symbol: "banknote.fill", color: Palette.mint)
        case .debitCard: .init(symbol: "creditcard.fill", color: Color(red: 0.35, green: 0.52, blue: 0.86))
        case .creditCard: .init(symbol: "creditcard.fill", color: Palette.iconPlum)
        case .mobileWallet: .init(symbol: "iphone.gen3", color: Palette.cranberry)
        case .bankTransfer: .init(symbol: "building.columns.fill", color: Palette.mint)
        }
    }
}

struct LedgerIconTile: View {
    let icon: LedgerIconDescriptor
    var size: CGFloat = 46

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        Image(systemName: icon.symbol)
            .font(.system(size: size * 0.43, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(icon.color)
            .frame(width: size, height: size)
            .background {
                shape.fill(LinearGradient(colors: [icon.color.opacity(0.20), icon.color.opacity(0.09)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay { shape.strokeBorder(icon.color.opacity(0.20), lineWidth: 1) }
            .accessibilityHidden(true)
    }
}
