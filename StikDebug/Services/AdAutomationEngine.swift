//
//  AdAutomationEngine.swift
//  StikDebug
//
//  Watches rewarded ads in another app: presses the button that starts an ad,
//  waits for a close control to appear, presses it, and repeats. Reading the
//  screen and tapping are done by a separate control app (see AdRunnerClient).
//  Every step is written to a log so a run can be reviewed afterwards.
//

import Foundation
import UIKit

struct AdAutomationConfig {
    var startKeywords: [String]
    var confirmKeywords: [String]
    var observeOnly: Bool
    var probeCorners: Bool
    var maxAdSeconds: Int
    var runMinutes: Int

    static func keywords(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// One thing on screen that could be tapped: recognised text or an
/// accessibility element. Coordinates are in screen points.
private struct AdScreenItem {
    enum Source: String {
        case text = "ocr"
        case element = "ax"
    }

    var source: Source
    var type: String
    var label: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var centerX: Double { x + width / 2 }
    var centerY: Double { y + height / 2 }

    var summary: String {
        "\(source.rawValue) \(type) '\(label)' @\(Int(centerX)),\(Int(centerY)) \(Int(width))x\(Int(height))"
    }
}

@MainActor
final class AdAutomationEngine: ObservableObject {
    static let shared = AdAutomationEngine()

    enum RunnerState: Equatable {
        case unknown
        case notRunning
        case running(version: String)
    }

    @Published private(set) var runnerState: RunnerState = .unknown
    @Published private(set) var isPaired = AdRunnerClient.shared.isPaired
    @Published private(set) var isConnecting = false
    @Published private(set) var isRunning = false
    @Published private(set) var status = ""
    @Published private(set) var adsFinished = 0
    @Published private(set) var recentLog: [String] = []
    @Published private(set) var exportURL: URL?

    private var runTask: Task<Void, Never>?
    private var sessionFolder: URL?
    private var logHandle: FileHandle?
    private var screenshotCount = 0
    /// Why the run ended by itself, shown in front of the final status.
    private var stopNote: String?

    private let client = AdRunnerClient.shared
    private static let tickInterval: TimeInterval = 2
    private static let minimumAdSeconds: TimeInterval = 5
    private static let abandonAdSeconds: TimeInterval = 240
    private static let maximumScreenshots = 240

    private static let keepWatchingLabels: Set<String> = [
        "繼續觀看", "继续观看", "繼續播放", "继续播放", "繼續看", "resume", "keep watching", "resume video",
    ]
    private static let closeGlyphs: Set<String> = ["x", "×", "✕", "✖", "╳", "ⓧ", "⊗", "⨯", "✗", "✘"]
    private static let closeWords = [
        "close", "dismiss", "skip", "關閉", "关闭", "略過", "略过", "跳過", "跳过",
    ]
    private static let ignoredApps: Set<String> = ["com.apple.springboard"]

    private init() {}

    // MARK: - Connection

    func refreshConnection() async {
        if let version = await client.runnerVersion() {
            runnerState = .running(version: version)
        } else {
            runnerState = .notRunning
        }
        isPaired = client.isPaired
    }

    func connect() async {
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        await refreshConnection()
        guard runnerState != .notRunning else {
            status = AdRunnerError.notRunning.localizedDescription
            return
        }
        status = "Waiting for you to allow the request in the control app's notification…".localized
        do {
            try await client.pair()
            isPaired = true
            status = "Connected.".localized
        } catch {
            isPaired = client.isPaired
            status = error.localizedDescription
        }
    }

    func disconnect() {
        client.forget()
        isPaired = false
        status = ""
    }

    // MARK: - Run control

    func start(_ config: AdAutomationConfig) {
        guard !isRunning else { return }
        isRunning = true
        adsFinished = 0
        recentLog = []
        exportURL = nil
        screenshotCount = 0
        stopNote = nil
        openSession()
        BackgroundAudioManager.shared.requestStart()
        BackgroundLocationManager.shared.requestStart()
        runTask = Task { [weak self] in
            await self?.run(config)
            await self?.finish()
        }
    }

    func stop() {
        runTask?.cancel()
    }

    private func finish() {
        guard isRunning else { return }
        isRunning = false
        runTask = nil
        BackgroundAudioManager.shared.requestStop()
        BackgroundLocationManager.shared.requestStop()
        log("stopped; ads finished: \(adsFinished)")
        try? logHandle?.close()
        logHandle = nil
        if let folder = sessionFolder {
            exportURL = Self.makeArchive(of: folder)
        }
        let summary = String(format: "Stopped. Ads finished: %lld".localized, adsFinished)
        if let stopNote {
            status = stopNote + " " + summary
        } else {
            status = summary
        }
    }

    // MARK: - Main loop

    private enum Phase {
        case idle
        case ad(startedAt: Date)
    }

    private func run(_ config: AdAutomationConfig) async {
        let ownBundle = Bundle.main.bundleIdentifier ?? ""
        let deadline = Date().addingTimeInterval(TimeInterval(config.runMinutes * 60))
        var game: String?
        var phase = Phase.idle
        var lastAdEnded = Date.distantPast
        var lastScreenshot = Date.distantPast
        var probeIndex = 0
        var closeTaps = 0
        var consecutiveErrors = 0
        var emptyStarts = 0

        log("start; observeOnly=\(config.observeOnly) probe=\(config.probeCorners) maxAd=\(config.maxAdSeconds)s "
            + "start=\(config.startKeywords) confirm=\(config.confirmKeywords)")
        status = "Switch to the game now.".localized

        while !Task.isCancelled && Date() < deadline {
            let tickStart = Date()
            do {
                let info = try await client.call("device_info")
                consecutiveErrors = 0
                let system = info["system"] as? [String: Any]
                let foreground = system?["foreground_app"] as? String
                let locked = (system?["screen_locked"] as? Bool) ?? false
                let screen = info["screen"] as? [String: Any]
                let width = Self.number(info["point_width"]) ?? Self.number(screen?["point_width"]) ?? 0
                let height = Self.number(info["point_height"]) ?? Self.number(screen?["point_height"]) ?? 0

                if locked {
                    status = "The screen is locked.".localized
                    log("screen locked")
                } else if let foreground, foreground == ownBundle || Self.ignoredApps.contains(foreground) {
                    if game == nil {
                        status = "Switch to the game now.".localized
                    } else {
                        status = "Paused. Go back to the game to continue.".localized
                    }
                } else if let foreground, game == nil {
                    game = foreground
                    log("game = \(foreground); screen \(Int(width))x\(Int(height)) points")
                    status = "Watching the game…".localized
                } else if let foreground, let game, foreground != game {
                    // An ad opened another app (App Store, Safari…).
                    let recentlyInAd: Bool
                    if case .ad = phase {
                        recentlyInAd = true
                    } else {
                        recentlyInAd = Date().timeIntervalSince(lastAdEnded) < 90
                    }
                    log("foreground is \(foreground), not the game")
                    if recentlyInAd && !config.observeOnly {
                        log("action: activate \(game)")
                        _ = try? await client.call("activate_app", ["bundle_id": game], timeout: 20)
                    }
                } else if game != nil {
                    // In the game: read the screen and decide.
                    var inAd = false
                    var adElapsed: TimeInterval = 0
                    if case .ad(let startedAt) = phase {
                        inAd = true
                        adElapsed = Date().timeIntervalSince(startedAt)
                    }

                    var items = await readText()
                    if inAd || config.observeOnly {
                        items += await readElements()
                    }
                    log("tick phase=\(inAd ? "ad \(Int(adElapsed))s" : "idle") items=\(items.count)")
                    for item in items.prefix(70) {
                        log("  " + item.summary)
                    }

                    if (inAd || config.observeOnly),
                       Date().timeIntervalSince(lastScreenshot) >= 6 {
                        lastScreenshot = Date()
                        await saveScreenshot(tag: inAd ? "ad" : "watch")
                    }

                    let startItem = Self.firstMatch(in: items, keywords: config.startKeywords)
                    let confirmItem = Self.firstMatch(in: items, keywords: config.confirmKeywords)

                    if config.observeOnly {
                        status = "Recording only. Nothing is tapped.".localized
                    } else if !inAd {
                        if let startItem {
                            log("action: tap start \(startItem.summary)")
                            await tap(x: startItem.centerX, y: startItem.centerY)
                            phase = .ad(startedAt: Date())
                            probeIndex = 0
                            closeTaps = 0
                            status = "Ad started. Waiting for the close button…".localized
                        } else if let confirmItem {
                            log("action: tap confirm \(confirmItem.summary)")
                            await tap(x: confirmItem.centerX, y: confirmItem.centerY)
                        } else {
                            status = config.startKeywords.isEmpty
                                ? "Enter the text of the button that starts an ad.".localized
                                : "Looking for the button that starts an ad…".localized
                        }
                    } else if let startItem {
                        // The page with the start button is showing, so no ad is on
                        // screen. Nothing else may be tapped here: the game's own
                        // close button would dismiss this page.
                        if adElapsed > 8 {
                            if closeTaps > 0 || adElapsed > 20 {
                                adsFinished += 1
                                emptyStarts = 0
                            } else {
                                emptyStarts += 1
                            }
                            log("ad over after \(Int(adElapsed))s (start button visible: \(startItem.label)); "
                                + "total \(adsFinished), empty starts \(emptyStarts)")
                            phase = .idle
                            lastAdEnded = Date()
                            status = String(format: "Ads finished: %lld".localized, adsFinished)
                            if emptyStarts >= 4 {
                                // The button no longer starts an ad: the daily limit
                                // is probably used up.
                                log("the start button did not start an ad 4 times in a row; stopping")
                                stopNote = "No more ads seem to be available.".localized
                                break
                            }
                        }
                    } else if let keepWatching = items.first(where: {
                        Self.keepWatchingLabels.contains($0.label.trimmingCharacters(in: .whitespaces).lowercased())
                    }) {
                        // Closed too early: the ad asks whether to give up the reward.
                        log("action: tap keep-watching \(keepWatching.summary)")
                        await tap(x: keepWatching.centerX, y: keepWatching.centerY)
                    } else if let confirmItem {
                        log("action: tap confirm \(confirmItem.summary)")
                        await tap(x: confirmItem.centerX, y: confirmItem.centerY)
                    } else if adElapsed >= Self.minimumAdSeconds,
                              let closeItem = Self.closeCandidate(in: items, width: width, height: height) {
                        await saveScreenshot(tag: "close")
                        log("action: tap close \(closeItem.summary)")
                        await tap(x: closeItem.centerX, y: closeItem.centerY)
                        closeTaps += 1
                    } else if config.probeCorners, adElapsed >= TimeInterval(config.maxAdSeconds),
                              width > 0, height > 0 {
                        let points = Self.cornerPoints(width: width, height: height)
                        let point = points[probeIndex % points.count]
                        probeIndex += 1
                        await saveScreenshot(tag: "probe")
                        log("action: probe corner \(Int(point.x)),\(Int(point.y))")
                        await tap(x: point.x, y: point.y)
                        closeTaps += 1
                    } else if adElapsed >= Self.abandonAdSeconds {
                        log("gave up on this ad after \(Int(adElapsed))s")
                        phase = .idle
                        lastAdEnded = Date()
                    }
                }
            } catch let error as AdRunnerError {
                log("error: \(error.localizedDescription)")
                status = error.localizedDescription
                if error == .notPaired || error == .keyRejected {
                    isPaired = client.isPaired
                    break
                }
                consecutiveErrors += 1
                if consecutiveErrors >= 15 {
                    break
                }
            } catch {
                log("error: \(error.localizedDescription)")
                consecutiveErrors += 1
                if consecutiveErrors >= 15 {
                    break
                }
            }

            let spent = Date().timeIntervalSince(tickStart)
            let remaining = Self.tickInterval - spent
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
    }

    // MARK: - Reading the screen

    private func readText() async -> [AdScreenItem] {
        do {
            // The accurate level is required: the fast one cannot read Chinese.
            let result = try await client.call("screen_text", timeout: 25)
            let rawItems = (result["items"] as? [[String: Any]]) ?? []
            return rawItems.compactMap { raw in
                guard let label = raw["label"] as? String,
                      let x = Self.number(raw["x"]), let y = Self.number(raw["y"]),
                      let width = Self.number(raw["width"]), let height = Self.number(raw["height"]) else {
                    return nil
                }
                return AdScreenItem(source: .text, type: "Text", label: label,
                                    x: x, y: y, width: width, height: height)
            }
        } catch {
            log("screen_text failed: \(error.localizedDescription)")
            return []
        }
    }

    private func readElements() async -> [AdScreenItem] {
        do {
            let result = try await client.call(
                "page_source",
                ["visible_only": true, "max_elements": 400],
                timeout: 25
            )
            guard let source = result["source"] as? String else { return [] }
            return Self.parseElements(source)
        } catch {
            log("page_source failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Parses lines like `Button, label: 'Close', {{340, 60}, {30, 30}}`.
    private static func parseElements(_ source: String) -> [AdScreenItem] {
        var items: [AdScreenItem] = []
        for rawLine in source.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let frameStart = line.range(of: "{{", options: .backwards) else { continue }
            let numbers = line[frameStart.lowerBound...]
                .split(whereSeparator: { !($0.isNumber || $0 == "-") })
                .compactMap { Double($0) }
            guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { continue }
            let type = line.split(separator: ",").first.map { String($0) } ?? ""
            guard type != "Application", type != "Window", type != "Other" || line.contains("label: '") else {
                continue
            }
            var label = ""
            if let labelStart = line.range(of: "label: '") {
                let rest = line[labelStart.upperBound...]
                if let labelEnd = rest.range(of: "'") {
                    label = String(rest[..<labelEnd.lowerBound])
                }
            }
            items.append(AdScreenItem(source: .element, type: type, label: label,
                                      x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]))
        }
        return items
    }

    // MARK: - Decisions

    private static func firstMatch(in items: [AdScreenItem], keywords: [String]) -> AdScreenItem? {
        guard !keywords.isEmpty else { return nil }
        let lowered = keywords.map { $0.lowercased() }
        return items.first { item in
            let label = item.label.lowercased()
            return !label.isEmpty && lowered.contains(where: { label.contains($0) })
        }
    }

    /// The most likely close control, or nil when none is on screen yet.
    private static func closeCandidate(in items: [AdScreenItem], width: Double, height: Double) -> AdScreenItem? {
        func isNearTopCorner(_ item: AdScreenItem) -> Bool {
            guard width > 0, height > 0 else { return false }
            let nearSide = item.centerX < width * 0.22 || item.centerX > width * 0.78
            return nearSide && item.centerY < height * 0.3
        }
        func isCloseWord(_ item: AdScreenItem) -> Bool {
            let label = item.label.trimmingCharacters(in: .whitespaces).lowercased()
            guard !label.isEmpty, label.count <= 24 else { return false }
            // "5 秒後可關閉" is a countdown, not a button.
            if label.contains(where: { $0.isNumber }) || label.contains("秒") { return false }
            return closeWords.contains(where: { label.contains($0) })
        }
        func isCloseGlyph(_ item: AdScreenItem) -> Bool {
            closeGlyphs.contains(item.label.trimmingCharacters(in: .whitespaces).lowercased())
        }

        let elements = items.filter { $0.source == .element }
        let texts = items.filter { $0.source == .text }

        // 1. An accessibility element that says it closes.
        if let labelled = elements.first(where: { isCloseWord($0) || isCloseGlyph($0) }) {
            return labelled
        }
        // 2. Recognised text: an X near a top corner, or a close word.
        if let glyph = texts.first(where: { isCloseGlyph($0) && isNearTopCorner($0) }) {
            return glyph
        }
        if let word = texts.first(where: { isCloseWord($0) }) {
            return word
        }
        // 3. A small unlabelled button or image in a top corner.
        return elements.first { item in
            (item.type == "Button" || item.type == "Image")
                && item.label.isEmpty
                && (12...64).contains(item.width) && (12...64).contains(item.height)
                && isNearTopCorner(item)
        }
    }

    private static func cornerPoints(width: Double, height: Double) -> [CGPoint] {
        // Portrait screens keep close buttons below the status bar area.
        let top: Double = height > width ? 72 : 32
        return [
            CGPoint(x: width - 32, y: top),
            CGPoint(x: 32, y: top),
            CGPoint(x: width - 32, y: top + 28),
            CGPoint(x: 32, y: top + 28),
        ]
    }

    // MARK: - Actions

    private func tap(x: Double, y: Double) async {
        do {
            _ = try await client.call("tap", ["x": x, "y": y, "settle": false, "fast": true], timeout: 20)
        } catch {
            log("tap failed: \(error.localizedDescription)")
        }
    }

    private func saveScreenshot(tag: String) async {
        guard screenshotCount < Self.maximumScreenshots, let folder = sessionFolder else { return }
        do {
            let result = try await client.call("screenshot", ["scale": 1, "quality": 0.5], timeout: 25)
            guard let base64 = result["data"] as? String, let data = Data(base64Encoded: base64) else { return }
            screenshotCount += 1
            let name = String(format: "%03d-%@.jpg", screenshotCount, tag)
            try data.write(to: folder.appendingPathComponent(name))
            log("screenshot \(name)")
        } catch {
            log("screenshot failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Log

    private func openSession() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = URL.documentsDirectory
            .appendingPathComponent("ad-runs", isDirectory: true)
            .appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let logURL = folder.appendingPathComponent("log.txt")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            logHandle = try FileHandle(forWritingTo: logURL)
            sessionFolder = folder
        } catch {
            sessionFolder = nil
            logHandle = nil
        }
    }

    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        let line = "\(formatter.string(from: Date())) \(message)"
        if let data = (line + "\n").data(using: .utf8) {
            try? logHandle?.write(contentsOf: data)
        }
        if !message.hasPrefix("  ") {
            recentLog.append(line)
            if recentLog.count > 60 {
                recentLog.removeFirst(recentLog.count - 60)
            }
        }
    }

    /// Zips the run folder so it can be shared as one file.
    private static func makeArchive(of folder: URL) -> URL? {
        var archive: URL?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading],
                                       error: &coordinationError) { zippedURL in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("ad-run-\(folder.lastPathComponent).zip")
            try? FileManager.default.removeItem(at: destination)
            if (try? FileManager.default.copyItem(at: zippedURL, to: destination)) != nil {
                archive = destination
            }
        }
        return archive
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
