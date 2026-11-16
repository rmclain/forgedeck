import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct UpdaterTests {
    static func release(tag: String, asset: String = "ForgeDeck-0.3.zip", url: String = "https://github.com/o/r/releases/download/v0.3/ForgeDeck-0.3.zip",
                        prerelease: Bool = false) -> String {
        #"{"tag_name":"\#(tag)","name":"ForgeDeck \#(tag)","body":"New: Play","html_url":"https://github.com/o/r/releases/tag/\#(tag)","draft":false,"prerelease":\#(prerelease),"published_at":"2026-11-15T12:00:00Z","assets":[{"name":"notes.txt","browser_download_url":"https://github.com/x"},{"name":"\#(asset)","size":12000000,"browser_download_url":"\#(url)"}]}"#
    }

    @Test func versionsCompareNumerically() {
        #expect(AppVersion.isNewer("v0.3", than: "0.2"))
        #expect(AppVersion.isNewer("0.10", than: "0.9"))
        #expect(AppVersion.isNewer("1.0.1", than: "1.0"))
        #expect(!AppVersion.isNewer("0.2", than: "0.2.0"))
        #expect(!AppVersion.isNewer("v0.2-beta", than: "0.2"))
        #expect(!AppVersion.isNewer("0.1", than: "0.2"))
    }

    @Test func aNewerReleaseWithAZipIsOffered() async throws {
        let http = MockHTTPClient()
        http.on("/repos/o/r/releases/latest", json: Self.release(tag: "v0.3"))
        let result = await UpdateChecker(repository: "o/r", http: http).check(currentVersion: "0.2")
        guard case .available(let release) = result else { Issue.record("expected an update, got \(result)"); return }
        #expect(release.version == "0.3")
        #expect(release.downloadURL.lastPathComponent == "ForgeDeck-0.3.zip")
        #expect(release.notes == "New: Play")
        #expect(http.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(await UpdateChecker(repository: "o/r", http: http).check(currentVersion: "0.3") == .upToDate(latest: "0.3"))
    }

    @Test func noReleasesPrereleasesAndForeignDownloadsAreNotInstalled() async {
        let http = MockHTTPClient()
        http.on("/repos/o/none/releases/latest", status: 404, json: "{}")
        http.on("/repos/o/pre/releases/latest", json: Self.release(tag: "v9", prerelease: true))
        http.on("/repos/o/evil/releases/latest", json: Self.release(tag: "v9", url: "https://evil.example/ForgeDeck.zip"))
        http.on("/repos/o/http/releases/latest", json: Self.release(tag: "v9", url: "http://github.com/ForgeDeck.zip"))
        for name in ["none", "pre", "evil", "http"] {
            let result = await UpdateChecker(repository: "o/\(name)", http: http).check(currentVersion: "0.2")
            guard case .noDownload = result else { Issue.record("\(name): \(result)"); continue }
        }
        #expect(UpdateChecker.isTrustedDownload(URL(string: "https://objects.githubusercontent.com/x")!))
        #expect(!UpdateChecker.isTrustedDownload(URL(string: "https://githubusercontent.com.evil.example/x")!))
    }

    @Test func repositoryNamesAreChecked() {
        #expect(UpdateChecker.isValidRepository("rmclain/forgedeck"))
        #expect(!UpdateChecker.isValidRepository("forgedeck"))
        #expect(!UpdateChecker.isValidRepository("a/b/c"))
        #expect(!UpdateChecker.isValidRepository("../x"))
        #expect(!UpdateChecker.isValidRepository("-o/r"))
    }

    @Test func anUpdateFromAnotherTeamIsRefused() async throws {
        let runner = FakeRunner { request in
            if request.arguments.contains("--verify") { return ProcessResult(exitCode: 0) }
            let team = request.arguments.last?.contains("new") == true ? "OTHERTEAM1" : "MYTEAM1234"
            return ProcessResult(exitCode: 0, stderr: "Identifier=com.forgedeck.app\nTeamIdentifier=\(team)\n")
        }
        let installer = UpdateInstaller(runner: runner)
        await #expect(throws: UpdateInstaller.Failure.team(expected: "MYTEAM1234", found: "OTHERTEAM1")) {
            try await installer.verify(URL(fileURLWithPath: "/tmp/new/ForgeDeck.app"), sameTeamAs: URL(fileURLWithPath: "/Applications/ForgeDeck.app"))
        }
        let unsigned = UpdateInstaller(runner: FakeRunner { request in
            ProcessResult(exitCode: 0, stderr: request.arguments.contains("--verify") ? "" : "TeamIdentifier=not set\n")
        })
        await #expect(throws: UpdateInstaller.Failure.self) {
            try await unsigned.verify(URL(fileURLWithPath: "/tmp/new/ForgeDeck.app"), sameTeamAs: URL(fileURLWithPath: "/Applications/ForgeDeck.app"))
        }
        let invalid = UpdateInstaller(runner: FakeRunner { _ in ProcessResult(exitCode: 1, stderr: "a sealed resource is missing or invalid") })
        await #expect(throws: UpdateInstaller.Failure.signature("a sealed resource is missing or invalid")) {
            try await invalid.verify(URL(fileURLWithPath: "/tmp/new/ForgeDeck.app"), sameTeamAs: URL(fileURLWithPath: "/a.app"))
        }
    }
}
