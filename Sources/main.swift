import AppKit
import Foundation

// MARK: - Small helpers

func asInt(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
func asDouble(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }

let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
let isoPlain: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

// Handles both 3-digit and 6-digit fractional seconds (the usage API sends microseconds).
func parseISO(_ s: String) -> Date? {
    if let d = isoFrac.date(from: s) { return d }
    if let d = isoPlain.date(from: s) { return d }
    if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
        return isoPlain.date(from: s.replacingCharacters(in: r, with: ""))
    }
    return nil
}

func severityColor(_ pct: Double) -> NSColor {
    if pct >= 80 { return .systemRed }
    if pct >= 50 { return .systemOrange }
    return .systemGreen
}

func fmtResetTime(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(d) ? "h:mm a" : "EEE h:mm a"
    return f.string(from: d)
}

// MARK: - Claude usage (same endpoint the /usage screen uses)

struct LimitRow {
    var label: String
    var percent: Double
    var resetsAt: Date?
}

struct ClaudeUsage {
    var rows: [LimitRow] = []
    var error: String?
    var retryAfter: TimeInterval?
    var fetchedAt = Date()
}

final class ClaudeUsageFetcher {
    private func readToken() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        return token
    }

    func fetch() -> ClaudeUsage {
        guard let token = readToken() else {
            return ClaudeUsage(error: "No Claude Code login found")
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 15

        let sem = DispatchSemaphore(value: 0)
        var result = ClaudeUsage(error: "Network error")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            guard let http = resp as? HTTPURLResponse else { return }
            if http.statusCode == 401 {
                result = ClaudeUsage(error: "Login expired — use Claude Code to refresh")
                return
            }
            if http.statusCode == 429 {
                let ra = (http.value(forHTTPHeaderField: "retry-after")).flatMap(Double.init)
                result = ClaudeUsage(error: "Rate limited", retryAfter: ra)
                return
            }
            guard http.statusCode == 200, let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let limits = obj["limits"] as? [[String: Any]] else {
                result = ClaudeUsage(error: "Usage fetch failed (HTTP \(http.statusCode))")
                return
            }
            var rows: [LimitRow] = []
            for l in limits {
                let kind = (l["kind"] as? String) ?? "?"
                let label: String
                switch kind {
                case "session":
                    label = "Current session"
                case "weekly_all":
                    label = "Current week (all models)"
                case "weekly_scoped":
                    var name = "scoped"
                    if let scope = l["scope"] as? [String: Any],
                       let model = scope["model"] as? [String: Any],
                       let dn = model["display_name"] as? String { name = dn }
                    label = "Current week (\(name))"
                default:
                    label = kind
                }
                rows.append(LimitRow(
                    label: label,
                    percent: asDouble(l["percent"]),
                    resetsAt: (l["resets_at"] as? String).flatMap(parseISO)))
            }
            result = ClaudeUsage(rows: rows, error: nil)
        }.resume()
        sem.wait()
        return result
    }
}

// MARK: - Codex limits (from session logs)

struct CodexWindow {
    var usedPercent: Double
    var resetsAt: Date?

    var hasReset: Bool {
        if let r = resetsAt { return r < Date() }
        return false
    }
    var effectivePercent: Double { hasReset ? 0 : usedPercent }
}

struct CodexLimits {
    var primary: CodexWindow?
    var secondary: CodexWindow?
    var asOf: Date
}

final class CodexScanner {
    private struct FileData {
        let size: Int64
        let mtime: Date
        let limits: CodexLimits?
    }

    private var cache: [String: FileData] = [:]
    let root = NSString(string: "~/.codex/sessions").expandingTildeInPath

    func latestLimits(daysBack: Int = 14) -> CodexLimits? {
        var latest: CodexLimits?
        let fm = FileManager.default
        let cal = Calendar.current
        for i in 0..<daysBack {
            guard let d = cal.date(byAdding: .day, value: -i, to: Date()) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: d)
            let dir = String(format: "%@/%04d/%02d/%02d", root, c.year!, c.month!, c.day!)
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for f in files where f.hasSuffix(".jsonl") {
                let path = dir + "/" + f
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date,
                      let size = attrs[.size] as? Int64 else { continue }
                let data: FileData
                if let c = cache[path], c.size == size, c.mtime == mtime {
                    data = c
                } else {
                    data = parseFile(path: path, size: size, mtime: mtime)
                    cache[path] = data
                }
                if let l = data.limits {
                    if latest == nil || l.asOf > latest!.asOf { latest = l }
                }
            }
        }
        return latest
    }

    private func parseFile(path: String, size: Int64, mtime: Date) -> FileData {
        var limits: CodexLimits?
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return FileData(size: size, mtime: mtime, limits: nil)
        }
        for line in content.split(separator: "\n") {
            guard line.contains("\"rate_limits\"") else { continue }
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let rl = payload["rate_limits"] as? [String: Any] else { continue }
            let ts = (obj["timestamp"] as? String).flatMap(parseISO) ?? mtime
            func window(_ v: Any?) -> CodexWindow? {
                guard let w = v as? [String: Any], w["used_percent"] != nil else { return nil }
                var resets: Date?
                let epoch = asDouble(w["resets_at"])
                if epoch > 0 { resets = Date(timeIntervalSince1970: epoch) }
                return CodexWindow(usedPercent: asDouble(w["used_percent"]), resetsAt: resets)
            }
            limits = CodexLimits(
                primary: window(rl["primary"]),
                secondary: window(rl["secondary"]),
                asOf: ts)
        }
        return FileData(size: size, mtime: mtime, limits: limits)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let claude = ClaudeUsageFetcher()
    let codex = CodexScanner()
    var claudeUsage = ClaudeUsage()          // last successful fetch (kept on errors)
    var claudeErrorNote: String?             // shown only when there's no good data yet
    var codexLimits: CodexLimits?
    let scanQueue = DispatchQueue(label: "usage.scan", qos: .utility)
    var timer: Timer?

    // Fetch throttling: minimum gap between requests, plus server-directed backoff on 429.
    var lastClaudeAttempt = Date.distantPast
    var claudeCooldownUntil = Date.distantPast
    let minFetchGap: TimeInterval = 60
    let defaultBackoff: TimeInterval = 300

    let launchAgentPath = NSString(
        string: "~/Library/LaunchAgents/com.usagetracker.claude-codex.plist").expandingTildeInPath

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        statusItem.button?.title = "✳ …"
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    @objc func refresh() { refresh(force: false) }

    @objc func forceRefresh() { refresh(force: true) }

    func refresh(force: Bool) {
        let now = Date()
        let fetchClaude = now >= claudeCooldownUntil
            && (force || now.timeIntervalSince(lastClaudeAttempt) >= minFetchGap)
        if fetchClaude { lastClaudeAttempt = now }

        scanQueue.async { [weak self] in
            guard let self else { return }
            let cu = fetchClaude ? self.claude.fetch() : nil
            let cl = self.codex.latestLimits()
            DispatchQueue.main.async {
                if let cu {
                    if cu.error == nil {
                        self.claudeUsage = cu
                        self.claudeErrorNote = nil
                        self.claudeCooldownUntil = .distantPast
                    } else {
                        // Keep the last good data; back off if rate limited.
                        if cu.error == "Rate limited" {
                            let wait = cu.retryAfter ?? self.defaultBackoff
                            self.claudeCooldownUntil = Date().addingTimeInterval(max(wait, 60))
                        }
                        self.claudeErrorNote = cu.error
                    }
                }
                self.codexLimits = cl
                self.render()
            }
        }
    }

    func render() {
        let titleFont = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize(for: .small), weight: .regular)
        let title = NSMutableAttributedString()
        func tAppend(_ s: String, _ color: NSColor? = nil) {
            var attrs: [NSAttributedString.Key: Any] = [.font: titleFont]
            if let color { attrs[.foregroundColor] = color }
            title.append(NSAttributedString(string: s, attributes: attrs))
        }
        if let session = claudeUsage.rows.first(where: { $0.label == "Current session" }) {
            tAppend("✳ ")
            tAppend("\(Int(session.percent.rounded()))%", severityColor(session.percent))
        } else {
            tAppend("✳ –")
        }
        if let p = codexLimits?.primary {
            tAppend("  ⌁ ")
            tAppend("\(Int(p.effectivePercent.rounded()))%", severityColor(p.effectivePercent))
        }
        statusItem.button?.attributedTitle = title

        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        func header(_ t: String) {
            let item = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.attributedTitle = NSAttributedString(
                string: t,
                attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)])
            menu.addItem(item)
        }
        func info(_ t: String) {
            let item = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.indentationLevel = 1
            menu.addItem(item)
        }
        // Renders a row where only the number segment is colored.
        func infoColoredNumber(_ prefix: String, _ number: String, _ color: NSColor, _ suffix: String) {
            let item = NSMenuItem(title: prefix + number + suffix, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.indentationLevel = 1
            let font = NSFont.menuFont(ofSize: 0)
            let plain: [NSAttributedString.Key: Any] =
                [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
            let a = NSMutableAttributedString()
            a.append(NSAttributedString(string: prefix, attributes: plain))
            a.append(NSAttributedString(string: number, attributes: [.font: font, .foregroundColor: color]))
            a.append(NSAttributedString(string: suffix, attributes: plain))
            item.attributedTitle = a
            menu.addItem(item)
        }

        header("Claude Code")
        if claudeUsage.rows.isEmpty {
            info(claudeErrorNote ?? "Loading…")
        } else {
            for row in claudeUsage.rows {
                let num = "\(Int(row.percent.rounded()))%"
                var suffix = " used"
                if let r = row.resetsAt { suffix += " · resets \(fmtResetTime(r))" }
                if row.label == "Current session" {
                    infoColoredNumber("\(row.label): ", num, severityColor(row.percent), suffix)
                } else {
                    info("\(row.label): \(num)\(suffix)")
                }
            }
            let age = Date().timeIntervalSince(claudeUsage.fetchedAt)
            if age > 300 {
                info("updated \(Int(age / 60))m ago")
            }
        }

        menu.addItem(.separator())

        header("Codex")
        if let limits = codexLimits {
            if let p = limits.primary {
                let num = "\(Int(p.effectivePercent.rounded()))%"
                var suffix = " used"
                if !p.hasReset, let r = p.resetsAt {
                    suffix += " · resets \(fmtResetTime(r))"
                }
                infoColoredNumber("Current session (5h): ", num, severityColor(p.effectivePercent), suffix)
            }
            if let s = limits.secondary {
                var line = "Current week: \(Int(s.effectivePercent.rounded()))% used"
                if s.hasReset {
                    line = "Current week: 0% used"
                } else if let r = s.resetsAt {
                    line += " · resets \(fmtResetTime(r))"
                }
                info(line)
            }
        } else {
            info("No recent Codex sessions")
        }

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(forceRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let loginItem = NSMenuItem(
            title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = FileManager.default.fileExists(atPath: launchAgentPath) ? .on : .off
        menu.addItem(loginItem)

        let quitItem = NSMenuItem(
            title: "Quit Usage Tracker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    @objc func toggleLaunchAtLogin() {
        let fm = FileManager.default
        if fm.fileExists(atPath: launchAgentPath) {
            try? fm.removeItem(atPath: launchAgentPath)
        } else {
            let appPath = Bundle.main.bundlePath
            let plist: [String: Any] = [
                "Label": "com.usagetracker.claude-codex",
                "ProgramArguments": ["/usr/bin/open", appPath],
                "RunAtLoad": true,
            ]
            let dir = (launchAgentPath as NSString).deletingLastPathComponent
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0) {
                fm.createFile(atPath: launchAgentPath, contents: data)
            }
        }
        render()
    }
}

// MARK: - CLI dump mode (for testing: UsageTracker --dump)

if CommandLine.arguments.contains("--dump") {
    let cu = ClaudeUsageFetcher().fetch()
    if let err = cu.error {
        print("Claude: \(err)")
    } else {
        for row in cu.rows {
            print("Claude \(row.label): \(Int(row.percent.rounded()))% used"
                + (row.resetsAt.map { " · resets \($0)" } ?? ""))
        }
    }
    if let l = CodexScanner().latestLimits() {
        if let p = l.primary {
            print("Codex session (5h): \(Int(p.effectivePercent.rounded()))% used"
                + (p.hasReset ? " (window reset)" : p.resetsAt.map { " · resets \($0)" } ?? ""))
        }
        if let s = l.secondary {
            print("Codex week: \(Int(s.effectivePercent.rounded()))% used"
                + (s.hasReset ? " (window reset)" : s.resetsAt.map { " · resets \($0)" } ?? ""))
        }
        print("Codex data as of \(l.asOf)")
    } else {
        print("Codex: no recent sessions")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
