import Darwin
import Foundation

// The parts of the in-app terminal that do not need AppKit: what to start, with which
// environment, and which program is in the foreground right now.

public enum TerminalSessionKind: String, Sendable, Codable {
    case shell, agent, recipe, ssh, command

    public var title: String {
        switch self {
        case .shell: "Shell"
        case .agent: "Agent"
        case .recipe: "Recipe"
        case .ssh: "SSH"
        case .command: "Command"
        }
    }
}

public struct TerminalLaunch: Sendable, Equatable {
    public var kind: TerminalSessionKind
    public var title: String
    public var executable: String
    public var arguments: [String]
    /// argv[0] as the program sees it. A leading "-" makes a shell a login shell.
    public var execName: String?
    public var directory: String
    /// KEY=VALUE pairs, as a PTY child expects them.
    public var environment: [String]
    /// Text shown in the terminal before the program starts, like what an agent was started with.
    public var banner: String? = nil

    /// Variables used only by ForgeDeck's own test and snapshot runs. A terminal does not inherit them.
    static let internalPrefixes = ["APP_", "FORGEDECK_ACCEPTANCE", "FORGEDECK_LIVE"]

    /// The environment for a terminal: the app's own, with a full PATH and terminal settings.
    public static func environment(base: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) -> [String] {
        var env = base.filter { key, _ in !internalPrefixes.contains { key.hasPrefix($0) } }
        // An app opened from Finder has a short PATH. A login shell rebuilds it; commands started
        // directly (an agent, a recipe step) need it here.
        let path = (["\(home)/.local/bin"] + ExecutableLocator.searchPaths + (env["PATH"] ?? "").split(separator: ":").map(String.init))
        var seen = Set<String>()
        env["PATH"] = path.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = Brand.name
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["HOME"] = env["HOME"] ?? home
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }

    /// The user's login shell in a folder.
    public static func shell(in directory: String, title: String, base: [String: String] = ProcessInfo.processInfo.environment) -> TerminalLaunch {
        var shell = base["SHELL"] ?? "/bin/zsh"
        if !FileManager.default.isExecutableFile(atPath: shell) { shell = "/bin/zsh" }
        return TerminalLaunch(kind: .shell, title: title, executable: shell, arguments: [], execName: "-" + (shell as NSString).lastPathComponent,
                              directory: directory, environment: environment(base: base))
    }

    /// A program with its arguments, started directly: no shell parses anything.
    public static func command(_ argv: [String], kind: TerminalSessionKind, title: String, in directory: String,
                               base: [String: String] = ProcessInfo.processInfo.environment) -> TerminalLaunch? {
        guard let program = argv.first else { return nil }
        let environment = environment(base: base)
        let path = environment.first { $0.hasPrefix("PATH=") }.map { String($0.dropFirst(5)) } ?? ""
        guard let resolved = ExecutableLocator.find(program, environment: ["PATH": path]) else { return nil }
        return TerminalLaunch(kind: kind, title: title, executable: resolved.path, arguments: Array(argv.dropFirst()), execName: nil,
                              directory: directory, environment: environment)
    }
}

public enum ProcessInspector {
    /// The program in the foreground of a terminal: what the person is running right now.
    /// nil when the shell itself is waiting for input.
    public static func foreground(ptyFD: Int32, shellPID: pid_t) -> (pid: pid_t, name: String)? {
        guard ptyFD >= 0 else { return nil }
        let group = tcgetpgrp(ptyFD)
        guard group > 0, group != shellPID, let name = name(of: group) else { return nil }
        return (group, name)
    }

    public static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let name = String(decoding: bytes, as: UTF8.self)
        return name.isEmpty ? nil : name
    }

    public static func isAlive(_ pid: pid_t) -> Bool { pid > 0 && kill(pid, 0) == 0 }

    /// Every process ID this user can see.
    public static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(max(0, Int(filled)))).filter { $0 > 0 }
    }

    /// The folder a process runs in.
    public static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// A process's arguments, the program first. nil for a process this user cannot read.
    public static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        // After argc: the executable path, padding NULs, then argc NUL-terminated arguments.
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    /// Processes running `arguments` (matched in order, anywhere in the command) in `folder`.
    public static func processes(running arguments: [String], in folder: String) -> [pid_t] {
        let folder = URL(fileURLWithPath: folder).standardizedFileURL.resolvingSymlinksInPath().path
        let me = getpid()
        return allPIDs().filter { pid in
            guard pid != me, let cwd = workingDirectory(of: pid),
                  URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath().path == folder,
                  let argv = ProcessInspector.arguments(of: pid) else { return false }
            return contains(argv, arguments)
        }
    }

    static func contains(_ argv: [String], _ wanted: [String]) -> Bool {
        guard !wanted.isEmpty else { return true }
        let names = argv.enumerated().map { $0.offset == 0 ? ($0.element as NSString).lastPathComponent : $0.element }
        return (0...max(0, names.count - wanted.count)).contains { start in
            names.count >= wanted.count && Array(names[start..<start + wanted.count]) == wanted
        }
    }
}
