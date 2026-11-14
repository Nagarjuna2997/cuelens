import SwiftUI

struct PracticeView: View {
    let model: AppModel
    private var sessions: [MeetingSession] {
        model.history.filter { $0.assistantID == model.selectedAssistantID && $0.practiceStyle != nil }
    }
    private var attempts: [PracticeAttempt] { sessions.flatMap { $0.practiceAttempts ?? [] }.sorted { $0.date > $1.date } }

    var body: some View {
        if model.live.isOpen { StudioView(model: model, practice: true) }
        else {
            HSplitView {
                SessionSetupView(model: model, practice: true).frame(minWidth: 420, maxWidth: .infinity)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Your practice progress").font(.title2.weight(.semibold))
                        if attempts.isEmpty {
                            Text("Complete a baseline interview to see your feedback and delivery measurements here.")
                                .foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 24) {
                                metric("Sessions", value: String(sessions.count))
                                metric("Answers", value: String(attempts.count))
                            }
                            let due = attempts.filter { ($0.nextReview ?? .distantFuture) <= Date() }
                            if !due.isEmpty {
                                Text("Ready to review").font(.headline)
                                ForEach(due) { attempt in
                                    Button(attempt.reviewTopic ?? attempt.question) { review(attempt) }
                                        .buttonStyle(.link)
                                }
                            }
                            ForEach(attempts.prefix(20)) { attempt in
                                VStack(alignment: .leading, spacing: 9) {
                                    Text(attempt.question).font(.headline)
                                    Text(attempt.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                    PracticeMetricsView(metrics: attempt.metrics)
                                    Text(attempt.feedbackStatus).font(.caption).foregroundStyle(.secondary)
                                    if let error = attempt.feedbackError {
                                        Text(error).font(.caption).foregroundStyle(.secondary)
                                    }
                                    DisclosureGroup("Your answer") {
                                        Text(attempt.response).textSelection(.enabled).font(.callout)
                                    }
                                    if !attempt.feedback.isEmpty {
                                        DisclosureGroup(attempt.effectiveFeedbackState == .completed ? "Feedback" : "Partial feedback") {
                                            Text(attempt.feedback).textSelection(.enabled).font(.callout)
                                        }
                                    }
                                    if let review = attempt.nextReview {
                                        Text("Review \(review.formatted(date: .abbreviated, time: .omitted))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Button("Practice This Topic") { review(attempt) }
                                }
                                .padding(14).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 280, idealWidth: 380, maxWidth: .infinity)
            }
        }
    }
    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(.title.monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func review(_ attempt: PracticeAttempt) {
        guard !model.live.isOpen, model.live.pendingSave == nil else { return }
        guard let assistant = model.activeAssistants.first(where: { $0.id == model.selectedAssistantID }) else { return }
        let style = sessions.first(where: { $0.practiceAttempts?.contains(where: { $0.id == attempt.id }) == true })?.practiceStyle ?? .technical
        model.live.start(assistant: assistant, settings: model.preferences,
                         options: .init(microphone: model.preferences.sessionMicrophone ?? true,
                                        meetingAudio: false, save: true, practice: true,
                                        previewCamera: model.preferences.startCameraWithSession ?? false, practiceStyle: style,
                                        reviewTopic: attempt.reviewTopic ?? attempt.question))
        guard model.live.isOpen else { return }
        model.startCameraForSessionIfEnabled()
        model.overlay.register()
        model.overlay.show(focus: true)
        model.minimizeMainWindow()
    }
}

struct PracticeMetricsView: View {
    let metrics: PracticeMetrics
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits {
                HStack(spacing: 15) {
                    Text("\(metrics.wordCount) words")
                    Text("\(metrics.fillerCount) fillers")
                    if let pace = metrics.wordsPerMinute { Text(String(format: "%.0f words/min", pace)) }
                    if let pauses = metrics.longPauseCount { Text("\(pauses) long pauses") }
                }
                Text("\(metrics.wordCount) words · \(metrics.fillerCount) fillers")
            }.font(.caption.monospacedDigit())
            if !metrics.repeatedPhrases.isEmpty {
                Text("Repeated: " + metrics.repeatedPhrases.prefix(3).joined(separator: ", ")).font(.caption)
            }
            Text("Transcript-based estimates. Speech recognition can omit fillers.").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
