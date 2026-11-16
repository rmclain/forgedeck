import Foundation

// Suggested recipes for mobile apps: Capacitor projects (iOS and Android shells around a web app)
// and plain Xcode projects. Suggestions start unapproved, like every detected recipe.

public struct MobileDevice: Sendable, Hashable, Codable {
    public var name: String
    /// A simulator UDID, or an Android emulator's AVD name.
    public var id: String
    public var runtime: String

    public init(name: String, id: String, runtime: String) {
        self.name = name
        self.id = id
        self.runtime = runtime
    }
}

public struct MobileDevices: Sendable, Equatable {
    public var iosSimulators: [MobileDevice] = []
    public var androidEmulators: [MobileDevice] = []

    public init(iosSimulators: [MobileDevice] = [], androidEmulators: [MobileDevice] = []) {
        self.iosSimulators = iosSimulators
        self.androidEmulators = androidEmulators
    }

    /// Filled once by the app at launch, so suggestions made during an import can name a device.
    nonisolated(unsafe) public static var cached: MobileDevices?

    /// The simulator a recipe uses by default: a current "Pro" iPhone, else any iPhone.
    public var preferredIPhone: MobileDevice? {
        let phones = iosSimulators.filter { $0.name.hasPrefix("iPhone") }
        return phones.first { $0.name.hasSuffix(" Pro") } ?? phones.first
    }

    /// Reads `xcrun simctl list devices available -j`. Newest runtime first.
    public static func parseSimulators(_ json: Data) -> [MobileDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let byRuntime = root["devices"] as? [String: [[String: Any]]] else { return [] }
        var devices: [MobileDevice] = []
        for (runtime, list) in byRuntime where runtime.contains("iOS") {
            // com.apple.CoreSimulator.SimRuntime.iOS-26-5 -> iOS 26.5
            let version = runtime.components(separatedBy: "iOS-").last?.replacingOccurrences(of: "-", with: ".") ?? ""
            for item in list where (item["isAvailable"] as? Bool) ?? true {
                guard let name = item["name"] as? String, let udid = item["udid"] as? String else { continue }
                devices.append(MobileDevice(name: name, id: udid, runtime: "iOS \(version)"))
            }
        }
        func number(_ runtime: String) -> [Int] { runtime.dropFirst(4).split(separator: ".").compactMap { Int($0) } }
        return devices.sorted { a, b in
            let (x, y) = (number(a.runtime), number(b.runtime))
            return x != y ? y.lexicographicallyPrecedes(x) : a.name < b.name
        }
    }

    public static func androidSDK(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        for candidate in [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"], NSHomeDirectory() + "/Library/Android/sdk"] {
            if let candidate, FileManager.default.fileExists(atPath: (candidate as NSString).appendingPathComponent("emulator/emulator")) { return candidate }
        }
        return nil
    }

    public static func detect(runner: any ProcessRunning = SystemProcessRunner()) async -> MobileDevices {
        var found = MobileDevices()
        if let xcrun = ExecutableLocator.find("xcrun"),
           let result = try? await runner.run(ProcessRequest(executable: xcrun, arguments: ["simctl", "list", "devices", "available", "-j"], timeout: 20)), result.ok {
            found.iosSimulators = parseSimulators(Data(result.stdout.utf8))
        }
        if let sdk = androidSDK() {
            let emulator = URL(fileURLWithPath: (sdk as NSString).appendingPathComponent("emulator/emulator"))
            if let result = try? await runner.run(ProcessRequest(executable: emulator, arguments: ["-list-avds"], timeout: 20)), result.ok {
                found.androidEmulators = result.stdout.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.contains(" ") && !$0.hasPrefix("INFO") }
                    .map { MobileDevice(name: $0.replacingOccurrences(of: "_", with: " "), id: $0, runtime: "Android") }
            }
        }
        return found
    }
}

public enum MobileRecipes {
    public struct Project: Sendable, Equatable {
        public var isCapacitor: Bool
        public var hasIOS: Bool
        public var hasAndroid: Bool
        /// A plain Xcode project or workspace, relative to the checkout.
        public var xcodeProject: String?
        public var scripts: Set<String>
    }

    public static func inspect(_ path: String) -> Project? {
        let fm = FileManager.default
        func exists(_ relative: String) -> Bool { fm.fileExists(atPath: (path as NSString).appendingPathComponent(relative)) }
        let capacitor = ["capacitor.config.json", "capacitor.config.ts", "capacitor.config.js"].contains(where: exists)
        var scripts = Set<String>()
        if let data = fm.contents(atPath: (path as NSString).appendingPathComponent("package.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let found = json["scripts"] as? [String: Any] {
            scripts = Set(found.keys)
        }
        // Capacitor keeps the Xcode project in ios/App. Other layouts: a project at the top or one level down.
        var project: String?
        for folder in ["", "ios", "ios/App", "macos"] {
            let base = folder.isEmpty ? path : (path as NSString).appendingPathComponent(folder)
            let entries = ((try? fm.contentsOfDirectory(atPath: base)) ?? []).sorted()
            if let workspace = entries.first(where: { $0.hasSuffix(".xcworkspace") }) ?? entries.first(where: { $0.hasSuffix(".xcodeproj") }) {
                project = folder.isEmpty ? workspace : "\(folder)/\(workspace)"
                break
            }
        }
        let hasIOS = capacitor ? exists("ios") : project != nil
        let hasAndroid = exists("android/gradlew") || exists("android/build.gradle") || exists("android/settings.gradle")
        guard capacitor || project != nil else { return nil }
        return Project(isCapacitor: capacitor, hasIOS: hasIOS, hasAndroid: hasAndroid, xcodeProject: project, scripts: scripts)
    }

    /// The recipes for one checkout. Labels are stable, so adding twice does not duplicate.
    public static func recipes(for checkout: LocalCheckout, environmentID: UUID?, devices: MobileDevices?, suffix: String = "") -> [ActionRecipe] {
        guard let project = inspect(checkout.path) else { return [] }
        func recipe(_ label: String, _ steps: [[String]], safety: ActionSafety = .localWrite, terminal: Bool = true) -> ActionRecipe {
            var recipe = ActionRecipe()
            recipe.label = label + suffix
            recipe.setSteps(steps)
            recipe.checkoutID = checkout.id
            recipe.environmentID = environmentID
            recipe.safety = safety
            recipe.isSuggested = true
            recipe.opensInTerminal = terminal
            return recipe
        }
        var out: [ActionRecipe] = []
        if project.isCapacitor {
            // The web bundle the native shells load. Prefer the project's own app build script.
            let webBuild: [[String]] = project.scripts.contains("build:app") ? [["npm", "run", "build:app"]]
                : project.scripts.contains("build") ? [["npm", "run", "build"]] : []
            // build:app in Capacitor templates usually ends with `cap sync`; cap run would sync again otherwise.
            let sync = project.scripts.contains("build:app") ? ["--no-sync"] : []
            if project.hasIOS {
                out.append(recipe("Open iOS Project in Xcode", project.scripts.contains("ios") ? [["npm", "run", "ios"]]
                                  : webBuild + [["npx", "cap", "sync", "ios"], ["npx", "cap", "open", "ios"]]))
                if let phone = devices?.preferredIPhone {
                    out.append(recipe("Build and Run on \(phone.name) Simulator", webBuild + [["npx", "cap", "run", "ios", "--target", phone.id] + sync]))
                } else {
                    // Without a known device, Capacitor asks which one in the terminal.
                    out.append(recipe("Build and Run on iOS Simulator", webBuild + [["npx", "cap", "run", "ios"] + sync]))
                }
            }
            if project.hasAndroid {
                out.append(recipe("Open Android Project in Android Studio", project.scripts.contains("android") ? [["npm", "run", "android"]]
                                  : webBuild + [["npx", "cap", "sync", "android"], ["npx", "cap", "open", "android"]]))
                if let emulator = devices?.androidEmulators.first {
                    out.append(recipe("Build and Run on \(emulator.name) Emulator", webBuild + [["npx", "cap", "run", "android", "--target", emulator.id] + sync]))
                }
            }
        } else if let xcode = project.xcodeProject {
            out.append(recipe("Open in Xcode", [["open", "-a", "Xcode", xcode]], safety: .readOnly, terminal: false))
        }
        return out
    }

    /// Adds the recipes the product does not have yet. Returns how many were added.
    @discardableResult
    public static func add(to product: inout Product, checkout: LocalCheckout, devices: MobileDevices?) -> Int {
        let suffix = product.checkouts.count > 1 ? " · \(checkout.name)" : ""
        let fresh = recipes(for: checkout, environmentID: product.environment(tier: .development)?.id, devices: devices, suffix: suffix)
            .filter { candidate in !product.recipes.contains { $0.label == candidate.label && $0.checkoutID == checkout.id } }
        product.recipes += fresh
        return fresh.count
    }
}
