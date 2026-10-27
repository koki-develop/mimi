import AppKit
import MimiKit
import SwiftUI

struct ContentView: View {
    let session: MeetingSession
    @AppStorage(SettingsKey.summaryModelID) private var summaryModelID = SettingsDefault.summaryModelID
    @AppStorage(SettingsKey.isAlwaysOnTop) private var isAlwaysOnTop = SettingsDefault.isAlwaysOnTop
    @AppStorage(SettingsKey.hidesFromScreenCapture) private var hidesFromScreenCapture = SettingsDefault.hidesFromScreenCapture
    @AppStorage(SettingsKey.isTranscriptCollapsed) private var isTranscriptCollapsed = SettingsDefault.isTranscriptCollapsed
    @AppStorage(SettingsKey.theme) private var theme = SettingsDefault.theme
    @State private var collapsedContentHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0

    // Reads no session state itself, so the frequent transcript and summary updates re-render only the views that
    // show them, not the whole window and its `WindowConfigurator`.
    var body: some View {
        content
            .containerBackground(Color(nsColor: .textBackgroundColor), for: .window)
            .toolbar {
                SessionToolbar(session: session, summaryModelID: summaryModelID)
            }
            .toolbar(removing: .title)
            .background(WindowConfigurator(
                isAlwaysOnTop: isAlwaysOnTop,
                hidesFromScreenCapture: hidesFromScreenCapture,
                collapsedContentHeight: isTranscriptCollapsed ? collapsedContentHeight : nil
            ) {
                NSApplication.shared.terminate(nil)
            })
            .onChange(of: theme, initial: true) {
                NSApplication.shared.appearance = theme.appearance
            }
            .onChange(of: isTranscriptCollapsed) {
                // The topic or failure may change while expanded, so the next collapse waits for a new measurement
                // instead of resizing the window to the previous one first.
                if !isTranscriptCollapsed {
                    collapsedContentHeight = 0
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if isTranscriptCollapsed {
            VStack(alignment: .leading, spacing: 0) {
                header
                LatestLineView(session: session)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
            }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { collapsedContentHeight = $0 }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                TranscriptView(session: session)
            }
            // The collapsed content is this header plus the latest line, so this minimum always stays below the
            // collapsed height: expanding never forces the window to grow before `WindowConfigurator` resizes it
            // with its top edge in place.
            .frame(minWidth: 320, minHeight: headerHeight, alignment: .top)
        }
    }

    private var header: some View {
        HeaderView(session: session, isTranscriptCollapsed: $isTranscriptCollapsed)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
    }
}

/// The failure, the current topic, and the rule that separates them from the transcript.
private struct HeaderView: View {
    let session: MeetingSession
    @Binding var isTranscriptCollapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let failure = session.failure {
                FailureBanner(failure: failure)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }
            TopicView(session: session)
                .padding(.horizontal, 18)
                .padding(.top, 8)
            SummaryRule(activity: session.summaryActivity, hasFailed: session.summaryFailure != nil, isTranscriptCollapsed: $isTranscriptCollapsed)
                .padding(.leading, 18)
                .padding(.trailing, 12)
                .padding(.top, 12)
        }
    }
}

// MARK: - Toolbar

private struct SessionToolbar: ToolbarContent {
    let session: MeetingSession
    let summaryModelID: String

    var body: some ToolbarContent {
        // Without a title, items would otherwise line up after the window controls.
        ToolbarSpacer(.flexible)
        if let runningSince = session.runningSince {
            ToolbarItem {
                ElapsedTimeView(since: runningSince)
            }
            // A status, not a control, so it goes without glass.
            .sharedBackgroundVisibility(.hidden)
        }
        ToolbarItem {
            Toggle(isOn: session.microphoneMutedBinding) {
                Label(MeetingSession.muteTitle, systemImage: session.isMicrophoneMuted ? "mic.slash.fill" : "mic")
            }
            .toggleStyle(.button)
            .help(MeetingSession.muteTitle)
        }
        // Keeps the icon-only toggle apart from the text-labeled button, so they don't read as one action.
        ToolbarSpacer(.fixed)
        ToolbarItem {
            SessionButton(session: session, summaryModelID: summaryModelID)
        }
    }
}

private struct ElapsedTimeView: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(Self.format(context.date.timeIntervalSince(since)))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("経過時間 \(Self.format(context.date.timeIntervalSince(since)))")
        }
    }

    private static func format(_ elapsed: TimeInterval) -> String {
        let seconds = max(0, elapsed.rounded(.down))
        return Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

private struct SessionButton: View {
    let session: MeetingSession
    let summaryModelID: String

    var body: some View {
        Button {
            Task { await session.toggleRunning(summaryModelID: summaryModelID) }
        } label: {
            Label {
                Text(session.toggleRunningTitle)
            } icon: {
                icon
            }
            .labelStyle(.titleAndIcon)
        }
        .disabled(!session.canToggleRunning)
    }

    @ViewBuilder
    private var icon: some View {
        switch session.state {
        case .idle:
            Image(systemName: "circle.fill")
                .imageScale(.small)
                .foregroundStyle(.red)
        case .running:
            Image(systemName: "stop.fill")
                .imageScale(.small)
                .foregroundStyle(.red)
        case .starting, .stopping:
            ProgressView()
                .controlSize(.small)
        }
    }
}

// MARK: - Failure

private struct FailureBanner: View {
    let failure: MeetingSession.Failure

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 6) {
                Text(failure.message)
                if case .microphoneAccessDenied = failure {
                    Button("システム設定を開く") {
                        NSWorkspace.shared.open(.microphonePrivacySettings)
                    }
                    .controlSize(.small)
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .help(failure.detail ?? "")
    }
}

private extension URL {
    /// The Microphone pane of Privacy & Security in System Settings.
    static let microphonePrivacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
}

// MARK: - Topic

private struct TopicView: View {
    let session: MeetingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("今の話題")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(topic)
                .font(.title2.weight(.semibold))
                .foregroundStyle(session.currentTopic.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.25), value: topic)
            if let failure = session.summaryFailure {
                Text(failure.message)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .help(failure.detail)
                    .padding(.top, 2)
            }
        }
    }

    private var topic: String {
        if !session.currentTopic.isEmpty {
            return session.currentTopic
        }
        if case .loadingModel = session.summaryActivity {
            return "要約モデルを準備しています"
        }
        return "まだありません"
    }
}

/// Separates the topic from the transcript, shows the summary's progress, and collapses or expands the transcript.
private struct SummaryRule: View {
    let activity: MeetingSession.SummaryActivity
    let hasFailed: Bool
    @Binding var isTranscriptCollapsed: Bool

    var body: some View {
        HStack(spacing: 6) {
            SummaryProgressTrack(activity: activity, hasFailed: hasFailed)
            let title = isTranscriptCollapsed ? "文字起こしをひらく" : "文字起こしをたたむ"
            Button {
                isTranscriptCollapsed.toggle()
            } label: {
                Image(systemName: isTranscriptCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(title)
            .accessibilityLabel(title)
        }
        .frame(height: 24)
    }
}

private struct SummaryProgressTrack: View {
    let activity: MeetingSession.SummaryActivity
    let hasFailed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let segmentWidth: CGFloat = 64
    private static let sweepDuration: TimeInterval = 1.8

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(hasFailed ? AnyShapeStyle(.red.opacity(0.45)) : AnyShapeStyle(.separator))
                    .frame(height: 1)
                switch activity {
                case .idle:
                    EmptyView()
                case let .loadingModel(progress):
                    Capsule()
                        .fill(.primary)
                        .frame(width: geometry.size.width * min(max(progress, 0), 1), height: 2)
                case .summarizing:
                    if reduceMotion {
                        Rectangle()
                            .fill(.secondary.opacity(0.35))
                            .frame(height: 2)
                    } else {
                        TimelineView(.animation) { context in
                            Capsule()
                                .fill(.secondary)
                                .frame(width: Self.segmentWidth, height: 2)
                                .offset(x: Self.sweepOffset(at: context.date, width: geometry.size.width))
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .frame(height: 2)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHidden(activity == .idle)
    }

    /// Moves the segment across the track and back to the start, easing in and out.
    private static func sweepOffset(at date: Date, width: CGFloat) -> CGFloat {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: sweepDuration) / sweepDuration
        let eased = phase < 0.5 ? 2 * phase * phase : 1 - pow(-2 * phase + 2, 2) / 2
        return -segmentWidth + (width + segmentWidth) * eased
    }

    private var accessibilityLabel: String {
        switch activity {
        case .idle: ""
        case .loadingModel: "要約モデルを準備しています"
        case .summarizing: "要約を更新しています"
        }
    }

    private var accessibilityValue: String {
        guard case let .loadingModel(progress) = activity else { return "" }
        return progress.formatted(.percent.precision(.fractionLength(0)))
    }
}

// MARK: - Transcript

private struct TranscriptView: View {
    let session: MeetingSession

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(session.transcript.turns.reversed()) { turn in
                    TurnView(turn: turn, level: turn.isInProgress ? session.level(of: turn.speaker) : nil)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollEdgeEffectStyle(.soft, for: .bottom)
    }
}

/// A turn with its newest line first, so the latest speech stays at the top however long the turn grows.
/// The tag sits beside that newest line, which is the one still being spoken while the turn is in progress.
private struct TurnView: View {
    let turn: Transcript.Turn
    /// The speaker's live level, while the speaker is speaking.
    let level: AudioLevelMeter?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            SpeakerTag(speaker: turn.speaker, level: level)
                .frame(width: 32, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(turn.lines.reversed()) { line in
                    LineText(line: line)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct LatestLineView: View {
    let session: MeetingSession

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let line = session.transcript.latestLine {
                SpeakerTag(speaker: line.speaker)
                    .frame(width: 32, alignment: .leading)
                // An in-progress line grows at its end, so the start gives way to keep the newest words visible.
                LineText(line: line)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        // Keeps the row's height while nothing has been said, so the window does not grow with the first line.
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct LineText: View {
    let line: Transcript.Line

    var body: some View {
        Text(line.text)
            .font(.body)
            .foregroundStyle(line.isFinal ? .primary : .secondary)
    }
}

/// Labels a speaker: an outline for the user and a fill for the others, matching across the window.
private struct SpeakerTag: View {
    let speaker: Speaker
    /// When set, ripples spread from the tag following the level.
    var level: AudioLevelMeter?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let cornerRadius: CGFloat = 4

    var body: some View {
        Text(speaker.displayName)
            .font(.caption.weight(.bold))
            .foregroundStyle(speaker == .me ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color(nsColor: .textBackgroundColor)))
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background {
                let shape = RoundedRectangle(cornerRadius: Self.cornerRadius)
                switch speaker {
                case .me: shape.strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: 1)
                case .others: shape.fill(.primary)
                }
            }
            .overlay {
                if let level, !reduceMotion {
                    SpeechRipple(level: level, color: speaker == .me ? .secondary : .primary, cornerRadius: Self.cornerRadius)
                }
            }
    }
}

/// Rings that spread from a shape whenever the level is loud enough, more often the louder it is.
/// Samples the level at a low rate and lets each ring animate itself, so the view updates only when a ring is added
/// or removed.
private struct SpeechRipple: View {
    let level: AudioLevelMeter
    let color: Color
    let cornerRadius: CGFloat
    @State private var rings: [RippleRing] = []

    var body: some View {
        ZStack {
            ForEach(rings) { ring in
                RippleRingView(ring: ring, color: color, cornerRadius: cornerRadius)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            let clock = ContinuousClock()
            var emitter = RippleEmitter()
            while true {
                let now = clock.now
                let hasFaded = { (ring: RippleRing) in ring.emittedAt.duration(to: now) >= .seconds(RippleEmitter.lifetime) }
                if rings.contains(where: hasFaded) {
                    rings.removeAll(where: hasFaded)
                }
                if let ring = emitter.emission(at: now, level: level.level) {
                    rings.append(ring)
                }
                do {
                    try await Task.sleep(for: RippleEmitter.samplingInterval)
                } catch {
                    // Cancelled because the ripple left the screen.
                    return
                }
            }
        }
    }
}

private struct RippleRing: Identifiable {
    let id = UUID()
    let emittedAt: ContinuousClock.Instant
    /// How far the level was above the threshold, from 0 to 1.
    let strength: Double
}

private struct RippleRingView: View {
    let ring: RippleRing
    let color: Color
    let cornerRadius: CGFloat
    @State private var hasSpread = false

    var body: some View {
        let spread = RippleEmitter.maxSpread * (0.6 + 0.4 * ring.strength)
        RoundedRectangle(cornerRadius: cornerRadius + (hasSpread ? spread : 0))
            .strokeBorder(color, lineWidth: 1)
            .padding(hasSpread ? -spread : 0)
            .opacity(hasSpread ? 0 : 0.5 + 0.25 * ring.strength)
            .onAppear {
                withAnimation(.easeOut(duration: RippleEmitter.lifetime)) {
                    hasSpread = true
                }
            }
    }
}

/// Emits a ring whenever the level is above a threshold, at intervals that shorten as the level rises.
private struct RippleEmitter {
    static let samplingInterval: Duration = .milliseconds(50)
    static let lifetime: TimeInterval = 0.9
    static let maxSpread: CGFloat = 5
    /// Roughly -33 dBFS on ``AudioLevel/normalized(_:floorDecibels:)``'s scale, above background noise.
    private static let threshold: Float = 0.45
    private static let longestInterval: Duration = .milliseconds(600)
    private static let shortestInterval: Duration = .milliseconds(180)

    private var lastEmission: ContinuousClock.Instant?

    mutating func emission(at now: ContinuousClock.Instant, level: Float) -> RippleRing? {
        guard level >= Self.threshold else { return nil }
        let strength = Double((level - Self.threshold) / (1 - Self.threshold))
        let interval = Self.longestInterval - (Self.longestInterval - Self.shortestInterval) * strength
        if let lastEmission, lastEmission.duration(to: now) < interval {
            return nil
        }
        lastEmission = now
        return RippleRing(emittedAt: now, strength: strength)
    }
}

// MARK: - Messages

private extension MeetingSession {
    func level(of speaker: Speaker) -> AudioLevelMeter {
        switch speaker {
        case .me: microphoneLevel
        case .others: systemAudioLevel
        }
    }
}

private extension MeetingSession.Failure {
    var message: String {
        switch self {
        case .microphoneAccessDenied: "マイクへのアクセスが許可されていません"
        case .audioCapture: "音声を取得できませんでした"
        case .transcription: "文字起こしに失敗しました"
        }
    }

    var detail: String? {
        switch self {
        case .microphoneAccessDenied: nil
        case let .audioCapture(error), let .transcription(error): error.localizedDescription
        }
    }
}

private extension MeetingSession.SummaryFailure {
    var message: String {
        switch self {
        case .modelLoading: "要約モデルを読み込めませんでした"
        case .summarization: "要約に失敗しました"
        }
    }

    var detail: String {
        switch self {
        case let .modelLoading(error), let .summarization(error): error.localizedDescription
        }
    }
}

#Preview {
    ContentView(session: .live())
}
