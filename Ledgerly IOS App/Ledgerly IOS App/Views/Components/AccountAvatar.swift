import SwiftUI

/// Every image URL comes from the current Firebase user, including linked providers.
/// A different account recreates the image view so an old download cannot show its photo.
struct AccountAvatar: View {
    let accountID: String?
    let name: String?
    let photoURL: URL?
    var size: CGFloat = 88
    @State private var customPhoto: UIImage?
    @State private var customPhotoOwner: String?

    private var initials: String {
        (name ?? "").split(whereSeparator: \.isWhitespace).prefix(2)
            .compactMap(\.first).map(String.init).joined().uppercased()
    }

    var body: some View {
        ZStack {
            Circle().fill(Palette.plum)
            if let customPhoto, accountID != nil, customPhotoOwner == accountID {
                Image(uiImage: customPhoto).resizable().scaledToFill()
            } else {
            AsyncImage(url: photoURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    ZStack {
                        if initials.isEmpty {
                            Image(systemName: "person.fill")
                                .font(.system(size: size * 0.4, weight: .medium))
                        } else {
                            Text(initials)
                                .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                                .minimumScaleFactor(0.5).lineLimit(1).padding(size * 0.12)
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                }
            }
            .id(accountID)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(.white.opacity(0.3), lineWidth: size > 60 ? 3 : 1.5) }
        .task(id: accountID) { customPhotoOwner = accountID; customPhoto = accountID.flatMap { AccountPhotoStore.data($0).flatMap(UIImage.init(data:)) } }
        .onReceive(NotificationCenter.default.publisher(for: AccountPhotoStore.changed)) { notification in
            guard notification.object as? String == accountID else { return }
            customPhotoOwner = accountID
            customPhoto = accountID.flatMap { AccountPhotoStore.data($0).flatMap(UIImage.init(data:)) }
        }
        .accessibilityHidden(true)
    }
}

struct AccountProfileHeader: View {
    let accountID: String?
    let name: String
    let email: String?
    let photoURL: URL?
    let provider: String

    var body: some View {
        VStack(spacing: 12) {
            AccountAvatar(accountID: accountID, name: accountID == nil ? nil : name, photoURL: photoURL)
            Text(name).font(.title2.bold()).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let email, !email.isEmpty {
                Text(email).font(.subheadline).multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(provider).font(.footnote.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.white.opacity(0.14), in: Capsule())
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(colors: [Palette.cranberry, Palette.plum],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }
}

struct SettingsMenuRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    var color: Color = Palette.iconPlum
    var titleColor: Color = .primary

    var body: some View {
        HStack(spacing: 14) {
            LedgerIconTile(icon: .init(symbol: symbol, color: color), size: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(titleColor)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 5)
        .frame(minHeight: 48, alignment: .leading)
    }
}
