import SwiftUI

struct BudgetQuietHoursScreen: View {
    @ObservedObject var notifications: LedgerNotificationService
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Bool
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var quietReminderSounds: Bool
    @State private var saveError: String?

    init(notifications: LedgerNotificationService) {
        self.notifications = notifications
        let hours = notifications.budgetQuietHours
        _enabled = State(initialValue: hours.enabled)
        _startTime = State(initialValue: Self.time(hours.startMinute))
        _endTime = State(initialValue: Self.time(hours.endMinute))
        _quietReminderSounds = State(initialValue: notifications.quietReminderSounds)
    }

    private var draft: BudgetQuietHours {
        BudgetQuietHours(enabled: enabled, startMinute: Self.minute(startTime), endMinute: Self.minute(endTime))
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable quiet hours", isOn: $enabled)
                DatePicker("From", selection: $startTime, displayedComponents: .hourAndMinute).disabled(!enabled)
                DatePicker("Until", selection: $endTime, displayedComponents: .hourAndMinute).disabled(!enabled)
                if enabled && !draft.isValid {
                    Text("Choose different start and end times.").foregroundStyle(.red)
                }
            } footer: {
                Text("Uses your local time, including overnight schedules.")
            }
            Section("Delivery") {
                Text("Budget warnings arrive after quiet hours end.")
                Text("Warnings show the spending recorded when you reached the limit.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Other notifications") {
                Toggle("Silence payment reminder sounds", isOn: $quietReminderSounds)
                    .disabled(!enabled)
                Text("Payment reminders still appear on time, without a sound during quiet hours.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Place alerts have separate quiet hours in Places.")
                    .foregroundStyle(.secondary)
                Text("These quiet hours apply to this device.").font(.footnote).foregroundStyle(.secondary)
            }
            if let saveError {
                Section { Text(saveError).foregroundStyle(.red) }
            }
        }
        .disabled(notifications.isUpdatingPreferences)
        .navigationTitle("Quiet hours")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if notifications.isUpdatingPreferences { ProgressView() }
                else {
                    Button("Save") {
                        Task {
                            saveError = nil
                            if await notifications.setBudgetQuietHours(draft, quietReminderSounds: quietReminderSounds) { dismiss() }
                            else { saveError = notifications.error ?? "Could not update pending alerts. Try again." }
                        }
                    }
                    .disabled(enabled && !draft.isValid)
                }
            }
        }
    }

    private static func time(_ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now
    }

    private static func minute(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
