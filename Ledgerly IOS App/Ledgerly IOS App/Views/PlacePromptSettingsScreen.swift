import SwiftUI

struct PlacePromptSettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var monitor: PlaceArrivalMonitor
    private let accountKey: String
    @State private var enabled: Bool
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var automaticMuting: Bool
    @State private var departureEnabled: Bool
    @State private var arrivalSound: PlaceAlertSound
    @State private var departureSound: PlaceAlertSound
    @State private var testInProgress = false
    @State private var testMessage: String?
    @State private var testFailed = false

    init(monitor: PlaceArrivalMonitor) {
        self.monitor = monitor
        accountKey = monitor.accountKey
        let hours = monitor.quietHours
        _enabled = State(initialValue: hours.enabled)
        _startTime = State(initialValue: Self.time(for: hours.startMinute))
        _endTime = State(initialValue: Self.time(for: hours.endMinute))
        _automaticMuting = State(initialValue: monitor.automaticMutingEnabled)
        _departureEnabled = State(initialValue: monitor.notificationPreferences.departureEnabled)
        _arrivalSound = State(initialValue: monitor.notificationPreferences.arrivalSound)
        _departureSound = State(initialValue: monitor.notificationPreferences.departureSound)
    }

    private var draft: PlaceQuietHours {
        PlaceQuietHours(enabled: enabled, startMinute: Self.minute(for: startTime),
                        endMinute: Self.minute(for: endTime))
    }

    var body: some View {
        Form {
            Section {
                Toggle("Departure reminders", isOn: $departureEnabled)
            } header: {
                Text("When you leave")
            } footer: {
                Text("Get a reminder when you leave a place with monitoring enabled.")
            }
            Section {
                Picker("Arrival sound", selection: $arrivalSound) {
                    ForEach(PlaceAlertSound.allCases) { Text($0.title).tag($0) }
                }
                Picker("Departure sound", selection: $departureSound) {
                    ForEach(PlaceAlertSound.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!departureEnabled)
                DisclosureGroup("Try notification sounds") {
                    Button("Test arrival notification", systemImage: "arrow.down.right.circle") {
                        test(.arrival, sound: arrivalSound)
                    }
                    .disabled(testInProgress)
                    Button("Test departure notification", systemImage: "arrow.up.right.circle") {
                        test(.departure, sound: departureSound)
                    }
                    .disabled(testInProgress || !departureEnabled)
                    if let testMessage {
                        Text(testMessage).font(.footnote)
                            .foregroundStyle(testFailed ? Color.red : Color.secondary)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    Text("Tests arrive after five seconds, including during quiet hours.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Notification sounds")
            } footer: {
                Text("Silent mode and Focus may silence notification sounds.")
            }
            Section {
                Toggle("Mute after repeated dismissals", isOn: $automaticMuting)
            } header: {
                Text("Automatic muting")
            } footer: {
                Text("Mute a place after you dismiss reminders on three visits. You can resume alerts from that place.")
            }
            Section {
                Toggle("Quiet hours for places", isOn: $enabled)
                if enabled {
                    DatePicker("From", selection: $startTime, displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: $endTime, displayedComponents: .hourAndMinute)
                }
                if enabled && !draft.isValid {
                    Text("Choose different start and end times.")
                        .font(.footnote).foregroundStyle(.red)
                }
            } footer: {
                Text("Pause place alerts during these hours. Uses your local time.")
            }
            Section {
                DisclosureGroup("Help with place alerts") {
                    Text("Allow Always location, notifications and Sounds in device Settings. Keep Background App Refresh on.")
                    Text("You do not need to open Ledgerly for an arrival or departure alert. iOS can wake it in the background for a saved boundary crossing, including after it has been closed. Delivery timing is controlled by iOS.")
                    Text("Arrival and departure alerts depend on crossing the place’s radius and may be delayed. Estimated departures found after reopening do not send alerts.")
                    Text("Muted places and quiet hours pause both alerts. Visit history and automatic shopping trips continue; payment reminders have their own settings.")
                    Text("Recording an expense or choosing Resume alerts resets automatic muting. Turning it off keeps any places you muted yourself.")
                    Text("Sound tests check delivery only, without recording a visit or purchase.")
                    Button("Open device Settings") { openDeviceSettings() }
                }
                if monitor.needsSettings {
                    Button("Review device permissions") { openDeviceSettings() }
                }
            } footer: {
                Text("Applies to this account on this device.")
            }
        }
        .navigationTitle("Place notifications")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    guard monitor.accountKey == accountKey else { dismiss(); return }
                    if monitor.setQuietHours(draft) {
                        monitor.setAutomaticMutingEnabled(automaticMuting)
                        monitor.setNotificationPreferences(PlaceNotificationPreferences(
                            departureEnabled: departureEnabled, arrivalSound: arrivalSound,
                            departureSound: departureSound))
                        dismiss()
                    }
                }
                .disabled(enabled && !draft.isValid)
            }
        }
        .onChange(of: monitor.accountKey) { _, _ in dismiss() }
    }

    private func openDeviceSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    private func test(_ kind: PlaceAlertKind, sound: PlaceAlertSound) {
        guard monitor.accountKey == accountKey else { dismiss(); return }
        testInProgress = true
        testMessage = nil
        Task { @MainActor in
            defer { testInProgress = false }
            do {
                try await monitor.sendTestNotification(kind, sound: sound)
                guard monitor.accountKey == accountKey else { return }
                testFailed = false
                testMessage = "Test scheduled for five seconds from now. Lock your phone to check it."
            } catch {
                guard monitor.accountKey == accountKey else { return }
                testFailed = true
                testMessage = error.localizedDescription
            }
        }
    }

    private static func time(for minute: Int) -> Date {
        Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60,
                              second: 0, of: .now) ?? .now
    }

    private static func minute(for date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
