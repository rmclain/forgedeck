import ForgeDeckKit
import SwiftUI

/// Every part of the kit on one page. Shown instead of the app with APP_KIT_GALLERY=1.
struct KitGallery: View {
    @State private var tier: EnvironmentTier = .staging
    @State private var segment = "7d"
    @State private var text = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                Text("Design kit").kitType(.pageTitle)
                row("Buttons") {
                    Button("Primary") {}.buttonStyle(.kit(.primary))
                    Button("Secondary") {}.buttonStyle(.kit(.secondary))
                    Button("Production") {}.buttonStyle(.kit(.production))
                    Button("Ghost") {}.buttonStyle(.kit(.ghost))
                    Button("Disabled") {}.buttonStyle(.kit(.secondary)).disabled(true)
                    IconButton(.terminal, label: "Icon") {}
                    Button("Link") {}.buttonStyle(.kit(.link))
                }
                row("Status") {
                    ForEach([Tone.ok, .warn, .err, .accent, .muted], id: \.self) { StatusPill("\($0)".capitalized, tone: $0) }
                    TagBadge("Prod", tone: .prod, filled: true)
                    TagBadge("Preview", tone: .accent)
                    DemoBadge()
                    Chip("Next.js")
                }
                row("Evidence") { ForEach([EvidenceLevel.verified, .reported, .stale, .unknown], id: \.self) { SourceBadge(level: $0) } }
                row("Connection") {
                    ConnectionState(kind: .connected)
                    ConnectionState(kind: .needsAuth)
                    ConnectionState(kind: .offline)
                    ConnectionState(kind: .failing)
                }
                row("Pickers") {
                    EnvironmentPicker(selection: $tier)
                    SegmentedPill(options: [("24h", "24h"), ("7d", "7d"), ("30d", "30d")], selection: $segment)
                    KitField(placeholder: "Field", text: $text, icon: .search).frame(width: 200)
                }
                HStack(spacing: Space.md) {
                    MetricTile(label: "New leads", value: "27", sub: "From 2 sources", tone: .ok, delta: "+18%", spark: [3, 5, 4, 7, nil, 6, 9, 8])
                    MetricTile(label: "Healthy environments", value: "—", sub: "No health source connected", tone: .muted)
                }
                .frame(width: 440)
                HStack(alignment: .top, spacing: Space.lg) {
                    VStack(alignment: .leading, spacing: Space.md) {
                        ErrorState(title: "Could not reach the endpoint", detail: "The TLS certificate could not be verified.", retry: {})
                        LoadingState()
                        CopyableValue(value: "~/code/lumen")
                    }
                    .frame(width: 360)
                    EmptyState(icon: .chart, title: "Connect a metrics source", message: "Nothing is shown until a source reports it.", cta: "Add Source", compact: true) {}
                        .card().frame(width: 360)
                }
                ToastView(text: "Opened lumen in Terminal")
            }
            .padding(Space.section)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Ink.window)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Space.md) {
            Text(title).kitType(.label, Ink.text3).frame(width: 96, alignment: .leading)
            content()
        }
    }
}
