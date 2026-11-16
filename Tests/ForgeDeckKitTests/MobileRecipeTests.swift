import Foundation
import Testing
@testable import ForgeDeckKit

@Suite struct MobileRecipeTests {
    static let simulators = #"""
    {"devices":{
      "com.apple.CoreSimulator.SimRuntime.iOS-18-2":[{"name":"iPhone 16 Pro","udid":"OLD-PRO","isAvailable":true}],
      "com.apple.CoreSimulator.SimRuntime.iOS-26-5":[
        {"name":"iPad Pro 13-inch (M5)","udid":"IPAD","isAvailable":true},
        {"name":"iPhone 17 Pro Max","udid":"MAX","isAvailable":true},
        {"name":"iPhone 17 Pro","udid":"PRO","isAvailable":true},
        {"name":"iPhone 17","udid":"BASE","isAvailable":false}],
      "com.apple.CoreSimulator.SimRuntime.watchOS-12-0":[{"name":"Apple Watch","udid":"WATCH","isAvailable":true}]}}
    """#

    @Test func simulatorsAreParsedNewestFirstAndAProIPhoneIsPreferred() {
        let devices = MobileDevices.parseSimulators(Data(Self.simulators.utf8))
        #expect(devices.first?.runtime == "iOS 26.5")
        #expect(!devices.contains { $0.id == "WATCH" || $0.id == "BASE" })
        #expect(MobileDevices(iosSimulators: devices).preferredIPhone?.id == "PRO")
        #expect(MobileDevices.parseSimulators(Data("nope".utf8)).isEmpty)
    }

    func capacitorProject(scripts: [String: String], android: Bool = true) throws -> URL {
        let root = try makeTempDir("cap app")
        try write(#"{"appId":"com.example.app","webDir":"www"}"#, to: root.appending(path: "capacitor.config.json"))
        let json = try JSONSerialization.data(withJSONObject: ["name": "x", "scripts": scripts])
        try json.write(to: root.appending(path: "package.json"))
        try FileManager.default.createDirectory(at: root.appending(path: "ios/App/App.xcodeproj"), withIntermediateDirectories: true)
        if android {
            try FileManager.default.createDirectory(at: root.appending(path: "android"), withIntermediateDirectories: true)
            try write("", to: root.appending(path: "android/gradlew"))
        }
        return root
    }

    @Test func aCapacitorAppGetsXcodeSimulatorAndEmulatorRecipes() throws {
        let root = try capacitorProject(scripts: ["build:app": "node tools/build_app.mjs && npx cap sync", "ios": "x", "android": "y"])
        defer { removeTemp(root) }
        var checkout = LocalCheckout()
        checkout.path = root.path
        let devices = MobileDevices(iosSimulators: [MobileDevice(name: "iPhone 17 Pro", id: "PRO", runtime: "iOS 26.5")],
                                    androidEmulators: [MobileDevice(name: "ccc pixel7", id: "ccc_pixel7", runtime: "Android")])
        let recipes = MobileRecipes.recipes(for: checkout, environmentID: nil, devices: devices)
        func steps(_ label: String) -> [[String]]? { recipes.first { $0.label == label }?.steps }
        #expect(steps("Open iOS Project in Xcode") == [["npm", "run", "ios"]])
        #expect(steps("Build and Run on iPhone 17 Pro Simulator") == [["npm", "run", "build:app"], ["npx", "cap", "run", "ios", "--target", "PRO", "--no-sync"]])
        #expect(steps("Open Android Project in Android Studio") == [["npm", "run", "android"]])
        #expect(steps("Build and Run on ccc pixel7 Emulator") == [["npm", "run", "build:app"], ["npx", "cap", "run", "android", "--target", "ccc_pixel7", "--no-sync"]])
        #expect(recipes.allSatisfy { $0.isSuggested && !$0.isApproved && $0.opensInTerminal && $0.safety == .localWrite })
    }

    @Test func withoutScriptsOrDevicesTheCapacitorCommandsAreUsed() throws {
        let root = try capacitorProject(scripts: ["build": "vite build"], android: false)
        defer { removeTemp(root) }
        var checkout = LocalCheckout()
        checkout.path = root.path
        let recipes = MobileRecipes.recipes(for: checkout, environmentID: nil, devices: nil)
        #expect(recipes.map(\.label) == ["Open iOS Project in Xcode", "Build and Run on iOS Simulator"])
        #expect(recipes[0].steps == [["npm", "run", "build"], ["npx", "cap", "sync", "ios"], ["npx", "cap", "open", "ios"]])
        #expect(recipes[1].steps == [["npm", "run", "build"], ["npx", "cap", "run", "ios"]])
    }

    @Test func aPlainXcodeProjectGetsOpenInXcode() throws {
        let root = try makeTempDir("native")
        defer { removeTemp(root) }
        try FileManager.default.createDirectory(at: root.appending(path: "My App.xcodeproj"), withIntermediateDirectories: true)
        var checkout = LocalCheckout()
        checkout.path = root.path
        let recipes = MobileRecipes.recipes(for: checkout, environmentID: nil, devices: nil)
        #expect(recipes.count == 1)
        #expect(recipes[0].steps == [["open", "-a", "Xcode", "My App.xcodeproj"]])
        #expect(recipes[0].safety == .readOnly)
        #expect(MobileRecipes.inspect(try makeTempDir("empty").path) == nil)
    }

    @Test func addingTwiceDoesNotDuplicate() throws {
        let root = try capacitorProject(scripts: [:])
        defer { removeTemp(root) }
        var product = Product(name: "App")
        var checkout = LocalCheckout()
        checkout.path = root.path
        product.checkouts = [checkout]
        let first = MobileRecipes.add(to: &product, checkout: checkout, devices: nil)
        #expect(first > 0)
        #expect(MobileRecipes.add(to: &product, checkout: checkout, devices: nil) == 0)
    }

    @Test func stepsRoundTripAndOldRecipesStillLoad() throws {
        var recipe = ActionRecipe()
        recipe.setSteps([["npm", "run", "build:app"], ["npx", "cap", "run", "ios"]])
        #expect(recipe.executable == "npm")
        #expect(recipe.steps.count == 2)
        let data = try JSONCoding.encoder().encode(recipe)
        #expect(try JSONCoding.decoder().decode(ActionRecipe.self, from: data).steps == recipe.steps)
        var old = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        old.removeValue(forKey: "extraSteps")
        let legacy = try JSONCoding.decoder().decode(ActionRecipe.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(legacy.steps == [["npm", "run", "build:app"]])
    }

    @Test func aMultiStepScriptStopsAtTheFirstFailureAndQuotesEverything() throws {
        let directory = try makeTempDir("it's steps")
        defer { removeTemp(directory) }
        let marker = directory.appending(path: "ran-third")
        let script = TerminalLauncher.script(directory: directory.path, commands: [
            ["/bin/echo", "first; $(touch pwned)"], ["/usr/bin/false"], ["/usr/bin/touch", marker.path]])
        let file = directory.appending(path: "run.command")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let result = try runTool("/bin/zsh", [file.path])
        #expect(result.code == 1)
        #expect(result.out.contains("first; $(touch pwned)"))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "pwned").path))
        let ok = TerminalLauncher.script(directory: directory.path, commands: [["/bin/echo", "a"], ["/usr/bin/touch", marker.path]])
        try ok.write(to: file, atomically: true, encoding: .utf8)
        #expect(try runTool("/bin/zsh", [file.path]).code == 0)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }
}
