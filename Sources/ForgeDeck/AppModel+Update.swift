import AppKit
import ForgeDeckKit
import SwiftUI

// Checking GitHub releases for a newer ForgeDeck, and installing it.

enum UpdateSettings {
    static let autoKey = "updates.auto"
    static let lastCheckKey = "updates.lastCheck"

    /// owner/name from Info.plist. Empty in a build that has no update source.
    static var repository: String { Bundle.main.object(forInfoDictionaryKey: "FDUpdateRepository") as? String ?? "" }
    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? CLI.version }
    static var isAutomatic: Bool { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
}

extension AppModel {
    /// Once a day at most, and never in snapshots or the self-test.
    func checkForUpdatesIfDue() {
        guard !Runtime.isAutomated, UpdateSettings.isAutomatic, UpdateChecker.isValidRepository(UpdateSettings.repository) else { return }
        let last = UserDefaults.standard.object(forKey: UpdateSettings.lastCheckKey) as? Date ?? .distantPast
        guard Date.now.timeIntervalSince(last) > 86_400 else { return }
        Task { await checkForUpdates(userInitiated: false) }
    }

    func checkForUpdates(userInitiated: Bool) async {
        guard !updateBusy else { return }
        updateBusy = true
        defer { updateBusy = false }
        let result = await UpdateChecker(repository: UpdateSettings.repository).check(currentVersion: UpdateSettings.currentVersion)
        updateStatus = result
        UserDefaults.standard.set(Date.now, forKey: UpdateSettings.lastCheckKey)
        switch result {
        case .available(let release):
            availableUpdate = release
            if userInitiated { sheet = .update(release) } else { show("\(Brand.name) \(release.version) is available. Press Update in the sidebar.") }
        case .upToDate(let latest):
            availableUpdate = nil
            if userInitiated { show("\(Brand.name) \(UpdateSettings.currentVersion) is the newest version (latest release \(latest)).") }
        case .noDownload(let why), .failed(let why):
            if userInitiated { show(why, isError: true) }
        }
    }

    /// Downloads, checks the signature, swaps the app in place (the old one goes to the Trash), and relaunches.
    func installUpdate(_ release: AppRelease) async {
        guard !updateBusy else { return }
        updateBusy = true
        defer { updateBusy = false }
        let installer = UpdateInstaller()
        let work = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "\(Brand.name)/Update")
        let current = Bundle.main.bundleURL
        do {
            updateProgress = "Downloading \(release.version)…"
            let zip = try await installer.download(release, into: work)
            updateProgress = "Checking the signature…"
            let app = try await installer.unpack(zip, into: work)
            try await installer.verify(app, sameTeamAs: current)
            updateProgress = "Installing…"
            var trashed: NSURL?
            try FileManager.default.trashItem(at: current, resultingItemURL: &trashed)
            do {
                try FileManager.default.moveItem(at: app, to: current)
            } catch {
                // Put the old app back so there is always one in place.
                if let trashed = trashed as URL? { try? FileManager.default.moveItem(at: trashed, to: current) }
                throw error
            }
            try? FileManager.default.removeItem(at: work)
            record("app.update", detail: "from=\(UpdateSettings.currentVersion) to=\(release.version)")
            saveNow()
            updateProgress = "Relaunching…"
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            _ = try await NSWorkspace.shared.openApplication(at: current, configuration: configuration)
            skipQuitConfirmation = true
            NSApp.terminate(nil)
        } catch {
            updateProgress = nil
            try? FileManager.default.removeItem(at: work)
            show("\(error)", isError: true)
        }
    }
}

/// What is new, and the button that installs it.
struct UpdateSheet: View {
    @Environment(AppModel.self) private var model
    let release: AppRelease

    var body: some View {
        SheetPanel(width: 560) {
            SheetHeader(icon: .download, tone: .accent, title: "\(Brand.name) \(release.version) is available",
                        message: "You have \(UpdateSettings.currentVersion). The update is checked against this copy's signature before it replaces it, and the old app goes to the Trash. Your products, settings, and secrets are not touched.")
            ScrollView {
                Text(release.notes.isEmpty ? "No release notes." : release.notes)
                    .kitType(.body, Ink.text2).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(maxHeight: 220)
            .padding(Space.md).background(Ink.field, in: RoundedRectangle(cornerRadius: Metric.controlRadius))
            .padding(.horizontal, Space.xl)
            if !model.terminals.running.isEmpty {
                Text("\(model.terminals.running.count) terminal session\(model.terminals.running.count == 1 ? " is" : "s are") running. Relaunching ends \(model.terminals.running.count == 1 ? "it" : "them").")
                    .kitType(.label, Ink.warn).padding(.horizontal, Space.xl)
            }
            SheetFooter {
                Button("View on GitHub") { model.openLink(release.pageURL.absoluteString) }.buttonStyle(.kit(.ghost))
                Spacer()
                Button("Later") { model.sheet = nil }.buttonStyle(.kit(.secondary)).keyboardShortcut(.cancelAction)
                Button(model.updateProgress ?? "Install and Relaunch") { Task { await model.installUpdate(release) } }
                    .buttonStyle(.kit(.primary)).keyboardShortcut(.defaultAction).disabled(model.updateBusy)
            }
        }
    }
}
