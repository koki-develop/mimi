import MimiKit
import SwiftUI

struct SettingsView: View {
    @AppStorage(SettingsKey.summaryModelID) private var summaryModelID = SummaryModel.default.id

    var body: some View {
        Form {
            Picker("要約モデル", selection: $summaryModelID) {
                ForEach(SummaryModel.all) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
            Text("初回利用時にモデルをダウンロードします。変更は次回の開始時に反映されます。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}

enum SettingsKey {
    static let summaryModelID = "summaryModelID"
    static let isAlwaysOnTop = "isAlwaysOnTop"
}
