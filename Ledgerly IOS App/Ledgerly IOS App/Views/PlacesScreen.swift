import SwiftUI

struct PlacesScreen: View {
    var body: some View {
        ContentUnavailableView("Places are coming next", systemImage: "map", description: Text("Saved shops and spending locations will appear here. A location never proves a purchase."))
            .navigationTitle("Places")
    }
}
