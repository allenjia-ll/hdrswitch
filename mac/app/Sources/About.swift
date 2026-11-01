// The About window. Not macOS's standard panel: it keeps its text in a small scrolling box, with a
// scrollbar even when everything fits.

import AppKit
import SwiftUI

struct AboutView: View {
    private let project = "https://github.com/allenjia-ll/hdrswitch"
    private let info = Bundle.main.infoDictionary ?? [:]
    private var version: String { info["CFBundleShortVersionString"] as? String ?? "" }
    private var commit: String { info["HDRSwitchCommit"] as? String ?? "" }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("HDR Switch")
                .font(.system(size: 14, weight: .bold))
            VStack(spacing: 3) {
                InfoRow(label: "Version", value: version, link: URL(string: "\(project)/releases/tag/v\(version)"))
                if !commit.isEmpty {
                    // A commit with uncommitted changes on top isn't on GitHub.
                    InfoRow(label: "Commit", value: commit,
                            link: commit.hasSuffix("-dirty") ? nil : URL(string: "\(project)/commit/\(commit)"))
                }
            }
            Text("Switches HDR on your external monitors in one click, along with the color profile, local dimming "
                 + "and brightness you choose in Settings.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("An unofficial tool, not affiliated with or endorsed by Apple or any monitor's manufacturer. It "
                 + "changes monitor settings using private macOS APIs and DDC/CI. Use it at your own risk.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundColor(.secondary)
            if let url = URL(string: project) {
                Link(project, destination: url)
            }
            Text(info["NSHumanReadableCopyright"] as? String ?? "")
                .foregroundColor(.secondary)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(width: 320)
    }
}

// "Version  0.3.5": the label on the left of the window's center and the value on the right, so a
// stack of rows lines up there. Values are links when they have somewhere to go.
private struct InfoRow: View {
    let label: String
    let value: String
    let link: URL?

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Group {
                if let link = link {
                    Link(value, destination: link)
                } else {
                    Text(value).foregroundColor(.secondary)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
