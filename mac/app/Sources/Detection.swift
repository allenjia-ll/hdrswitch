// Detect Monitor: the same process as `hdrctl detect`, as a window of steps with Back and Continue.
// The user sets each local dimming level in the monitor's menu while we scan every VCP code; the one
// code that follows is local dimming. After the user confirms each level on the monitor, the entry
// is saved to local_monitor_db.json (in Application Support). The scanning, candidates, report and
// contribution link are in the core (HCDetection and friends), shared with the CLI.

import AppKit
import SwiftUI

final class DetectionModel: ObservableObject {
    enum Step: Equatable {
        case intro, levels, scan(Int), result, verify(Int), hdrLevels, details, done, failed
    }

    static let maxLevels = 10

    @Published private(set) var step = Step.intro
    @Published private(set) var busy = false
    @Published private(set) var progress = 0.0           // during a scan, 0...1
    @Published private(set) var status = ""              // what's happening, under the step
    @Published private(set) var failure = ""             // .failed
    @Published private(set) var monitorName = MonitorModel.displayName
    @Published private(set) var knownNote: String?       // already in a database
    @Published var levelCount = 2
    @Published var names = Array(repeating: "", count: DetectionModel.maxLevels)
    @Published private(set) var candidates: [UInt8] = []
    @Published var chosen = 0                            // index into candidates
    @Published var onLevel = ""
    @Published var offLevel = ""
    @Published var firmware = ""
    @Published var connection = ""
    @Published private(set) var savedPath = ""
    @Published private(set) var savedJSON = ""

    private let onSaved: () -> Void
    private var av: AnyObject?
    private var identity: [AnyHashable: Any]?
    private var hash = ""
    private var detection: HCDetection?

    init(onSaved: @escaping () -> Void) { self.onSaved = onSaved }

    // MARK: - For the view

    var levelNames: [String] {
        names.prefix(levelCount).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }
    var namesValid: Bool {
        let n = levelNames
        return !n.contains("") && Set(n).count == n.count
    }
    var code: UInt8? { candidates.indices.contains(chosen) ? candidates[chosen] : nil }
    func value(atLevel i: Int) -> UInt16 {
        guard let d = detection, let c = code else { return 0 }
        return d.value(ofCode: c, atLevel: UInt(i))
    }
    func values(of candidate: UInt8) -> String {
        guard let d = detection else { return "" }
        return levelNames.indices.map { "\(levelNames[$0])=\(d.value(ofCode: candidate, atLevel: UInt($0)))" }
            .joined(separator: ", ")
    }
    var rangeMax: UInt16 { code.map { detection?.rangeMax(ofCode: $0) ?? 0 } ?? 0 }

    var stepNumber: Int {
        switch step {
        case .intro: return 1
        case .levels: return 2
        case .scan(let i): return 3 + i
        case .result: return 3 + levelCount
        case .verify(let i): return 4 + levelCount + i
        case .hdrLevels: return 4 + 2 * levelCount
        case .details: return 5 + 2 * levelCount
        case .done, .failed: return stepCount
        }
    }
    var stepCount: Int { 5 + 2 * levelCount }

    var canGoBack: Bool {
        guard !busy else { return false }
        switch step {
        case .intro, .done, .failed: return false
        default: return true
        }
    }
    var canContinue: Bool {
        guard !busy else { return false }
        switch step {
        case .intro: return av != nil && identity != nil
        case .levels: return namesValid
        case .result: return code != nil
        case .hdrLevels: return levelNames.contains(onLevel) && levelNames.contains(offLevel)
        case .done, .failed: return false
        default: return true
        }
    }
    var continueTitle: String { step == .details ? "Save" : "Continue" }

    // MARK: - Steps

    // Reads the monitor's identity (DDC, so on the shared queue).
    func start() {
        step = .intro
        busy = true
        status = "Reading the monitor…"
        ddcQueue.async {
            var attrs: NSDictionary?, err: NSString?, why: NSString?
            let av = HCFindAVService(MonitorModel.displayName, &attrs, &err)?.takeRetainedValue()
            let identity = av.flatMap { HCReadIdentityValues($0, attrs as? [AnyHashable: Any], &why) }
            DispatchQueue.main.async {
                self.busy = false
                self.status = ""
                guard let av = av, let identity = identity else {
                    self.fail("Can't read the monitor over DDC: \(((why ?? err) as String?) ?? "no DDC connection"). "
                              + "Check that it's connected and awake, and that MonitorControl and other DDC apps are closed.")
                    return
                }
                self.av = av
                self.identity = identity
                self.hash = HCSHA256Hex(HCIdentityJSON(identity))
                self.monitorName = identity["product_name"] as? String ?? MonitorModel.displayName
                var dbErr: NSString?
                let local = HCLoadLocalDB(&dbErr), db = HCLoadDB(&dbErr)
                if local?[self.hash] != nil {
                    self.knownNote = "It's already in local_monitor_db.json; a new detection replaces that entry."
                } else if db?[self.hash] != nil {
                    self.knownNote = "It's already in the shipped monitor_db.json. The result is saved to "
                        + "local_monitor_db.json and is used instead of the shipped entry on this Mac."
                }
            }
        }
    }

    func next() {
        guard canContinue else { return }
        switch step {
        case .intro: step = .levels
        case .levels:
            detection = HCDetection(service: av!, levelCount: UInt(levelCount))
            step = .scan(0)
        case .scan(let i): scan(i)
        case .result: verify(0)
        case .verify(let i):
            if i + 1 < levelCount { verify(i + 1); return }
            if !levelNames.contains(onLevel) { onLevel = HCSuggestedHDRLevel(levelNames, true) }
            if !levelNames.contains(offLevel) { offLevel = HCSuggestedHDRLevel(levelNames, false) }
            step = .hdrLevels
        case .hdrLevels: step = .details
        case .details: confirmSave()
        case .done, .failed: break
        }
    }

    func back() {
        guard canGoBack else { return }
        status = ""
        switch step {
        case .levels: step = .intro
        case .scan(let i):
            if i == 0 { detection = nil; step = .levels }
            else { detection?.discardLevels(from: UInt(i - 1)); step = .scan(i - 1) }   // redo the previous level
        case .result:
            detection?.discardLevels(from: UInt(levelCount - 1))
            step = .scan(levelCount - 1)
        case .verify(let i):
            if i == 0 { step = .result } else { verify(i - 1) }
        case .hdrLevels: verify(levelCount - 1)
        case .details: step = .hdrLevels
        case .intro, .done, .failed: break
        }
    }

    // The monitor's menu didn't show the level just written: stop without saving, leaving local
    // dimming at the last level the user set themselves.
    func doesntMatch() {
        guard case .verify = step, let av = av, let code = code else { return }
        let last = value(atLevel: levelCount - 1), name = levelNames[levelCount - 1]
        busy = true
        ddcQueue.async {
            HCSetDimming(av, code, last, name)
            DispatchQueue.main.async {
                self.busy = false
                self.fail("Not saved: the monitor's menu didn't show the level that was set. Start over, and set each "
                          + "level exactly as asked before clicking Continue.")
            }
        }
    }

    func startOver() {
        detection = nil
        candidates = []
        savedJSON = ""
        start()
    }

    func contribute() {
        guard let identity = identity, !savedJSON.isEmpty,
              let url = HCContributionURL(identity, savedJSON, "HDR Switch") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Private

    private func scan(_ i: Int) {
        guard let detection = detection else { return }
        busy = true
        progress = 0
        status = "Reading VCP codes…"
        ddcQueue.async {
            let ok = detection.scanNextLevel { pass, done, total in
                DispatchQueue.main.async {
                    self.progress = Double(done) / Double(max(total, 1))
                    self.status = pass == 1 ? "Reading again, to rule out values that change on their own… \(done)/\(total)"
                                            : "Reading VCP codes… \(done)/\(total)"
                }
            }
            DispatchQueue.main.async {
                self.busy = false
                self.status = ""
                guard ok else {
                    self.fail("The monitor stopped answering over DDC (asleep?). Nothing was saved.")
                    return
                }
                if i + 1 < self.levelCount {
                    self.step = .scan(i + 1)
                } else {
                    self.candidates = detection.candidates.map { $0.uint8Value }
                    self.chosen = 0
                    self.step = .result
                }
            }
        }
    }

    // Writes level i to the detected code for the user to check in the monitor's menu.
    private func verify(_ i: Int) {
        guard let av = av, let code = code else { return }
        step = .verify(i)
        let value = value(atLevel: i), name = levelNames[i]
        busy = true
        status = "Setting local dimming to \"\(name)\"…"
        ddcQueue.async {
            let ok = HCSetDimming(av, code, value, name)
            DispatchQueue.main.async {
                self.busy = false
                self.status = ok ? "" : "Couldn't confirm the change over DDC; check the monitor's menu anyway."
            }
        }
    }

    private func confirmSave() {
        guard let code = code else { return }
        let alert = NSAlert()
        alert.messageText = "Save this monitor?"
        alert.informativeText = "\(monitorName): local dimming on VCP \(String(format: "0x%02X", code)) with \(levelCount) "
            + "levels will be saved to local_monitor_db.json, and used instead of any shipped entry on this Mac."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { save() }
    }

    private func save() {
        guard let identity = identity, let code = code, let detection = detection else { return }
        var err: NSString?
        let report = HCDetectionReport("HDR Switch", firmware.trimmingCharacters(in: .whitespaces),
                                       connection.trimmingCharacters(in: .whitespaces))
        guard let entry = HCSaveLocalMonitor(identity, code, detection.levelsNamed(levelNames, forCode: code),
                                             onLevel, offLevel, report, &err) else {
            fail("Couldn't save: \((err as String?) ?? "unknown error").")
            return
        }
        savedPath = HCLocalDBPath()
        savedJSON = HCPrettyJSON([hash: entry]) ?? ""
        step = .done
        onSaved()
    }

    private func fail(_ message: String) {
        failure = message
        step = .failed
    }
}

// MARK: - The window

struct DetectionView: View {
    @ObservedObject var model: DetectionModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                if model.step != .done && model.step != .failed {
                    Text("Step \(model.stepNumber) of \(model.stepCount)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 10) { content }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if model.busy || !model.status.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if case .scan = model.step, model.busy {
                        ProgressView(value: model.progress)
                    } else if model.busy {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.status)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 8)
            }

            Divider()
                .padding(.vertical, 12)
            buttons
        }
        .padding(20)
        .frame(width: 480, height: 460)
    }

    private var title: String {
        switch model.step {
        case .intro: return "Detect Monitor"
        case .levels: return "Local dimming levels"
        case .scan(let i): return "Level \(i + 1) of \(model.levelCount): \(model.levelNames[i].capitalized)"
        case .result: return "Result"
        case .verify(let i): return "Check level \(i + 1) of \(model.levelCount): \(model.levelNames[i].capitalized)"
        case .hdrLevels: return "Levels for HDR on and off"
        case .details: return "Details (optional)"
        case .done: return "Saved"
        case .failed: return "Detection stopped"
        }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .intro:
            Text("Monitor: \(model.monitorName)").font(.system(size: 12, weight: .semibold))
            if let note = model.knownNote { Paragraph(note) }
            Paragraph("This finds the VCP code your monitor uses for local dimming. You'll set each local dimming "
                      + "level in the monitor's own menu while HDR Switch reads every VCP code; the code that changes "
                      + "with it is the one. Until you confirm the result, it only reads from the monitor; then it "
                      + "writes that one code to check each level with you.")
            Paragraph("Before starting, quit MonitorControl and other DDC apps, and keep the monitor awake. The first "
                      + "level takes about two minutes, the others about 20 seconds each.")

        case .levels:
            HStack {
                Text("How many local dimming levels does the monitor's menu have?")
                Stepper("\(model.levelCount)", value: $model.levelCount, in: 2...DetectionModel.maxLevels)
                    .fixedSize()
            }
            Text("Name each one as the monitor's menu shows it:").foregroundColor(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(0..<model.levelCount, id: \.self) { i in
                        HStack {
                            Text("Level \(i + 1)").frame(width: 56, alignment: .leading)
                            TextField(i == 0 ? "e.g. Off" : "e.g. Low, Standard, High",
                                      text: Binding(get: { model.names[i] }, set: { model.names[i] = $0 }))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
            if !model.namesValid {
                Text("Give every level a name, and use each name once.").font(.system(size: 11)).foregroundColor(.secondary)
            }

        case .scan(let i):
            Paragraph("In the monitor's menu, set local dimming to \"\(model.levelNames[i].capitalized)\" and close the "
                      + "menu. Then click Continue to read the monitor.")
            if i == 0 { Paragraph("This first level is read twice, to rule out values that change on their own.") }

        case .result:
            if model.candidates.isEmpty {
                Paragraph("No VCP code changed with local dimming. This monitor may not expose local dimming over DDC/CI, "
                          + "or a level was skipped. Go Back to read the last level again, or close this window.")
            } else {
                if model.candidates.count > 1 {
                    Paragraph("More than one VCP code changed with local dimming. Which one is local dimming?")
                    Picker("", selection: $model.chosen) {
                        ForEach(model.candidates.indices, id: \.self) { c in
                            Text(String(format: "VCP 0x%02X: ", model.candidates[c]) + model.values(of: model.candidates[c])).tag(c)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
                if let code = model.code {
                    Text(String(format: "Local dimming is VCP 0x%02X (range max %u):", code, model.rangeMax))
                    LevelTable(model: model)
                    Paragraph(String(format: "Continue writes each level to VCP 0x%02X, one at a time, so you can check it "
                                             + "on the monitor.", code))
                }
            }

        case .verify(let i):
            Paragraph(String(format: "HDR Switch set local dimming to \"%@\" (VCP 0x%02X = %u).",
                             model.levelNames[i].capitalized, model.code ?? 0, model.value(atLevel: i)))
            Paragraph("Open the monitor's menu: does it show local dimming \"\(model.levelNames[i].capitalized)\"? "
                      + "If it does, click Continue. If not, click Doesn't Match.")

        case .hdrLevels:
            Paragraph("Which local dimming level should HDR Switch set when it turns HDR on, and when it turns HDR off?")
            LevelPicker(label: "HDR on", selection: $model.onLevel, names: model.levelNames)
            LevelPicker(label: "HDR off", selection: $model.offLevel, names: model.levelNames)

        case .details:
            Paragraph("These help whoever reviews the entry if you contribute it. Leave them empty to skip.")
            HStack {
                Text("Firmware").frame(width: 76, alignment: .leading)
                TextField("as shown in the monitor's menu", text: $model.firmware).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Connection").frame(width: 76, alignment: .leading)
                TextField("e.g. USB-C, DisplayPort, HDMI", text: $model.connection).textFieldStyle(.roundedBorder)
            }
            Paragraph("Click Save to save the result to local_monitor_db.json.")

        case .done:
            Paragraph("Saved to \(model.savedPath). HDR Switch uses it from now on.")
            ScrollView {
                Text(model.savedJSON)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            Paragraph("To add this monitor for everyone, contribute it: this opens a pre-filled GitHub issue in your "
                      + "browser, which you can review before submitting.")

        case .failed:
            Paragraph(model.failure)
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            switch model.step {
            case .done:
                Spacer()
                Button("Contribute on GitHub…", action: model.contribute)
                Button("Close", action: close).keyboardShortcut(.defaultAction)
            case .failed:
                Spacer()
                Button("Start Over", action: model.startOver)
                Button("Close", action: close).keyboardShortcut(.defaultAction)
            default:
                Button("Back", action: model.back).disabled(!model.canGoBack)
                Spacer()
                if case .verify = model.step {
                    Button("Doesn't Match", action: model.doesntMatch).disabled(model.busy)
                }
                Button(model.continueTitle, action: model.next)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canContinue)
            }
        }
    }
}

// A paragraph that wraps instead of truncating.
private struct Paragraph: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).fixedSize(horizontal: false, vertical: true) }
}

// The detected levels and their values.
private struct LevelTable: View {
    @ObservedObject var model: DetectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.levelNames.indices, id: \.self) { i in
                HStack {
                    Text(model.levelNames[i].capitalized).frame(width: 120, alignment: .leading)
                    Text("\(model.value(atLevel: i))").font(.system(size: 12, design: .monospaced))
                }
            }
        }
        .padding(.leading, 12)
    }
}

private struct LevelPicker: View {
    let label: String
    @Binding var selection: String
    let names: [String]

    var body: some View {
        HStack {
            Text(label).frame(width: 76, alignment: .leading)
            Picker("", selection: $selection) {
                ForEach(names, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }
}
