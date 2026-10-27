import MimiKit
import SwiftUI

struct SettingsView: View {
    let summaryModels: SummaryModelStore
    @AppStorage(SettingsKey.theme) private var theme = SettingsDefault.theme
    @AppStorage(SettingsKey.isAlwaysOnTop) private var isAlwaysOnTop = SettingsDefault.isAlwaysOnTop
    @AppStorage(SettingsKey.hidesFromScreenCapture) private var hidesFromScreenCapture = SettingsDefault.hidesFromScreenCapture

    var body: some View {
        Form {
            SummaryModelSection(summaryModels: summaryModels)

            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text("外観")
                    ThemePicker(selection: $theme)
                }
            }

            Section {
                Toggle("常に最前面に表示", isOn: $isAlwaysOnTop)
                    .toggleStyle(.switch)
            }

            Section {
                Toggle("画面共有・スクリーンショットから隠す", isOn: $hidesFromScreenCapture)
                    .toggleStyle(.switch)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}

// MARK: - Summary models

private struct SummaryModelSection: View {
    let summaryModels: SummaryModelStore
    @State private var pendingDeletion: SummaryModel?
    @State private var deletionFailure: (model: SummaryModel, error: any Error)?

    var body: some View {
        Section {
            if summaryModels.selectedModel == nil {
                Banner(tone: .warning, message: SummaryModelStore.selectionRequiredMessage)
                    .padding(.vertical, 2)
                    .listRowSeparator(.hidden)
            }
            ForEach(SummaryModel.all) { model in
                SummaryModelRow(model: model, summaryModels: summaryModels) {
                    pendingDeletion = model
                }
            }
        } header: {
            Text("要約モデル")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .confirmationDialog(
            pendingDeletion.map { "\($0.displayName)を削除しますか？" } ?? "",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { model in
            Button("削除", role: .destructive) {
                do {
                    try summaryModels.delete(model)
                } catch {
                    deletionFailure = (model, error)
                }
            }
        }
        .alert(
            deletionFailure.map { "\($0.model.displayName)を削除できませんでした" } ?? "",
            isPresented: Binding(
                get: { deletionFailure != nil },
                set: { if !$0 { deletionFailure = nil } }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(deletionFailure.map { $0.error.deletionMessage } ?? "")
        }
    }
}

private struct SummaryModelRow: View {
    let model: SummaryModel
    let summaryModels: SummaryModelStore
    let delete: () -> Void

    var body: some View {
        let status = summaryModels.status(of: model)
        let isSelected = summaryModels.selectedModel == model
        HStack(spacing: 12) {
            Button {
                summaryModels.select(model)
            } label: {
                HStack(spacing: 12) {
                    RadioIndicator(isSelected: isSelected)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.displayName)
                            .font(.system(size: 13))
                            .foregroundStyle(status.isDownloaded ? .primary : .secondary)
                        StatusDetail(status: status, isInUse: summaryModels.isInUse(model))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!status.isDownloaded)
            .accessibilityLabel(model.displayName)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            trailingControls(status: status)
        }
        .frame(minHeight: 36)
    }

    @ViewBuilder
    private func trailingControls(status: SummaryModelStore.Status) -> some View {
        switch status {
        case let .downloaded(size):
            Text(ByteCount.size(size))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            deleteButton
                .disabled(summaryModels.isInUse(model))
        case .downloading:
            IconButton(
                systemImage: "xmark.circle",
                title: "ダウンロードをキャンセル",
                accessibilityLabel: "\(model.displayName)のダウンロードをキャンセル"
            ) {
                summaryModels.cancelDownload(model)
            }
        case .notDownloaded, .failed:
            Button {
                summaryModels.download(model)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10, weight: .medium))
                    Text(status.isFailed ? "再試行" : "ダウンロード")
                }
            }
            .buttonStyle(PushButtonStyle())
            .accessibilityLabel("\(model.displayName)を\(status.isFailed ? "再ダウンロード" : "ダウンロード")")
            // The files of a failed download are kept for retrying, so they can be deleted instead.
            if status.isFailed {
                deleteButton
            }
        }
    }

    private var deleteButton: some View {
        IconButton(systemImage: "trash", title: "削除", accessibilityLabel: "\(model.displayName)を削除", action: delete)
    }
}

/// A 16-point radio button, which SwiftUI offers only inside a picker.
private struct RadioIndicator: View {
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ZStack {
            if isSelected {
                Circle().fill(.tint)
                Circle().fill(.white).frame(width: 6, height: 6)
            } else {
                Circle().fill(Palette.radioBackground)
                Circle().strokeBorder(Palette.radioBorder, lineWidth: 1)
            }
        }
        .frame(width: 16, height: 16)
        .opacity(isEnabled ? 1 : 0.35)
    }
}

/// A 24-point borderless button showing only a symbol.
private struct IconButton: View {
    let systemImage: String
    let title: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(title)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// A small white push button with a hairline border.
private struct PushButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PushButton(configuration: configuration)
    }

    private struct PushButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 6)
            configuration.label
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .padding(.leading, 7)
                .padding(.trailing, 9)
                .frame(height: 22)
                .background(Palette.pushButtonBackground, in: shape)
                .overlay {
                    if configuration.isPressed {
                        shape.fill(.primary.opacity(0.08))
                    }
                }
                .overlay(shape.strokeBorder(Palette.pushButtonBorder, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.06), radius: 0.5, y: 1)
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(shape)
        }
    }
}

/// The line under a model's name.
private struct StatusDetail: View {
    let status: SummaryModelStore.Status
    let isInUse: Bool

    var body: some View {
        switch status {
        case let .downloading(progress):
            HStack(spacing: 8) {
                ProgressBar(fraction: progress?.fractionCompleted ?? 0)
                if let progress {
                    Text(ByteCount.progress(progress))
                        .monospacedDigit()
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        case .downloaded where isInUse:
            Text("会議で使用中のため削除できません")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case let .failed(error):
            Text("ダウンロードに失敗しました")
                .font(.system(size: 11))
                .foregroundStyle(Palette.danger)
                .help(error.localizedDescription)
        case .notDownloaded, .downloaded:
            EmptyView()
        }
    }
}

private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(Palette.progressTrack)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(.tint)
                    .frame(width: 140 * min(max(fraction, 0), 1))
            }
            .frame(width: 140, height: 4)
            .accessibilityElement()
            .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
    }
}

/// Byte counts in the decimal units Finder uses, from kilobytes up, writing zero as "0 KB" rather than spelling it out.
private enum ByteCount {
    static func size(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }

    /// Each count with its own unit, as in "26.8 MB / 3.06 GB".
    static func progress(_ progress: ModelDownloadProgress) -> String {
        "\(size(progress.completedBytes)) / \(size(progress.totalBytes))"
    }

    private static let formatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()
}

private extension SummaryModelStore.Status {
    var isFailed: Bool {
        if case .failed = self { true } else { false }
    }
}

private extension Error {
    var deletionMessage: String {
        switch self as? SummaryModelStore.StoreError {
        case .inUse: "会議で使用中のため削除できません。"
        case .downloading: "ダウンロード中のため削除できません。"
        case .notDownloaded, nil: localizedDescription
        }
    }
}

private struct ThemePicker: View {
    @Binding var selection: AppTheme

    var body: some View {
        HStack(spacing: 12) {
            ForEach(AppTheme.allCases) { theme in
                let isSelected = theme == selection
                Button {
                    selection = theme
                } label: {
                    VStack(spacing: 7) {
                        ThemeThumbnail(theme: theme)
                            .background {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 11)
                                        .strokeBorder(.primary, lineWidth: 2)
                                        .padding(-4)
                                }
                            }
                        Text(theme.displayName)
                            .font(.subheadline.weight(isSelected ? .bold : .regular))
                            .foregroundStyle(isSelected ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("外観")
    }
}

/// A miniature main window drawn in the colors of a theme.
private struct ThemeThumbnail: View {
    let theme: AppTheme

    var body: some View {
        Group {
            switch theme {
            case .light:
                Miniature(palette: .light)
            case .dark:
                Miniature(palette: .dark)
            case .system:
                Miniature(palette: .light)
                    .overlay {
                        Miniature(palette: .dark)
                            .mask {
                                HStack(spacing: 0) {
                                    Color.clear
                                    Color.black
                                }
                            }
                    }
            }
        }
        .frame(width: 100, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

private struct Miniature: View {
    struct Palette {
        var background: Color
        var ink: Color
        var line: Color
        var rule: Color

        static let light = Palette(
            background: .white,
            ink: Color(red: 0.11, green: 0.11, blue: 0.12),
            line: Color(red: 0.78, green: 0.78, blue: 0.80),
            rule: Color(red: 0.90, green: 0.90, blue: 0.92)
        )
        static let dark = Palette(
            background: Color(red: 0.12, green: 0.12, blue: 0.13),
            ink: Color(red: 0.95, green: 0.95, blue: 0.95),
            line: Color(red: 0.28, green: 0.28, blue: 0.29),
            rule: Color(red: 0.22, green: 0.22, blue: 0.23)
        )
    }

    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34))
                Circle().fill(Color(red: 1, green: 0.74, blue: 0.18))
                Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25))
            }
            .frame(width: 13, height: 3)
            bar(width: 78, height: 4, palette.ink)
            bar(width: 52, height: 4, palette.ink)
            Rectangle().fill(palette.rule).frame(height: 1).padding(.vertical, 2)
            HStack(spacing: 3) {
                bar(width: 7, height: 4, palette.ink)
                bar(width: 56, height: 3, palette.line)
            }
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 1)
                    .strokeBorder(palette.line, lineWidth: 1)
                    .frame(width: 7, height: 4)
                bar(width: 44, height: 3, palette.line)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.background)
    }

    private func bar(width: CGFloat, height: CGFloat, _ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(color)
            .frame(width: width, height: height)
    }
}
