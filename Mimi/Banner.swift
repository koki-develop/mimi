import SwiftUI

/// A message with an optional action at its trailing edge.
struct Banner: View {
    enum Tone {
        case error
        case warning

        var symbol: String {
            switch self {
            case .error: "exclamationmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            }
        }

        var background: Color {
            switch self {
            case .error: Palette.errorBackground
            case .warning: Palette.warningBackground
            }
        }

        var icon: Color {
            switch self {
            case .error: Palette.errorIcon
            case .warning: Palette.warningIcon
            }
        }

        var text: Color {
            switch self {
            case .error: Palette.errorText
            case .warning: Palette.warningText
            }
        }

        var buttonBorder: Color {
            switch self {
            case .error: Palette.errorButtonBorder
            case .warning: Palette.warningButtonBorder
            }
        }
    }

    struct Action {
        let title: String
        let perform: () -> Void
    }

    let tone: Tone
    let message: String
    var detail: String?
    var action: Action?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: tone.symbol)
                .font(.system(size: 13))
                .foregroundStyle(tone.icon)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.system(size: 12))
                    .lineSpacing(2)
                    .foregroundStyle(tone.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action.title, action: action.perform)
                        .buttonStyle(BannerButtonStyle(tone: tone))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.background, in: RoundedRectangle(cornerRadius: 10))
        .help(detail ?? "")
    }
}

/// A small outlined button in the colors of its banner.
private struct BannerButtonStyle: ButtonStyle {
    let tone: Banner.Tone

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tone.text)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Palette.bannerButtonBackground, in: shape)
            .overlay(shape.strokeBorder(tone.buttonBorder, lineWidth: 0.5))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(shape)
    }
}
