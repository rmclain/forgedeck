import AppKit
import ForgeDeckKit
import SwiftUI

// MARK: Surfaces

extension View {
    /// The standard card: panel fill, hairline border, soft shadow.
    func card(border: Color = Ink.line, radius: CGFloat = Metric.cardRadius) -> some View {
        background(Ink.panel, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(border, lineWidth: Metric.hairline))
            .shadow(color: Ink.shadow, radius: 1, y: 1)
    }

    func hairlineBelow(_ color: Color = Ink.line) -> some View {
        overlay(alignment: .bottom) { color.frame(height: Metric.hairline) }
    }

    func hairlineAbove(_ color: Color = Ink.line2) -> some View {
        overlay(alignment: .top) { color.frame(height: Metric.hairline) }
    }
}

struct SurfaceCard<Content: View>: View {
    var padding: CGFloat = Space.lg
    var border: Color = Ink.line
    var lifts = false
    @ViewBuilder var content: Content
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.panel, in: RoundedRectangle(cornerRadius: Metric.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metric.cardRadius, style: .continuous)
                .strokeBorder(lifts && hovering ? Ink.lineStrong : border, lineWidth: Metric.hairline))
            .shadow(color: lifts && hovering ? Ink.shadowLarge : Ink.shadow, radius: lifts && hovering ? 12 : 1, y: lifts && hovering ? 6 : 1)
            .onHover { inside in
                guard lifts else { return }
                if reduceMotion { hovering = inside } else { withAnimation(Motion.hover) { hovering = inside } }
            }
    }
}

struct CardHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Space.sm) {
            Text(title).kitType(.section)
            if let subtitle { Text(subtitle).kitType(.meta, Ink.text3) }
            Spacer(minLength: Space.sm)
            trailing
        }
    }
}

extension CardHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: Small labels

struct Dot: View {
    var color: Color
    var size: CGFloat = 6
    var body: some View { Circle().fill(color).frame(width: size, height: size).accessibilityHidden(true) }
}

/// A status in words with a colored dot. The word carries the meaning, the color repeats it.
struct StatusPill: View {
    let label: String
    let tone: Tone
    var large = false

    init(_ label: String, tone: Tone, large: Bool = false) {
        self.label = label
        self.tone = tone
        self.large = large
    }

    init(_ badge: StatusBadge, large: Bool = false) {
        self.init(badge.label, tone: badge.tone, large: large)
    }

    var body: some View {
        HStack(spacing: Space.xs) {
            Dot(color: Ink.tone(tone), size: large ? 6 : 5) // grid: ok dot size from the design
            Text(label).kitType(large ? .labelMedium : .metaMedium, Ink.tone(tone)).lineLimit(1)
        }
        .padding(.horizontal, 6) // grid: ok pill inset from the design
        .padding(.vertical, large ? 2 : 1)
        .background(Ink.tone(tone).soft(), in: RoundedRectangle(cornerRadius: Metric.chipRadius, style: .continuous))
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(label)")
    }
}

/// A small capital label like PROD, LIVE, DEMO.
struct TagBadge: View {
    let text: String
    var tone: Tone = .muted
    var filled = false

    init(_ text: String, tone: Tone = .muted, filled: Bool = false) {
        self.text = text
        self.tone = tone
        self.filled = filled
    }

    var body: some View {
        Text(text.uppercased())
            .kitType(.badge, filled ? (tone == .prod ? Ink.onProd : Ink.onAccent) : (tone == .muted ? Ink.text2 : Ink.tone(tone)))
            .padding(.horizontal, 5) // grid: ok badge inset from the design
            .padding(.vertical, 2)
            .background(filled ? (tone == .prod ? Ink.prod : Ink.accent) : (tone == .muted ? Ink.chip : Ink.tone(tone).soft()),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .fixedSize()
    }
}

/// Marks sample data from fixtures. Shown wherever a demo value appears.
struct DemoBadge: View {
    var body: some View {
        TagBadge("Demo")
            .help("Sample data from a checked-in fixture. It is not connected to any real system.")
            .accessibilityLabel("Demo data")
    }
}

struct Chip: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).kitType(.meta, Ink.text2).lineLimit(1)
            .padding(.horizontal, 7) // grid: ok chip inset from the design
            .padding(.vertical, 2)
            .background(Ink.chip, in: RoundedRectangle(cornerRadius: Metric.chipRadius, style: .continuous))
            .fixedSize()
    }
}

/// Lays children out in rows and wraps to the next row when one is full, so a list of chips never widens its container.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4 // grid: ok Space.xs, which is main-actor isolated and can't be a default here

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                let width = min(size.width, bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: width, height: size.height))
                x += width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let itemWidth = min(size.width, width)
            if !current.indices.isEmpty, current.width + spacing + itemWidth > width {
                rows.append(current)
                current = Row()
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + itemWidth
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

struct Kbd: View {
    let keys: String
    init(_ keys: String) { self.keys = keys }
    var body: some View { Text(keys).kitType(.meta, Ink.text3).accessibilityHidden(true) }
}

/// How strong the evidence is, and where it came from.
struct SourceBadge: View {
    let level: EvidenceLevel
    var source: String?
    var observedAt: Date?
    var isDemo = false

    private var tone: Tone {
        switch level {
        case .verified: .ok
        case .reported: .accent
        case .stale: .warn
        case .unknown: .muted
        }
    }

    private var symbol: String {
        switch level {
        case .verified: "checkmark.seal.fill"
        case .reported: "doc.text"
        case .stale: "clock"
        case .unknown: "questionmark.circle"
        }
    }

    private var explanation: String {
        var text: String
        switch level {
        case .verified: text = "Verified: the target itself reported this."
        case .reported: text = "Reported: a CI or provider record says so. The running system did not confirm it."
        case .stale: text = "Stale: this was observed, but it is past its expiry. Refresh to check again."
        case .unknown: text = "Unknown: nothing was observed, or the last check failed."
        }
        if let source { text += " Source: \(source)." }
        if let observedAt { text += " Seen \(RelativeTime.short(observedAt))." }
        return text
    }

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(Ink.tone(tone)).accessibilityHidden(true)
            Text(level.title).kitType(.metaMedium, Ink.tone(tone))
            if isDemo { DemoBadge() }
        }
        .fixedSize()
        .help(explanation)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Evidence: \(level.title)\(isDemo ? ", demo data" : "")")
        .accessibilityHint(explanation)
    }
}

/// A connection's state in words.
struct ConnectionState: View {
    enum Kind { case connected, needsAuth, offline, notConfigured, failing, checking, stale }
    let kind: Kind
    var detail: String?

    private var label: String {
        switch kind {
        case .connected: "Connected"
        case .needsAuth: "Authentication required"
        case .offline: "Offline"
        case .notConfigured: "Not connected"
        case .failing: "Failing"
        case .checking: "Checking…"
        case .stale: "Stale"
        }
    }

    private var tone: Tone {
        switch kind {
        case .connected: .ok
        case .needsAuth, .stale: .warn
        case .failing: .err
        case .offline, .notConfigured, .checking: .muted
        }
    }

    static func kind(for problem: ObservationProblem?) -> Kind {
        switch problem {
        case nil: .connected
        case .unauthorized?, .forbidden?: .needsAuth
        case .offline?: .offline
        case .notConfigured?: .notConfigured
        default: .failing
        }
    }

    var body: some View {
        HStack(spacing: 6) { // grid: ok dot gap from the design
            Dot(color: Ink.tone(tone))
            Text(detail ?? label).kitType(.label, Ink.tone(tone)).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Product icon

struct ProjectIcon: View {
    let monogram: String
    let hue: Double
    var size: CGFloat = 40

    init(_ product: Product, size: CGFloat = 40) {
        monogram = product.monogram
        hue = product.hue
        self.size = size
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(LinearGradient(colors: Ink.iconGradient(hue: hue), startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5)) // grid: ok drawing size from the design, not layout spacing
            .overlay {
                Text(size < 20 ? String(monogram.prefix(1)).uppercased() : monogram)
                    .font(.system(size: size * 0.36, weight: size < 20 ? .bold : .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(size > 30 ? 0.14 : 0), radius: size > 50 ? 6 : 2, y: size > 50 ? 4 : 1)
            .accessibilityHidden(true)
    }
}

// MARK: Buttons

struct KitButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, production, ghost, icon, toolbar, link }
    var kind: Kind = .secondary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        KitButtonBody(configuration: configuration, kind: kind, compact: compact)
    }
}

extension ButtonStyle where Self == KitButtonStyle {
    static func kit(_ kind: KitButtonStyle.Kind = .secondary, compact: Bool = false) -> KitButtonStyle {
        KitButtonStyle(kind: kind, compact: compact)
    }
}

private struct KitButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: KitButtonStyle.Kind
    let compact: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    private var foreground: Color {
        switch kind {
        case .primary: Ink.onAccent
        case .production: Ink.onProd
        case .secondary: Ink.text
        case .ghost, .toolbar: hovering ? Ink.text : Ink.text2
        case .icon: hovering ? Ink.text : Ink.text2
        case .link: Ink.accentText
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: Ink.accent
        case .production: Ink.prod
        case .secondary, .icon: Ink.button
        case .ghost, .toolbar: hovering || configuration.isPressed ? Ink.hover : .clear
        case .link: .clear
        }
    }

    private var border: Color {
        switch kind {
        case .secondary, .icon: hovering ? Ink.lineStrong : Ink.buttonLine
        default: .clear
        }
    }

    private var height: CGFloat { kind == .link ? 20 : compact ? 24 : kind == .icon ? 26 : Metric.buttonHeight } // grid: ok icon button height from the design

    var body: some View {
        configuration.label
            .font(.system(size: compact ? 11.5 : 12.5, weight: kind == .production ? .semibold : .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, kind == .icon || kind == .toolbar ? 0 : kind == .link ? 0 : compact ? Space.sm : Space.md)
            .frame(width: kind == .icon || kind == .toolbar ? Metric.iconButtonWidth : nil, height: height)
            .background(fill, in: RoundedRectangle(cornerRadius: kind == .toolbar || kind == .icon ? Metric.rowRadius : Metric.controlRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: kind == .icon ? Metric.rowRadius : Metric.controlRadius, style: .continuous)
                .strokeBorder(border, lineWidth: Metric.hairline))
            .shadow(color: kind == .secondary ? Ink.shadow : .clear, radius: 1, y: 1)
            .brightness(configuration.isPressed ? -0.06 : hovering && (kind == .primary || kind == .production) ? 0.04 : 0)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .onHover { hovering = $0 && isEnabled }
            .animation(Motion.hover, value: hovering)
    }
}

/// A button showing only an icon, with a tooltip and a VoiceOver label.
struct IconButton: View {
    let icon: KitIcon
    let label: String
    var kind: KitButtonStyle.Kind = .icon
    var action: () -> Void

    init(_ icon: KitIcon, label: String, kind: KitButtonStyle.Kind = .icon, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.kind = kind
        self.action = action
    }

    var body: some View {
        Button(action: action) { Icon(icon, size: kind == .toolbar ? 15 : 13) }
            .buttonStyle(.kit(kind))
            .help(label)
            .accessibilityLabel(label)
    }
}

/// A row that highlights on hover and selection, like a sidebar item.
struct RowButtonStyle: ButtonStyle {
    var selected = false
    var height: CGFloat = Metric.rowHeight

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, selected: selected, height: height)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        let height: CGFloat
        @State private var hovering = false
        @Environment(\.appearsActive) private var appearsActive

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
                .background(selected ? Ink.selection.opacity(appearsActive ? 1 : 0.6) : hovering || configuration.isPressed ? Ink.hover : .clear,
                            in: RoundedRectangle(cornerRadius: Metric.rowRadius, style: .continuous))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

// MARK: Segmented control

struct SegmentedPill<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var compact = false
    var stretch = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label)
                        .kitType(compact ? .metaMedium : .labelMedium, on ? Ink.text : Ink.text2)
                        .padding(.horizontal, Space.sm)
                        .frame(maxWidth: stretch ? .infinity : nil)
                        .frame(height: compact ? 20 : 24)
                        .background(on ? Ink.panel : .clear, in: RoundedRectangle(cornerRadius: Metric.chipRadius, style: .continuous))
                        .shadow(color: on ? Ink.shadow : .clear, radius: 1, y: 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Ink.field, in: RoundedRectangle(cornerRadius: Metric.controlRadius, style: .continuous))
    }
}

struct FilterChip: View {
    let label: String
    let selected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label).kitType(.labelMedium, selected ? Ink.text : Ink.text2)
                .padding(.horizontal, Space.sm).frame(height: 24)
                .background(selected || hovering ? Ink.selection : .clear, in: RoundedRectangle(cornerRadius: Metric.rowRadius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Fields

struct KitField: View {
    let placeholder: String
    @Binding var text: String
    var icon: KitIcon?
    var secure = false
    var monospaced = false

    var body: some View {
        HStack(spacing: Space.sm) {
            if let icon { Icon(icon, size: 12).foregroundStyle(Ink.text3) }
            Group {
                if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
            }
            .textFieldStyle(.plain)
            .font(monospaced ? KitType.mono.font : KitType.body.font)
            .foregroundStyle(Ink.text)
        }
        .padding(.horizontal, Space.sm)
        .frame(height: Metric.controlHeight)
        .background(Ink.field, in: RoundedRectangle(cornerRadius: Metric.controlRadius, style: .continuous))
    }
}

struct LabeledField<Content: View>: View {
    let label: String
    var hint: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label).kitType(.labelMedium, Ink.text2)
            content
            if let hint { Text(hint).kitType(.meta, Ink.text3).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

// MARK: Values

struct KeyValueRow: View {
    let key: String
    let value: String
    var mono = false
    var tone: Tone?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            Text(key).kitType(.label, Ink.text3)
            Spacer(minLength: Space.sm)
            Text(value).kitType(mono ? .monoSmall : .label, tone.map(Ink.tone) ?? Ink.text2)
                .lineLimit(1).truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A value with a copy button. Never used for secrets.
struct CopyableValue: View {
    let value: String
    var display: String?
    var mono = true
    @State private var copied = false

    var body: some View {
        HStack(spacing: Space.xs) {
            Text(display ?? value).kitType(mono ? .monoSmall : .label, Ink.text2).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
            } label: {
                Icon(copied ? .check : .copy, size: 10).foregroundStyle(copied ? Ink.ok : Ink.text3)
            }
            .buttonStyle(.plain)
            .help(copied ? "Copied" : "Copy")
            .accessibilityLabel("Copy \(display ?? value)")
        }
    }
}

// MARK: Charts

/// A spark line. Missing points leave a gap: no value is not zero.
struct Sparkline: View {
    let values: [Double?]
    var color: Color = Ink.accentText
    var fill = true

    private func points(in size: CGSize) -> [[CGPoint]] {
        let known = values.compactMap { $0 }
        guard values.count > 1, let low = known.min(), let high = known.max() else { return [] }
        let range = high - low == 0 ? 1 : high - low
        var runs: [[CGPoint]] = [[]]
        for (index, value) in values.enumerated() {
            guard let value else {
                if !(runs.last?.isEmpty ?? true) { runs.append([]) }
                continue
            }
            let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
            let y = size.height - 2 - CGFloat((value - low) / range) * (size.height - 6)
            runs[runs.count - 1].append(CGPoint(x: x, y: y))
        }
        return runs.filter { !$0.isEmpty }
    }

    private func smooth(_ run: [CGPoint]) -> Path {
        var path = Path()
        guard let first = run.first else { return path }
        path.move(to: first)
        for index in 1..<max(1, run.count) {
            let a = run[index - 1], b = run[index]
            let mid = (a.x + b.x) / 2
            path.addCurve(to: b, control1: CGPoint(x: mid, y: a.y), control2: CGPoint(x: mid, y: b.y))
        }
        return path
    }

    var body: some View {
        Canvas { context, size in
            for run in points(in: size) {
                let line = smooth(run)
                if fill, run.count > 1, let first = run.first, let last = run.last {
                    var area = line
                    area.addLine(to: CGPoint(x: last.x, y: size.height))
                    area.addLine(to: CGPoint(x: first.x, y: size.height))
                    area.closeSubpath()
                    context.fill(area, with: .color(color.opacity(0.12)))
                }
                if run.count == 1, let only = run.first {
                    context.fill(Path(ellipseIn: CGRect(x: only.x - 1.5, y: only.y - 1.5, width: 3, height: 3)), with: .color(color)) // grid: ok drawing size from the design, not layout spacing
                } else {
                    context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)) // grid: ok drawing size from the design, not layout spacing
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The larger chart on a product page, with dashed guides and day labels.
struct TrendChart: View {
    let values: [Double?]
    let labels: [String]
    var color: Color = Ink.accentText

    var body: some View {
        VStack(spacing: Space.xs) {
            Canvas { context, size in
                var guides = Path()
                for fraction in [0.25, 0.55, 0.87] {
                    guides.move(to: CGPoint(x: 0, y: size.height * fraction))
                    guides.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                }
                context.stroke(guides, with: .color(Ink.line), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            }
            .overlay { Sparkline(values: values, color: color).padding(.vertical, Space.sm) }
            .frame(height: 148)
            HStack {
                ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                    if index > 0 { Spacer(minLength: 0) }
                    Text(label).kitType(.meta, Ink.text3)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trend chart")
    }
}

/// One bar per health check, oldest first.
struct HealthBars: View {
    let samples: [HealthSample]
    var count = 30

    var body: some View {
        let recent = Array(samples.suffix(count))
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { index in
                let offset = index - (count - recent.count)
                RoundedRectangle(cornerRadius: 2)
                    .fill(offset < 0 ? Ink.line : recent[offset].ok
                        ? ((recent[offset].latencyMS ?? 0) > 800 ? Ink.warn : Ink.ok.opacity(0.7)) : Ink.err)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(recent.filter(\.ok).count) of \(recent.count) recent checks passed")
    }
}

// MARK: Metric tile

struct MetricTile: View {
    let label: String
    let value: String
    var sub: String
    var tone: Tone = .accent
    var delta: String?
    var deltaTone: Tone = .ok
    var spark: [Double?] = []
    var isDemo = false
    var action: (() -> Void)?

    var body: some View {
        Group {
            // A tile that goes nowhere is not a button: a disabled button would dim its numbers.
            if let action {
                Button(action: action) { tile }.buttonStyle(.plain)
            } else {
                tile
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value). \(sub)\(isDemo ? ". Demo data" : "")")
        .accessibilityAddTraits(action == nil ? [] : .isButton)
    }

    private var tile: some View {
        SurfaceCard(padding: 0, lifts: action != nil) {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.xs) {
                    Text(label).kitType(.labelMedium, Ink.text2).lineLimit(1)
                    Spacer(minLength: 0)
                    if let delta {
                        Text(delta).kitType(.metaStrong, Ink.tone(deltaTone))
                            .padding(.horizontal, 6).padding(.vertical, 1) // grid: ok delta inset from the design
                            .background(Ink.tone(deltaTone).soft(), in: RoundedRectangle(cornerRadius: Metric.chipRadius))
                    }
                }
                Text(value).kitType(.metric).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                HStack(spacing: Space.xs) {
                    Dot(color: Ink.tone(tone))
                    Text(sub).kitType(.meta, Ink.text3).lineLimit(1)
                    Spacer(minLength: 0)
                    if isDemo { DemoBadge() }
                }
                Sparkline(values: spark, color: Ink.tone(tone)).frame(height: 28).padding(.top, Space.xs)
            }
            .padding(.horizontal, Space.md).padding(.top, Space.md).padding(.bottom, Space.sm)
        }
    }
}

// MARK: Rows

struct ToneIcon: View {
    let icon: KitIcon
    let tone: Tone
    var size: CGFloat = 26 // grid: ok icon tile size from the design

    var body: some View {
        RoundedRectangle(cornerRadius: Metric.tileRadius, style: .continuous)
            .fill(tone == .muted ? Ink.chip : Ink.tone(tone).soft(0.14))
            .frame(width: size, height: size)
            .overlay { Icon(icon, size: size * 0.5, weight: .medium).foregroundStyle(tone == .muted ? Ink.text2 : Ink.tone(tone)) }
            .accessibilityHidden(true)
    }
}

extension ActivityKind {
    var icon: KitIcon {
        switch self {
        case .commit: .commit
        case .pullRequest: .pullRequest
        case .deploy: .deploy
        case .checkFailed: .error
        case .checkRecovered, .recovery: .check
        case .lead: .lead
        case .purchase: .purchase
        case .alert: .alert
        case .authFailure: .key
        case .terminal: .terminal
        case .custom: .activity
        }
    }

    var tone: Tone {
        switch self {
        case .purchase, .deploy, .checkRecovered, .recovery: .ok
        case .lead, .commit, .pullRequest, .terminal: .accent
        case .alert, .authFailure: .warn
        case .checkFailed: .err
        case .custom: .muted
        }
    }
}

struct ActivityRow: View {
    let event: ActivityEvent
    let productName: String?
    var now: Date = .now

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            ToneIcon(icon: event.kind.icon, tone: event.kind.tone)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).kitType(.labelMedium).lineLimit(2)
                HStack(spacing: Space.xs) {
                    if let productName { Text(productName).kitType(.meta, Ink.text2).lineLimit(1) }
                    if productName != nil, !event.detail.isEmpty { Text("·").kitType(.meta, Ink.text3) }
                    Text(event.detail).kitType(.meta, Ink.text3).lineLimit(1)
                    if event.isDemo { DemoBadge() }
                }
            }
            Spacer(minLength: Space.xs)
            Text(RelativeTime.compact(event.at, now: now)).kitType(.meta, Ink.text3).monospacedDigit().fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

/// A row with an icon, two lines, and something on the right.
struct ActionRow<Trailing: View>: View {
    let icon: KitIcon
    var tone: Tone = .muted
    let title: String
    var subtitle: String?
    var mono = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Space.sm) {
            ToneIcon(icon: icon, tone: tone)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).kitType(mono ? .mono : .labelMedium).lineLimit(1).truncationMode(.middle)
                if let subtitle, !subtitle.isEmpty { Text(subtitle).kitType(.meta, Ink.text3).lineLimit(1).truncationMode(.middle) }
            }
            Spacer(minLength: Space.sm)
            trailing
        }
        .padding(.vertical, Space.xs)
    }
}

// MARK: States

struct EmptyState: View {
    let icon: KitIcon
    let title: String
    let message: String
    var cta: String?
    var kbd: String?
    var hint: String?
    var compact = false
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Space.sm) {
            ZStack {
                if !compact {
                    Circle().strokeBorder(Ink.line2, lineWidth: Metric.hairline).frame(width: 120, height: 120)
                    Circle().strokeBorder(Ink.line, lineWidth: Metric.hairline).frame(width: 96, height: 96)
                }
                RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous)
                    .fill(LinearGradient(colors: [Ink.panel, Ink.panel2], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: compact ? 12 : 16, style: .continuous).strokeBorder(Ink.line, lineWidth: Metric.hairline))
                    .shadow(color: Ink.shadowLarge, radius: 10, y: 6)
                    .frame(width: compact ? 44 : 64, height: compact ? 44 : 64)
                    .overlay { Icon(icon, size: compact ? 18 : 26, weight: .light).foregroundStyle(Ink.accentText) }
            }
            .frame(height: compact ? 52 : 124)
            Text(title).kitType(compact ? .section : .cardTitle).multilineTextAlignment(.center)
            Text(message).kitType(compact ? .label : .body, Ink.text2).multilineTextAlignment(.center)
                .lineSpacing(2).frame(maxWidth: 400).fixedSize(horizontal: false, vertical: true)
            if cta != nil || hint != nil {
                HStack(spacing: Space.sm) {
                    if let cta, let action {
                        Button(action: action) {
                            HStack(spacing: Space.sm) {
                                Text(cta)
                                if let kbd { Text(kbd).opacity(0.7) }
                            }
                        }
                        .buttonStyle(.kit(.primary))
                    }
                    if let hint, !hint.isEmpty { Text(hint).kitType(.label, Ink.text3) }
                }
                .padding(.top, Space.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? Space.xxl : 64)
        .padding(.horizontal, Space.xxl)
    }
}

struct ErrorState: View {
    let title: String
    let detail: String
    var retryLabel = "Try Again"
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            ToneIcon(icon: .alert, tone: .err)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).kitType(.labelMedium)
                Text(detail).kitType(.label, Ink.text2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.sm)
            if let retry { Button(retryLabel, action: retry).buttonStyle(.kit(.secondary, compact: true)) }
        }
        .padding(Space.md)
        .background(Ink.err.soft(0.08), in: RoundedRectangle(cornerRadius: Metric.controlRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Skeleton rows while something loads.
struct LoadingState: View {
    var rows = 3
    var label = "Loading"
    @State private var phase = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            ForEach(0..<rows, id: \.self) { index in
                HStack(spacing: Space.sm) {
                    RoundedRectangle(cornerRadius: Metric.tileRadius).fill(Ink.chip).frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        RoundedRectangle(cornerRadius: 4).fill(Ink.chip).frame(width: index % 2 == 0 ? 180 : 140, height: 12)
                        RoundedRectangle(cornerRadius: 4).fill(Ink.chip).frame(width: index % 2 == 0 ? 120 : 200, height: 8)
                    }
                }
            }
        }
        .opacity(phase ? 0.55 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// A titled panel beside or below a list, for details about the selection.
struct InspectorPanel<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).kitType(.section)
                if let subtitle { Text(subtitle).kitType(.meta, Ink.text3) }
            }
            .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hairlineBelow(Ink.line2)
            content.padding(Space.lg)
        }
        .card()
    }
}

struct DoctorStepRow: View {
    let step: DoctorStep

    private var tone: Tone {
        switch step.state {
        case .pass: .ok
        case .warn: .warn
        case .fail: .err
        case .skipped: .muted
        }
    }

    private var symbol: String {
        switch step.state {
        case .pass: "checkmark"
        case .warn: "exclamationmark"
        case .fail: "xmark"
        case .skipped: "minus"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Circle().fill(Ink.tone(tone).soft(0.16)).frame(width: 20, height: 20)
                .overlay { Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(Ink.tone(tone)) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).kitType(.labelMedium)
                Text(step.detail).kitType(.label, Ink.text2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.title): \(step.state.rawValue). \(step.detail)")
    }
}

// MARK: Toast

struct ToastView: View {
    let text: String
    var isError = false

    var body: some View {
        HStack(spacing: Space.sm) {
            Circle().fill(isError ? Ink.err : Ink.accent).frame(width: 20, height: 20)
                .overlay { Image(systemName: isError ? "exclamationmark" : "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(isError ? .white : Ink.onAccent) }
            Text(text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Ink.onToast).lineLimit(2)
        }
        .padding(.leading, Space.md).padding(.trailing, Space.lg).padding(.vertical, Space.sm)
        .background(Ink.toast, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 10)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// Frosted material that follows the window.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}
