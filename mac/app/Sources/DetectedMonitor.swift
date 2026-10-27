// View Detected Monitor: what's in local_monitor_db.json (monitors found with Detect Monitor or
// `hdrctl detect`), with a button to contribute an entry on GitHub, as at the end of detection.

import AppKit
import SwiftUI

final class DetectedMonitorModel: ObservableObject {
    struct Entry {
        let hash: String
        let entry: [AnyHashable: Any]
        var identity: [AnyHashable: Any] { entry["identity"] as? [AnyHashable: Any] ?? [:] }
        var name: String { identity["product_name"] as? String ?? "Unknown monitor" }
        var manufacturer: String { identity["manufacturer"] as? String ?? "" }
        var localDimming: [AnyHashable: Any] {
            (entry["settings"] as? [AnyHashable: Any])?["local_dimming"] as? [AnyHashable: Any] ?? [:]
        }
        var tool: String { (entry["report"] as? [AnyHashable: Any])?["tool"] as? String ?? "HDR Switch" }
        var json: String { HCPrettyJSON([hash: entry]) ?? "" }
    }

    @Published private(set) var entries: [Entry] = []
    @Published var selected = 0
    @Published private(set) var problem: String?
    let path = HCLocalDBPath() ?? "local_monitor_db.json"

    init() { reload() }

    func reload() {
        var err: NSString?
        guard let db = HCLoadLocalDB(&err) else {
            problem = (err as String?) ?? "Can't read local_monitor_db.json."
            entries = []
            return
        }
        entries = db.compactMap { key, value in
            guard let hash = key as? String, let entry = value as? [AnyHashable: Any] else { return nil }
            return Entry(hash: hash, entry: entry)
        }
        .sorted { ($0.name, $0.hash) < ($1.name, $1.hash) }
        selected = min(selected, max(entries.count - 1, 0))
        problem = nil
    }

    var current: Entry? { entries.indices.contains(selected) ? entries[selected] : nil }

    func contribute() {
        guard let e = current, let url = HCContributionURL(e.identity, e.json, e.tool) else { return }
        NSWorkspace.shared.open(url)
    }
}

struct DetectedMonitorView: View {
    @ObservedObject var model: DetectedMonitorModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Detected Monitor")
                .font(.system(size: 13, weight: .bold))
                .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 10) {
                if let problem = model.problem {
                    Text(problem).fixedSize(horizontal: false, vertical: true)
                } else if let e = model.current {
                    if model.entries.count > 1 {
                        Picker("Monitor", selection: $model.selected) {
                            ForEach(model.entries.indices, id: \.self) { i in
                                Text("\(model.entries[i].name) (\(model.entries[i].hash.prefix(12))…)").tag(i)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    Summary(entry: e)
                    ScrollView {
                        Text(e.json)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    Text("In \(model.path)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No detected monitors yet.")
                }
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()
                .padding(.vertical, 12)
            HStack {
                Spacer()
                Button("Contribute on GitHub…", action: model.contribute)
                    .disabled(model.current == nil)
                Button("OK", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 460)
    }

    // Name, VCP code, levels, and the levels HDR on and off use.
    private struct Summary: View {
        let entry: DetectedMonitorModel.Entry

        var body: some View {
            let ld = entry.localDimming
            let levels = (ld["levels"] as? [[AnyHashable: Any]] ?? []).compactMap { l -> String? in
                guard let name = l["name"] as? String, let value = l["value"] as? NSNumber else { return nil }
                return "\(name.capitalized) \(value)"
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(entry.name)\(entry.manufacturer.isEmpty ? "" : " (\(entry.manufacturer))")")
                    .font(.system(size: 12, weight: .semibold))
                Row(label: "Local dimming", value: "VCP \(ld["vcp"] as? String ?? "?")")
                Row(label: "Levels", value: levels.joined(separator: ", "))
                Row(label: "HDR on / off", value: "\((ld["hdr_on"] as? String ?? "standard").capitalized) / "
                                                + "\((ld["hdr_off"] as? String ?? "off").capitalized)")
            }
        }

        private struct Row: View {
            let label: String
            let value: String
            var body: some View {
                HStack(alignment: .firstTextBaseline) {
                    Text(label).foregroundColor(.secondary).frame(width: 96, alignment: .leading)
                    Text(value).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
