import Foundation
import Testing
@testable import ForgeDeckKit

private let nextPackage = """
{
  "name": "web",
  "dependencies": {"next": "15.0.0", "react": "19.0.0"},
  "devDependencies": {"typescript": "5.6.0"},
  "scripts": {"dev": "next dev", "build": "next build", "test": "vitest run"}
}
"""

/// A folder that looks like a Git checkout to discovery: a `.git` directory with a config.
private func makeFakeCheckout(_ url: URL, remote: String? = nil) throws {
    var config = "[core]\n\trepositoryformatversion = 0\n"
    if let remote { config += "[remote \"origin\"]\n\turl = \(remote)\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n" }
    try write(config, to: url.appending(path: ".git/config"))
}

@Suite struct DiscoveryScanTests {
    @Test func dependencyFoldersAreNeverEntered() async throws {
        let root = try makeTempDir("scan")
        defer { removeTemp(root) }
        try write(nextPackage, to: root.appending(path: "app/package.json"))
        try write("{\"name\": \"dep\"}", to: root.appending(path: "app/node_modules/dep/package.json"))
        try write("{\"name\": \"hoisted\"}", to: root.appending(path: "node_modules/hoisted/package.json"))
        try write("[project]\nname = \"api\"\n", to: root.appending(path: "py/pyproject.toml"))
        try write("[project]\nname = \"vendored\"\n", to: root.appending(path: "py/.venv/lib/thing/pyproject.toml"))
        try write("{}", to: root.appending(path: "php/composer.json"))
        try write("{}", to: root.appending(path: "php/vendor/acme/lib/composer.json"))
        try write("// swift-tools-version: 6.0\n", to: root.appending(path: "tools/.build/checkouts/dep/Package.swift"))

        let result = await ProjectDiscovery().scan(root: root)
        #expect(result.projects.map(\.name) == ["app", "php", "py"])
        #expect(!result.hitLimit && !result.cancelled)
        for name in ["node_modules", ".venv", "vendor", ".build", "Pods", "DerivedData"] {
            #expect(ProjectDiscovery.skipped.contains(name))
        }
    }

    @Test func aGitRepositoryIsNotSearchedFurther() async throws {
        let root = try makeTempDir("scan")
        defer { removeTemp(root) }
        try makeFakeCheckout(root.appending(path: "mono"))
        try write(nextPackage, to: root.appending(path: "mono/packages/web/package.json"))
        try write("// swift-tools-version: 6.0\n", to: root.appending(path: "plain/Package.swift"))
        try write(nextPackage, to: root.appending(path: "plain/Examples/Demo/package.json"))
        let result = await ProjectDiscovery().scan(root: root)
        // The monorepo is one project. A folder without Git is still searched for nested projects.
        #expect(result.projects.map(\.name) == ["mono", "plain", "Demo"])
    }

    @Test func aSymlinkLoopDoesNotHangOrDuplicate() async throws {
        let root = try makeTempDir("scan")
        defer { removeTemp(root) }
        try write("// swift-tools-version: 6.0\n", to: root.appending(path: "a/Package.swift"))
        try FileManager.default.createDirectory(at: root.appending(path: "b/c"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "b/c/up"), withDestinationURL: root)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "a/self"), withDestinationURL: root.appending(path: "a"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "alias-of-a"), withDestinationURL: root.appending(path: "a"))

        var limits = DiscoveryLimits()
        limits.maxDepth = 12
        let result = await ProjectDiscovery(limits: limits).scan(root: root)
        #expect(result.projects.map(\.name) == ["a"])
        #expect(result.directoriesVisited <= 4)
        #expect(!result.hitLimit)
    }

    @Test func maxDirectoriesStopsTheScan() async throws {
        let root = try makeTempDir("scan")
        defer { removeTemp(root) }
        for index in 0..<12 { try write("// swift\n", to: root.appending(path: "p\(index)/Package.swift")) }
        var limits = DiscoveryLimits()
        limits.maxDirectories = 4
        let result = await ProjectDiscovery(limits: limits).scan(root: root)
        #expect(result.hitLimit)
        #expect(result.projects.count <= 4)
        #expect(result.directoriesVisited <= 5)
    }

    @Test func maxResultsStopsTheScan() async throws {
        let root = try makeTempDir("scan")
        defer { removeTemp(root) }
        for index in 0..<6 { try write("// swift\n", to: root.appending(path: "p\(index)/Package.swift")) }
        var limits = DiscoveryLimits()
        limits.maxResults = 2
        let limited = await ProjectDiscovery(limits: limits).scan(root: root)
        #expect(limited.hitLimit)
        #expect(limited.projects.count == 2)
        let full = await ProjectDiscovery().scan(root: root)
        #expect(!full.hitLimit)
        #expect(full.projects.count == 6)
    }

    @Test func maxDepthBoundsTheSearch() async throws {
        let root = try makeTempDir("scan")
        defer { removeTemp(root) }
        try write("// swift\n", to: root.appending(path: "near/Package.swift"))
        try write("// swift\n", to: root.appending(path: "x/y/z/far/Package.swift"))
        var limits = DiscoveryLimits()
        limits.maxDepth = 2
        let shallow = await ProjectDiscovery(limits: limits).scan(root: root)
        #expect(shallow.projects.map(\.name) == ["near"])
        let deep = await ProjectDiscovery().scan(root: root)
        #expect(deep.projects.map(\.name) == ["near", "far"])
    }

    @Test func cancellationStopsTheScan() async throws {
        let root = try makeTempDir("scan")
        defer { removeTemp(root) }
        for index in 0..<20 { try write("// swift\n", to: root.appending(path: "p\(index)/Package.swift")) }
        let task = Task {
            // Cancelled before the first directory is read, so the outcome is deterministic.
            withUnsafeCurrentTask { $0?.cancel() }
            return await ProjectDiscovery().scan(root: root)
        }
        let result = await task.value
        #expect(result.cancelled)
        #expect(result.projects.isEmpty)
        #expect(result.directoriesVisited == 0)
    }

    @Test func hiddenFoldersAndFilesAreNotProjects() async throws {
        let root = try makeTempDir("scan")
        defer { removeTemp(root) }
        try write(nextPackage, to: root.appending(path: ".hidden/package.json"))
        try write("just a file", to: root.appending(path: "notes.txt"))
        try FileManager.default.createDirectory(at: root.appending(path: "empty"), withIntermediateDirectories: true)
        let result = await ProjectDiscovery().scan(root: root)
        #expect(result.projects.isEmpty)
        #expect(ProjectDiscovery().inspect(root.appending(path: "empty")) == nil)
    }
}

@Suite struct DiscoverySecretTests {
    @Test func secretBearingNamesAreRecognised() {
        for name in [".env", ".env.local", ".env.production", "prod.env", ".ENV", ".npmrc", ".netrc", ".pypirc", "credentials",
                     "credentials.json", "secrets.yml", "id_rsa", "id_ed25519", "server.pem", "deploy.key", "cert.p12",
                     "release.keystore", "wp-config.php", ".htpasswd", "App.mobileprovision"] {
            #expect(ProjectDiscovery.isSecretBearing(name), "\(name)")
        }
        for name in ["package.json", "README.md", "composer.json", "pyproject.toml", "Dockerfile", "docker-compose.yml",
                     "environment.md", "keyboard.swift", "plugin.php"] {
            #expect(!ProjectDiscovery.isSecretBearing(name), "\(name)")
        }
    }

    @Test func secretFilesInAProjectAreNeverRead() throws {
        let root = try makeTempDir("secrets")
        defer { removeTemp(root) }
        let marker = "DISCOVERY-SECRET-MARKER-91f2"
        try write(nextPackage, to: root.appending(path: "package.json"))
        try write("API_KEY=\(marker)\n", to: root.appending(path: ".env"))
        try write("API_KEY=\(marker)\n", to: root.appending(path: ".env.local"))
        try write("//registry.npmjs.org/:_authToken=\(marker)\n", to: root.appending(path: ".npmrc"))
        try write("-----BEGIN OPENSSH PRIVATE KEY-----\n\(marker)\n-----END OPENSSH PRIVATE KEY-----\n", to: root.appending(path: "id_ed25519"))
        try write("-----BEGIN PRIVATE KEY-----\n\(marker)\n", to: root.appending(path: "server.pem"))
        // A secret-bearing PHP file with a plugin header: the header must not be picked up, because the file is never opened.
        try write("<?php\n/* Plugin Name: \(marker) */\ndefine('DB_PASSWORD', '\(marker)');\n", to: root.appending(path: "wp-config.php"))

        let project = try #require(ProjectDiscovery().inspect(root))
        #expect(project.metadata.wordpressPluginName == nil)
        #expect(!project.metadata.stack.contains("WordPress"))
        #expect(!String(describing: project).contains(marker))
        var portfolio = Portfolio()
        ImportPlanner.apply(ImportPlanner.plan([project], portfolio: portfolio), to: &portfolio)
        let saved = try JSONCoding.encoder().encode(portfolio)
        #expect(!String(decoding: saved, as: UTF8.self).contains(marker))
    }

    @Test func aTokenEmbeddedInTheRemoteURLIsRedacted() throws {
        let root = try makeTempDir("secrets")
        defer { removeTemp(root) }
        let token = "ghp_xxxxxxxxxxxxxxxxxxxxxxxx"
        try makeFakeCheckout(root, remote: "https://user:\(token)@github.com/o/r.git")
        let project = try #require(ProjectDiscovery().inspect(root))
        #expect(project.isGitRepository)
        let remote = try #require(project.remoteURL)
        #expect(!remote.contains(token))
        #expect(!remote.contains("ghp_"))
        #expect(remote.contains("github.com/o/r.git"))
        #expect(project.repository == RepositoryURL(host: "github.com", owner: "o", name: "r"))

        // The token does not reach the portfolio either.
        var portfolio = Portfolio()
        ImportPlanner.apply(ImportPlanner.plan([project], portfolio: portfolio), to: &portfolio)
        let saved = String(decoding: try JSONCoding.encoder().encode(portfolio), as: UTF8.self)
        #expect(!saved.contains(token))
        #expect(portfolio.products[0].repositories[0].webURL == "https://github.com/o/r")
    }

    @Test func aPasswordInAnyRemoteURLIsRedacted() throws {
        let root = try makeTempDir("secrets")
        defer { removeTemp(root) }
        try makeFakeCheckout(root, remote: "https://deploy:hunter2-very-secret@git.example.com/team/app.git")
        let remote = try #require(ProjectDiscovery().inspect(root)?.remoteURL)
        #expect(!remote.contains("hunter2-very-secret"))
        #expect(remote.contains("git.example.com/team/app.git"))
    }

    @Test func originIsPreferredOverOtherRemotes() {
        let config = """
        [core]
        \tbare = false
        [remote "upstream"]
        \turl = https://github.com/upstream/app.git
        [remote "origin"]
        \turl = git@github.com:me/app.git
        [branch "main"]
        \tremote = origin
        """
        #expect(ProjectDiscovery.originURL(inGitConfig: config) == "git@github.com:me/app.git")
        #expect(ProjectDiscovery.originURL(inGitConfig: "[remote \"fork\"]\n\turl = https://example.com/a/b.git\n") == "https://example.com/a/b.git")
        #expect(ProjectDiscovery.originURL(inGitConfig: "[core]\n\tbare = false\n") == nil)
    }
}

@Suite struct DiscoveryMetadataTests {
    @Test func nextJSPackageWithScripts() throws {
        let root = try makeTempDir("meta")
        defer { removeTemp(root) }
        try write(nextPackage, to: root.appending(path: "package.json"))
        let meta = ProjectDiscovery.detectMetadata(in: root)
        #expect(meta.stack == ["Next.js", "React", "TypeScript"])
        #expect(meta.startCommand == ["npm", "run", "dev"])
        #expect(meta.testCommand == ["npm", "test"])
        #expect(meta.devURL == "http://localhost:3000")
        #expect(meta.suggestedKind == .frontend)
    }

    @Test func lockFileSelectsThePackageManager() throws {
        let root = try makeTempDir("meta")
        defer { removeTemp(root) }
        try write("{\"dependencies\": {\"express\": \"4\"}, \"scripts\": {\"start\": \"node .\"}}", to: root.appending(path: "package.json"))
        try write("", to: root.appending(path: "pnpm-lock.yaml"))
        let meta = ProjectDiscovery.detectMetadata(in: root)
        #expect(meta.startCommand == ["pnpm", "run", "start"])
        #expect(meta.testCommand.isEmpty)
        #expect(meta.stack == ["Express"])
        #expect(meta.suggestedKind == .backend)
    }

    @Test func aPackageWithoutKnownFrameworksIsNode() throws {
        let root = try makeTempDir("meta")
        defer { removeTemp(root) }
        try write("{\"name\": \"lib\"}", to: root.appending(path: "package.json"))
        #expect(ProjectDiscovery.detectMetadata(in: root).stack == ["Node.js"])
        // Broken JSON is not a project marker and does not crash.
        try write("{ nope", to: root.appending(path: "package.json"))
        #expect(ProjectDiscovery.detectMetadata(in: root).stack.isEmpty)
    }

    @Test func composerProject() throws {
        let root = try makeTempDir("meta")
        defer { removeTemp(root) }
        try write("{\"require\": {\"php\": \"^8.2\"}}", to: root.appending(path: "composer.json"))
        var meta = ProjectDiscovery.detectMetadata(in: root)
        #expect(meta.stack == ["PHP"])
        #expect(meta.testCommand == ["composer", "test"])
        #expect(meta.suggestedKind == .backend)
        try write("{\"require\": {\"laravel/framework\": \"^11.0\"}}", to: root.appending(path: "composer.json"))
        meta = ProjectDiscovery.detectMetadata(in: root)
        #expect(meta.stack == ["Laravel"])
    }

    @Test func fastAPIProject() throws {
        let root = try makeTempDir("meta")
        defer { removeTemp(root) }
        try write("[project]\nname = \"api\"\ndependencies = [\"fastapi>=0.110\", \"uvicorn\"]\n[tool.pytest.ini_options]\n", to: root.appending(path: "pyproject.toml"))
        let meta = ProjectDiscovery.detectMetadata(in: root)
        #expect(meta.stack == ["FastAPI"])
        #expect(meta.devURL == "http://localhost:8000")
        #expect(meta.testCommand == ["python3", "-m", "pytest"])
        #expect(meta.suggestedKind == .backend)
    }

    @Test func swiftPackage() throws {
        let root = try makeTempDir("meta")
        defer { removeTemp(root) }
        try write("// swift-tools-version: 6.0\nimport PackageDescription\n", to: root.appending(path: "Package.swift"))
        let meta = ProjectDiscovery.detectMetadata(in: root)
        #expect(meta.stack == ["Swift"])
        #expect(meta.testCommand == ["swift", "test"])
    }

    @Test func dockerfileAndComposeServices() throws {
        let root = try makeTempDir("meta")
        defer { removeTemp(root) }
        try write("FROM alpine:3.20\n", to: root.appending(path: "Dockerfile"))
        try write("""
        # stack
        services:
          web:
            image: nginx
            ports:
              - "8080:80"
          "db":
            image: postgres:16
            environment:
              POSTGRES_DB: app

          worker:
            build: .
        volumes:
          data:
        """, to: root.appending(path: "docker-compose.yml"))
        let meta = ProjectDiscovery.detectMetadata(in: root)
        #expect(meta.hasDockerfile)
        #expect(meta.composeServices == ["web", "db", "worker"])
        #expect(meta.stack == ["Docker"])
        let project = try #require(ProjectDiscovery().inspect(root))
        #expect(!project.isGitRepository)
        #expect(project.name == root.lastPathComponent)
    }

    @Test func composeParserIgnoresOtherTopLevelKeys() {
        #expect(ProjectDiscovery.composeServices(in: "version: '3'\nvolumes:\n  data:\nnetworks:\n  front:\n").isEmpty)
        #expect(ProjectDiscovery.composeServices(in: "services:\n    api:\n        image: x\n    cache:\n        image: y\n") == ["api", "cache"])
        #expect(ProjectDiscovery.composeServices(in: "").isEmpty)
    }

    @Test func wordPressPluginHeader() throws {
        let root = try makeTempDir("meta")
        defer { removeTemp(root) }
        try write("""
        <?php
        /**
         * Plugin Name: Acme Forms
         * Description: Forms for Acme.
         * Version: 1.2.0
         */
        defined('ABSPATH') || exit;
        """, to: root.appending(path: "acme-forms.php"))
        let meta = ProjectDiscovery.detectMetadata(in: root)
        #expect(meta.wordpressPluginName == "Acme Forms")
        #expect(meta.stack == ["WordPress", "PHP"])
        #expect(meta.suggestedKind == .plugin)

        let project = try #require(ProjectDiscovery().inspect(root))
        var portfolio = Portfolio()
        ImportPlanner.apply(ImportPlanner.plan([project], portfolio: portfolio), to: &portfolio)
        #expect(portfolio.products[0].name == "Acme Forms")
        #expect(portfolio.products[0].components.first?.kind == .plugin)
    }

    @Test func readmeGivesTheDescription() throws {
        let root = try makeTempDir("meta")
        defer { removeTemp(root) }
        try write("// swift\n", to: root.appending(path: "Package.swift"))
        try write("# Title\n\n![badge](x.svg)\n\nA tool that does one thing well.\n\nMore text.\n", to: root.appending(path: "README.md"))
        #expect(ProjectDiscovery().inspect(root)?.description == "A tool that does one thing well.")
    }

    @Test func mixedStackIsDeduplicated() throws {
        let root = try makeTempDir("meta")
        defer { removeTemp(root) }
        try write(nextPackage, to: root.appending(path: "package.json"))
        try write("FROM node:22\n", to: root.appending(path: "Dockerfile"))
        try write("services:\n  web:\n    build: .\n", to: root.appending(path: "compose.yaml"))
        let meta = ProjectDiscovery.detectMetadata(in: root)
        #expect(meta.stack == ["Next.js", "React", "TypeScript", "Docker"])
        #expect(meta.composeServices == ["web"])
    }
}
