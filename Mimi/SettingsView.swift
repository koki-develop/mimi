import MimiKit
import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKey.summaryModelID) private var summaryModelID = SettingsDefault.summaryModelID
    @AppStorage(SettingsKey.theme) private var theme = SettingsDefault.theme
    @AppStorage(SettingsKey.isAlwaysOnTop) private var isAlwaysOnTop = SettingsDefault.isAlwaysOnTop
    @AppStorage(SettingsKey.hidesFromScreenCapture) private var hidesFromScreenCapture = SettingsDefault.hidesFromScreenCapture

    var body: some View {
        Form {
            Section {
                Picker("要約モデル", selection: $summaryModelID) {
                    ForEach(SummaryModel.all) { model in
                        Text(model.displayName).tag(model.id)
                    }
                }
            } footer: {
                Text("初回利用時にモデルをダウンロードします。変更は次回の開始時に反映されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
