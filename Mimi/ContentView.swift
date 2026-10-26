import MimiKit
import SwiftUI

struct ContentView: View {
    let session: MeetingSession
    @AppStorage(SettingsKey.summaryModelID) private var summaryModelID = SummaryModel.default.id
    @AppStorage(SettingsKey.isAlwaysOnTop) private var isAlwaysOnTop = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SessionButton(session: session, summaryModelID: summaryModelID)

                if session.state == .running {
                    LevelIndicator(speaker: .me, meter: session.microphoneLevel)
                    LevelIndicator(speaker: .others, meter: session.systemAudioLevel)
                }

                Spacer()

                Toggle(isOn: $isAlwaysOnTop) {
                    Image(systemName: isAlwaysOnTop ? "pin.fill" : "pin")
                }
                .toggleStyle(.button)
                .help("常に最前面に表示")
            }

            CurrentTopicView(session: session)

            Divider()

            TranscriptView(lines: session.transcript.lines)

            if let failure = session.failure {
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .frame(minWidth: 320, minHeight: 360)
        .background(WindowConfigurator(isAlwaysOnTop: isAlwaysOnTop) {
            NSApplication.shared.terminate(nil)
        })
    }
}

private struct SessionButton: View {
    let session: MeetingSession
    let summaryModelID: String

    var body: some View {
        Button {
            Task {
                if session.state == .idle {
                    await session.start(summaryModelID: summaryModelID)
                } else {
                    await session.stop()
                }
            }
        } label: {
            switch session.state {
            case .idle:
                Label("開始", systemImage: "record.circle")
            case .starting:
                Label("開始しています", systemImage: "record.circle")
            case .running:
                Label("停止", systemImage: "stop.fill")
            case .stopping:
                Label("停止しています", systemImage: "stop.fill")
            }
        }
        .disabled(session.state == .starting || session.state == .stopping)
    }
}

private struct LevelIndicator: View {
    let speaker: Speaker
    let meter: AudioLevelMeter

    var body: some View {
        HStack(spacing: 4) {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { _ in
                Circle()
                    .fill(speaker.color.opacity(0.2 + 0.8 * Double(meter.level)))
                    .frame(width: 8, height: 8)
            }
            .frame(width: 8, height: 8)
            Text(speaker.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CurrentTopicView: View {
    let session: MeetingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("今の話題")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                status
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if case let .loadingModel(progress) = session.summaryActivity {
                ProgressView(value: progress)
            }
            Text(session.currentTopic.isEmpty ? "まだありません" : session.currentTopic)
                .font(.title3)
                .foregroundStyle(session.currentTopic.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let failure = session.summaryFailure {
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch session.summaryActivity {
        case .loadingModel:
            Text("要約モデルを準備しています")
        case .summarizing:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("更新中")
            }
        case .idle:
            if let duration = session.lastSummaryDuration {
                Text("前回 \(duration.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1))))")
            }
        }
    }
}

private struct TranscriptView: View {
    let lines: [Transcript.Line]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(line.speaker.displayName)
                            .font(.caption.bold())
                            .foregroundStyle(line.speaker.color)
                            .frame(width: 28, alignment: .leading)
                        Text(line.text)
                            .font(.callout)
                            .foregroundStyle(line.isFinal ? .primary : .secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
    }
}

private extension Speaker {
    var color: Color {
        switch self {
        case .me: .accentColor
        case .others: .orange
        }
    }
}

private extension MeetingSession.Failure {
    var message: String {
        switch self {
        case .microphoneAccessDenied:
            "マイクへのアクセスが許可されていません。"
        case let .audioCapture(error):
            "音声を取得できませんでした: \(error.localizedDescription)"
        case let .transcription(error):
            "文字起こしに失敗しました: \(error.localizedDescription)"
        }
    }
}

private extension MeetingSession.SummaryFailure {
    var message: String {
        switch self {
        case let .modelLoading(error):
            "要約モデルを読み込めませんでした: \(error.localizedDescription)"
        case let .summarization(error):
            "要約に失敗しました: \(error.localizedDescription)"
        }
    }
}

#Preview {
    ContentView(session: .live())
}
