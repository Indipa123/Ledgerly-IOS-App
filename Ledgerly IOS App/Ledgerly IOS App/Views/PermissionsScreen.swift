import SwiftUI

struct PermissionsScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @StateObject private var access = PermissionOverviewService()

    var body: some View {
        Form {
            Section {
                Text("You control access to your location, camera and notifications.")
                Button("Open Ledgerly Settings", systemImage: "gearshape") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            } footer: {
                Text("The status refreshes when you return to Ledgerly.")
            }
            accessSection("Current location", symbol: "location.fill", status: access.currentLocation)
            accessSection("Arrival monitoring", symbol: "mappin.and.ellipse", status: access.arrivalMonitoring)
            accessSection("Notifications", symbol: "bell.fill", status: access.notifications)
            accessSection("Camera", symbol: "camera.fill", status: access.camera)
            Section {
                LabeledContent("Access", value: "Selected photo only")
                Text("Ledgerly can access only the photos you choose.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } header: {
                Label("Receipt photos", systemImage: "photo.on.rectangle")
            }
            accessSection("Device authentication", symbol: "lock.shield", status: access.authentication)
            accessSection("Live Activities", symbol: "timer", status: access.liveActivities)
        }
        .navigationTitle("Permissions")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await access.refresh() }
            }
            .disabled(access.isRefreshing)
        }
        .task { await access.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await access.refresh() } }
        }
    }

    private func accessSection(_ title: String, symbol: String,
                               status: DeviceAccessStatus) -> some View {
        Section {
            LabeledContent("Status", value: status.label)
            Text(status.detail).font(.subheadline).foregroundStyle(.secondary)
        } header: {
            Label(title, systemImage: symbol)
        }
    }
}
