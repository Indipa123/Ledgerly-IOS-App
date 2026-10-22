import SwiftUI
import Charts

struct PersonalCategoryReliabilityScreen: View {
    @ObservedObject var learning: PersonalCategoryLearningController
    let attemptID: UUID
    @State private var accountScope: String
    @State private var shownOnly = false

    init(learning: PersonalCategoryLearningController, attemptID: UUID) {
        self.learning = learning
        self.attemptID = attemptID
        _accountScope = State(initialValue: learning.accountScope)
    }

    private var report: PersonalCategoryReliabilityReport? {
        guard accountScope == learning.accountScope else { return nil }
        return learning.archive.attempts.first { $0.id == attemptID }?.metrics.reliability
    }

    var body: some View {
        Group {
            if let report { results(report) }
            else {
                ContentUnavailableView("Chart unavailable", systemImage: "chart.xyaxis.line",
                    description: Text("This attempt has no saved reliability data, was cleared, or belongs to a different account. Return to current model results."))
            }
        }
        .navigationTitle("Score reliability")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func results(_ report: PersonalCategoryReliabilityReport) -> some View {
        let series = shownOnly ? report.shown : report.all
        return List {
            Section {
                Picker("Predictions", selection: $shownOnly) {
                    Text("All scores").tag(false)
                    Text("Shown suggestions").tag(true)
                }.pickerStyle(.segmented)
                Text(shownOnly
                    ? "Only predictions that passed the confidence, similarity and margin checks."
                    : "All valid model scores on the reserved test slice, including predictions Ledgerly would hide and ask you to categorise instead.")
                    .font(.subheadline).foregroundStyle(.secondary)
                LabeledContent("Scored predictions", value: "\(series.count)")
                LabeledContent("Correct predictions", value: "\(series.correct) of \(series.count)")
                LabeledContent("Average model score", value: percent(series.meanScore))
                LabeledContent("Observed correctness", value: percent(series.accuracy))
                LabeledContent("Binned score gap", value: percent(series.binnedGap))
                if report.unscored > 0 {
                    Text("\(report.unscored) test transactions had no valid model score and are excluded from this chart.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Model score versus observed correctness") {
                if series.count > 0 {
                    Chart {
                        ForEach([0.0, 1.0], id: \.self) { value in
                            LineMark(x: .value("Average score", value), y: .value("Observed correctness", value))
                                .foregroundStyle(.secondary)
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        }
                        ForEach(series.bins.filter { $0.count > 0 }) { bin in
                            PointMark(x: .value("Average score", bin.meanScore ?? 0),
                                      y: .value("Observed correctness", bin.accuracy ?? 0))
                                .foregroundStyle(Palette.cranberry)
                                .symbolSize(75)
                        }
                    }
                    .chartXScale(domain: 0...1)
                    .chartYScale(domain: 0...1)
                    .chartXAxis {
                        AxisMarks(values: [0.0, 0.25, 0.5, 0.75, 1.0]) { value in
                            AxisGridLine()
                            AxisValueLabel { Text(percent(value.as(Double.self))) }
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: [0.0, 0.25, 0.5, 0.75, 1.0]) { value in
                            AxisGridLine()
                            AxisValueLabel { Text(percent(value.as(Double.self))) }
                        }
                    }
                    .chartXAxisLabel("Average model score")
                    .chartYAxisLabel("Observed correctness")
                    .frame(height: 240)
                    .accessibilityHidden(true)
                    Text("Each dot represents one populated score range. Below the dashed reference, scores were higher than observed correctness; above it, they were lower. The full numbers are listed below.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("No scored predictions in this selection. Empty score ranges are not plotted as zero accuracy.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Score ranges") {
                ForEach(series.bins) { bin in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(range(bin.index)).font(.headline)
                        if bin.count > 0 {
                            Text("\(bin.correct) correct of \(bin.count) predictions")
                            Text("Average score \(percent(bin.meanScore)) · observed correctness \(percent(bin.accuracy))")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else { Text("No samples").foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 3)
                }
            }
            Section("Reading these results") {
                Text("Model scores are uncalibrated scores, not proven probabilities. This chart diagnoses the difference; it does not recalibrate the model or change its suggestion gate.")
                Text("The gap averages each range's absolute difference between mean score and observed correctness, weighted by its sample count. Smaller gaps mean closer agreement on this test only. Small samples, empty ranges and repeated checks can make results look better than future performance.")
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func percent(_ value: Double?) -> String {
        value?.formatted(.percent.precision(.fractionLength(0))) ?? "No samples"
    }

    private func range(_ index: Int) -> String {
        let start = percent(Double(index) / 5)
        let end = percent(Double(index + 1) / 5)
        return index == 4 ? "\(start)–\(end)" : "\(start) to below \(end)"
    }
}
