import ForgeDeckKit
import SwiftUI

/// What a product has published, next to the version its code declares.
struct ReleaseState {
    var local: LocalRelease
    var channels: [(ReleaseChannel, ReleaseObservation?)]
    var githubTag: String?
    var githubProvenance: Provenance?

    var isEmpty: Bool { local.facts.isEmpty && channels.isEmpty && githubTag == nil && local.suggestions.isEmpty }
    var findings: [ReleaseFinding] { ReleaseCheck.findings(local: local, channels: channels, githubTag: githubTag) }
}

extension AppModel {
    func releaseState(_ product: Product) -> ReleaseState {
        if let demo = DemoFixtures.releases(for: product, now: now) {
            return ReleaseState(local: demo.local, channels: demo.channels, githubTag: demo.githubTag,
                                githubProvenance: Provenance(observedAt: now, source: .fixture, level: .reported, isDemo: true))
        }
        let channels = (product.releaseChannels ?? []).map { ($0, cache.releases?[$0.id]) }
        let remote = product.repositories.lazy.compactMap { self.cache.remotes[$0.id] }.first { $0.latestReleaseTag != nil }
        return ReleaseState(local: localReleases[product.id] ?? LocalRelease(), channels: channels,
                            githubTag: remote?.latestReleaseTag, githubProvenance: remote?.provenance)
    }

    /// Starts asking a registry for the product's newest published version.
    func trackRelease(_ channel: ReleaseChannel, for product: Product) {
        guard !product.isDemo else { return show("\(product.name) is a demo product. It is not looked up.", isError: true) }
        guard ReleaseChannel.isValidName(channel.package, kind: channel.kind) else {
            return show("\"\(channel.package)\" is not a valid \(channel.kind.title) name.", isError: true)
        }
        guard !(product.releaseChannels ?? []).contains(where: { $0.kind == channel.kind && $0.package == channel.package }) else { return }
        var added = channel
        added.id = UUID()
        update(product.id) { $0.releaseChannels = ($0.releaseChannels ?? []) + [added] }
        record("release.track", product: product, detail: "registry=\(channel.kind.rawValue) package=\(channel.package)")
        guard let current = self.product(product.id) else { return }
        Task {
            apply(await engine.refreshReleases(current))
            let result = cache.releases?[added.id]
            show(result?.version.map { "\(channel.kind.title) publishes \(channel.package) \($0)" } ?? (result?.detail ?? "Added \(channel.package)"),
                 isError: result?.problem != nil)
        }
    }

    func untrackRelease(_ channel: ReleaseChannel, for product: Product) {
        update(product.id) { $0.releaseChannels?.removeAll { $0.id == channel.id } }
        cache.releases?[channel.id] = nil
        record("release.untrack", product: product, detail: "registry=\(channel.kind.rawValue) package=\(channel.package)")
        show("Stopped looking up \(channel.package) on \(channel.kind.title)")
    }
}

struct ReleasesCard: View {
    @Environment(AppModel.self) private var model
    let product: Product

    var body: some View {
        let state = model.releaseState(product)
        let findings = state.findings
        let tracked = Set(state.channels.map { "\($0.0.kind.rawValue):\($0.0.package)" })
        let suggestions = state.local.suggestions.filter { !tracked.contains("\($0.kind.rawValue):\($0.package)") }
        VStack(alignment: .leading, spacing: 0) {
            CardHeader(title: "Releases", subtitle: "What is published, next to the version in the code") {
                if product.isDemo { DemoBadge() }
                Button("Track a Registry…") { model.sheet = .releaseChannel(product.id) }
                    .buttonStyle(.kit(.secondary, compact: true)).disabled(product.isDemo)
                    .help("Look up the newest version on WordPress.org, npm, or PyPI on every refresh")
            }
            .padding(Space.lg)
            if !state.local.facts.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("In the code").kitType(.labelMedium, Ink.text2)
                    ForEach(state.local.facts) { fact in
                        HStack(spacing: Space.sm) {
                            Text(fact.label).kitType(.label, Ink.text2).frame(width: 150, alignment: .leading) // grid: ok label column
                            Text(fact.version).kitType(.mono, Ink.text)
                            Text(fact.file).kitType(.monoSmall, Ink.text3).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.horizontal, Space.lg).padding(.bottom, Space.md)
            }
            ForEach(state.channels, id: \.0.id) { channel, observation in channelRow(channel, observation) }
            if let tag = state.githubTag {
                row(icon: .branch, title: "GitHub release", detail: nil, version: tag,
                    badge: state.githubProvenance.map { SourceBadge(level: $0.effectiveLevel(now: model.now), source: $0.source.title, observedAt: $0.observedAt, isDemo: $0.isDemo) }) { EmptyView() }
            }
            if !findings.isEmpty {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(findings) { finding in
                        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                            Icon(finding.tone == .ok ? .check : .alert, size: 11).foregroundStyle(finding.tone == .ok ? Ink.ok : Ink.warn)
                            Text(finding.text).kitType(.label, Ink.text).fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(Space.lg).frame(maxWidth: .infinity, alignment: .leading).hairlineAbove()
            }
            ForEach(suggestions, id: \.self) { suggestion in
                HStack(spacing: Space.sm) {
                    Icon(.info, size: 12).foregroundStyle(Ink.text3)
                    Text("Is this \(suggestion.package) on \(suggestion.kind.title)? Track it to compare each release.").kitType(.label, Ink.text2).lineLimit(2)
                    Spacer(minLength: Space.sm)
                    Button("Track") { model.trackRelease(suggestion, for: product) }
                        .buttonStyle(.kit(.secondary, compact: true)).disabled(product.isDemo)
                        .help("Asks \(suggestion.kind.title)'s public API for \(suggestion.package) on each refresh. Only the name is sent.")
                }
                .padding(.horizontal, Space.lg).padding(.vertical, Space.sm).hairlineAbove()
            }
        }
        .card()
    }

    private func channelRow(_ channel: ReleaseChannel, _ observation: ReleaseObservation?) -> some View {
        let level = observation?.provenance.effectiveLevel(now: model.now)
        let failed = observation?.problem != nil && observation?.version == nil
        return row(icon: .tag, title: channel.kind.title, detail: failed ? observation?.detail : nil,
                   version: observation?.version ?? (failed ? nil : "Not looked up yet"), package: channel.package,
                   badge: observation.map { SourceBadge(level: level ?? .unknown, source: $0.provenance.source.title, observedAt: $0.provenance.observedAt, isDemo: $0.provenance.isDemo) }) {
            IconButton(.external, label: "Open \(channel.package) on \(channel.kind.title)") { model.openLink(channel.pageURL) }
            if !product.isDemo {
                IconButton(.trash, label: "Stop tracking \(channel.package)") { model.untrackRelease(channel, for: product) }
            }
        }
    }

    private func row<Trailing: View>(icon: KitIcon, title: String, detail: String?, version: String?, package: String? = nil,
                                     badge: SourceBadge?, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: Space.md) {
            Icon(icon, size: 13).foregroundStyle(Ink.text2).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(title).kitType(.labelMedium)
                    if let package { Text(package).kitType(.monoSmall, Ink.text3).lineLimit(1) }
                }
                if let detail { Text(detail).kitType(.meta, Ink.warn).lineLimit(2) }
            }
            Spacer(minLength: Space.sm)
            if let version { Text(version).kitType(.mono, Ink.text) }
            if let badge { badge }
            trailing()
        }
        .padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
        .hairlineAbove()
        .accessibilityElement(children: .contain)
    }
}

struct ReleaseChannelSheet: View {
    @Environment(AppModel.self) private var model
    let productID: UUID
    @State private var kind: ReleaseChannel.Kind = .wordpressOrg
    @State private var package = ""

    var body: some View {
        let product = model.product(productID)
        let name = package.trimmingCharacters(in: .whitespaces)
        let valid = ReleaseChannel.isValidName(name, kind: kind)
        SheetPanel(width: 520) {
            SheetHeader(icon: .tag, title: "Track Releases of \(product?.name ?? "Product")",
                        message: "For something you ship rather than host: a plugin, a package. \(Brand.name) compares the newest published version with the version in the code.")
            VStack(alignment: .leading, spacing: Space.md) {
                SegmentedPill(options: ReleaseChannel.Kind.allCases.map { ($0, $0.title) }, selection: $kind, stretch: true)
                LabeledField(label: kind.packageLabel, hint: hint) {
                    KitField(placeholder: kind == .wordpressOrg ? "my-plugin" : kind == .npm ? "@scope/package" : "package-name", text: $package, icon: .tag, monospaced: true)
                }
                if !name.isEmpty, !valid { Text("That is not a valid \(kind.title) name.").kitType(.meta, Ink.err) }
            }
            .padding(.horizontal, Space.xl)
            .onAppear {
                if let suggestion = product.flatMap({ model.releaseState($0).local.suggestions.first }) { kind = suggestion.kind; package = suggestion.package }
            }
            SheetFooter(note: "A public, read-only request on each refresh. Only the name is sent; no token.") {
                Button("Cancel") { model.sheet = nil }.buttonStyle(.kit(.secondary)).keyboardShortcut(.cancelAction)
                Button("Track") {
                    model.sheet = nil
                    if let product { model.trackRelease(ReleaseChannel(kind: kind, package: name), for: product) }
                }
                .buttonStyle(.kit(.primary)).keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
    }

    private var hint: String {
        switch kind {
        case .wordpressOrg: "The part after wordpress.org/plugins/. Usually the plugin's folder name or Text Domain."
        case .npm: "As in npm install. Scoped names start with @."
        case .pypi: "As in pip install."
        }
    }
}
