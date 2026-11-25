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
    /// Name of the game as the App Store shows it. When set, the control app
    /// opens the game itself, which is also how it learns which app it is.
    var gameName: String = ""
    var startKeywords: [String]
    var confirmKeywords: [String]
    var observeOnly: Bool
    var probeCorners: Bool
    var maxAdSeconds: Int
    var runMinutes: Int
    /// Press the report sheet's own button when nothing else closes it. Off
    /// unless the player turns it on: it sends a report about the ad.
    var submitReportSheet: Bool = false
    /// Close the game and open it again when an ad offers nothing to tap.
    var restartGame: Bool = true

    static func keywords(from text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// The ad network showing the ad, told from what its player exposes. Each
/// one keeps its close control in a different place.
private enum AdNetwork: String {
    case unknown
    case appLovin
    case pangle
    case mintegral
    case liftoff
}

/// A small light mark found in the picture near a top corner. Position and
/// size are in the points the player sees.
private struct AdIcon {
    var isCross: Bool
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

/// Connected light pixels while the picture is searched, in pixels of the
/// searched region.
private struct AdGlyph {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int
    var points: [Int]
    var parts: Int

    mutating func absorb(_ other: AdGlyph) {
        minX = min(minX, other.minX)
        minY = min(minY, other.minY)
        maxX = max(maxX, other.maxX)
        maxY = max(maxY, other.maxY)
        points += other.points
        parts += other.parts
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

/// Where things are on screen. A landscape game on a phone is reported in two
/// spaces: recognised text and taps use the device's portrait points, while
/// accessibility elements use the points of the picture as the player sees it.
/// Everything is decided in the second space ("content") and converted back
/// to the first only for tapping.
private struct AdScreenGeometry {
    var deviceWidth: Double = 0
    var deviceHeight: Double = 0
    /// The picture is turned a quarter relative to the device's portrait points.
    var rotated = false
    /// Turned the other way round (the phone held with the other side up).
    var flipped = false

    var width: Double { rotated ? deviceHeight : deviceWidth }
    var height: Double { rotated ? deviceWidth : deviceHeight }

    /// Recognised text, moved into the content space.
    func toContent(_ item: AdScreenItem) -> AdScreenItem {
        guard rotated else { return item }
        var moved = item
        moved.width = item.height
        moved.height = item.width
        if flipped {
            moved.x = deviceHeight - (item.y + item.height)
            moved.y = item.x
        } else {
            moved.x = item.y
            moved.y = deviceWidth - (item.x + item.width)
        }
        return moved
    }

    /// A content point, as the point to tap.
    func toDevice(x: Double, y: Double) -> CGPoint {
        guard rotated else { return CGPoint(x: x, y: y) }
        if flipped {
            return CGPoint(x: y, y: deviceHeight - x)
        }
        return CGPoint(x: deviceWidth - y, y: x)
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
    private var lastNotes: [String: String] = [:]
    private var geometry = AdScreenGeometry()
    /// Which way round the picture is turned has been worked out once.
    private var flipKnown = false
    private var lastTapAt = Date()
    /// The run as text for the clipboard: every main line, and what was on
    /// screen only for the ticks that led to an action.
    private var transcript: [String] = []
    private var pendingDetails: [String] = []
    private var previousTranscript: [String] = []
    private var runStartedAt = Date()
    /// Calls to the control app that failed since the screen was last read.
    private var failedCalls = 0

    private let client = AdRunnerClient.shared
    private static let tickInterval: TimeInterval = 2
    private static let minimumAdSeconds: TimeInterval = 5
    private static let abandonAdSeconds: TimeInterval = 240
    private static let maximumGameRestarts = 6
    private static let maximumScreenshots = 240
    /// A run never sends more reports than this.
    private static let maximumReportSubmits = 5
    private static let reportSubmitLabels: Set<String> = ["submit", "提交", "送出"]

    private static let keepWatchingLabels: Set<String> = [
        "繼續觀看", "继续观看", "繼續播放", "继续播放", "繼續看", "resume", "keep watching", "resume video",
        "continue watching", "continue", "keep playing", "繼續觀看影片", "繼續",
    ]
    private static let closeGlyphs: Set<String> = ["x", "×", "✕", "✖", "╳", "ⓧ", "⊗", "⨯", "✗", "✘"]
    /// A "next" arrow. At the top right of an ad it skips or closes it.
    private static let nextGlyphs: Set<String> = [">", "›", "»", ">>", "＞", "〉", "》"]
    private static let closeWords = [
        "close", "dismiss", "skip", "關閉", "关闭", "略過", "略过", "跳過", "跳过",
    ]
    private static let ignoredApps: Set<String> = ["com.apple.springboard"]
    /// Titles of the sheet an ad's "report" control opens.
    private static let reportSheetTitles = [
        "report ad", "report this ad", "ad feedback", "檢舉廣告", "舉報廣告", "举报广告", "回報廣告",
    ]
    /// A button such a sheet has next to its title.
    private static let reportSheetButtons = ["submit", "cancel", "提交", "送出", "取消"]
    /// Small marks that open information or report pages, never a close button.
    private static let infoGlyphs: Set<String> = ["!", "！", "i", "ⓘ", "ℹ", "?", "？", "ad", "ads", "廣告", "广告"]
    private static let countdownWords = ["秒", "sec", "剩", "remaining", "reward in"]
    /// The control of a playable ad that shows the store page; on those ads the
    /// close button only appears after that page was opened and closed.
    /// Words of the App Store's page for one app.
    private static let storePageWords = ["則評分", "年齡分級", "排行榜", "開發者"]
    private static let openStoreWords = ["open store", "打開商店", "開啟商店", "前往商店", "skip to store"]
    /// The button that closes the store page. Whole label only.
    private static let storeDoneLabels: Set<String> = ["完成", "done"]
    /// A clock such as "18小時56分58秒" belongs to the game, not to an ad.
    private static let clockMarks = ["時", "时", "分", "天", "hour", "min", "day", ":", "："]
    /// Titles of the window a game shows when it hands out the reward.
    private static let rewardTitles = [
        "恭喜獲得", "恭喜获得", "獲得獎勵", "获得奖励", "恭喜", "congratulations", "you got", "reward received",
    ]
    /// Buttons that collect a reward. These must match the whole label.
    private static let claimLabels: Set<String> = ["領取", "领取", "領取獎勵", "领取奖励", "收下", "claim", "collect"]
    /// Buttons that only count next to a reward title.
    private static let acknowledgeLabels: Set<String> = ["確定", "确定", "確認", "确认", "ok", "好", "好的", "知道了"]

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
        runStartedAt = Date()
        failedCalls = 0
        screenshotCount = 0
        stopNote = nil
        lastNotes = [:]
        geometry = AdScreenGeometry()
        flipKnown = false
        lastTapAt = Date()
        // A real run is kept when a short one follows, so stopping and
        // starting again does not throw away the log worth reading.
        if transcript.count + pendingDetails.count > 12 {
            previousTranscript = Array((transcript + pendingDetails).suffix(700))
        }
        transcript = []
        pendingDetails = []
        openSession()
        BackgroundAudioManager.shared.requestStart()
        BackgroundLocationManager.shared.requestStart()
        runTask = Task { [weak self] in
            await self?.run(config)
            await self?.finish()
        }
    }

    func stop() {
        if isRunning {
            log("stop pressed")
        }
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
        if let folder = sessionFolder,
           exportURL == nil || Date().timeIntervalSince(runStartedAt) >= 20 {
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
        // A run goes on until it is stopped, unless a limit was asked for.
        let deadline = config.runMinutes > 0
            ? Date().addingTimeInterval(TimeInterval(config.runMinutes * 60))
            : Date.distantFuture
        var game: String?
        var phase = Phase.idle
        var lastAdEnded = Date.distantPast
        var lastScreenshot = Date.distantPast
        var probeIndex = 0
        var closeTaps = 0
        var consecutiveErrors = 0
        var emptyStarts = 0
        var sawGame = false
        var lastTick = Date()
        var lastCloseTap: CGPoint?
        var badSpots: [CGPoint] = []
        var dismissTaps = 0
        // Controls that were already there while the countdown ran: a close
        // button only appears afterwards, so these are something else.
        var earlySpots: [CGPoint] = []
        var sawCountdown = false
        var countdownGoneSince: Date?
        var lastCountdownLabel = ""
        var lastCountdownValue: Int?
        var lastCountdownProgress = Date.distantPast
        var countdownFirstSeen: Date?
        var openStoreTaps = 0
        var lastOpenStoreTap = Date.distantPast
        var storeClosedAt: Date?
        // Set once the ad shows the marks of a network whose top-left
        // control reports the ad.
        var cautiousLeft = false
        // The last control tapped as a close button, and when.
        var lastCandidateTap: CGPoint?
        var lastCandidateTapAt = Date.distantPast
        var reportSubmits = 0
        var lastReportSubmit = Date.distantPast
        // Where the countdown was last read, and when it should reach zero.
        var countdownSpot: CGPoint?
        var countdownEnds = Date.distantPast
        // Tried spots that brought up the store page instead of closing the ad.
        var storeSpots: [CGPoint] = []
        var lastProbe: CGPoint?
        var lastProbeAt = Date.distantPast
        var network = AdNetwork.unknown
        // What the last look at the picture found.
        var crossSpots: [CGPoint] = []
        var markSpots: [CGPoint] = []
        var marksSeenAt = Date.distantPast
        var countdownSpotTapAt = Date.distantPast
        var lastIconScan = Date.distantPast
        var crossTaps: [CGPoint] = []
        var probeTaps: [CGPoint] = []
        // A blind tap that brought up the store page says nothing about a
        // cross that shows up in the same place later, so the two are kept apart.
        var crossStoreSpots: [CGPoint] = []
        var lastProbeWasCross = false
        // How long the ad says it lasts, when it says so.
        var statedLength = 0.0
        // AppLovin's skip mark sits at the top left and hides itself a few
        // seconds after the last touch. It comes back when the ad is touched
        // or the store page it opened is closed.
        var skipTaps = 0
        var lastSkipTap = Date.distantPast
        var mirrorPending = false
        var mirrorTaps = 0
        var nudges = 0
        var lastNudge = Date.distantPast
        // The control app can go on answering while it no longer sees any of
        // the screen's elements.
        var emptyReads = 0
        var blindRepairs = 0
        var lastBlindRepair = Date.distantPast
        // A store page that is only known from its text.
        var storeGuesses = 0
        var lastStoreGuess = Date.distantPast
        var markTaps = 0
        // Outside an ad the elements are only read now and then, to notice
        // an ad that is on screen although this run did not start it.
        var lastIdleLook = Date.distantPast
        var adoptions = 0
        var gameRestarts = 0
        var lastGameRestart = Date.distantPast
        // The control app can stop answering in the middle of a run.
        var stalls = 0
        var recoveries = 0
        var lastRecovery = Date.distantPast

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        log("start; version=\(appVersion) observeOnly=\(config.observeOnly) probe=\(config.probeCorners) "
            + "maxAd=\(config.maxAdSeconds)s "
            + "game='\(config.gameName)' start=\(config.startKeywords) confirm=\(config.confirmKeywords) "
            + "submitReport=\(config.submitReportSheet) restartGame=\(config.restartGame)")
        status = "Switch to the game now.".localized

        if !config.gameName.isEmpty {
            game = await openGame(named: config.gameName)
            if game == nil {
                status = "Could not open the game. Switch to it yourself.".localized
            }
        }

        while !Task.isCancelled && Date() < deadline {
            let tickStart = Date()
            let gap = tickStart.timeIntervalSince(lastTick)
            if gap > 12 {
                // Ticks are two seconds apart unless a call is slow or iOS
                // suspended this app in the background.
                log("no tick for \(Int(gap))s")
            }
            lastTick = tickStart
            if failedCalls > 0 || consecutiveErrors >= 2,
               recoveries < 5, Date().timeIntervalSince(lastRecovery) >= 30 {
                recoveries += 1
                lastRecovery = Date()
                await recoverRunner(game: game)
            }
            do {
                let info = try await client.call("device_info")
                consecutiveErrors = 0
                let system = info["system"] as? [String: Any]
                // The control app cannot always name the app in front: on recent
                // iOS it only knows apps it opened itself. So "which app" is
                // optional here, and whether this app is in front is asked of
                // this app, not of the control app.
                let foreground = system?["foreground_app"] as? String
                let locked = (system?["screen_locked"] as? Bool) ?? false
                let screen = info["screen"] as? [String: Any]
                let deviceWidth = Self.number(info["point_width"]) ?? Self.number(screen?["point_width"]) ?? 0
                let deviceHeight = Self.number(info["point_height"]) ?? Self.number(screen?["point_height"]) ?? 0
                let ownAppInFront = UIApplication.shared.applicationState == .active || foreground == ownBundle
                let size = "\(Int(deviceWidth))x\(Int(deviceHeight))"

                if locked {
                    status = "The screen is locked.".localized
                    note("state: screen locked")
                } else if ownAppInFront {
                    note("state: this app is in front")
                    if sawGame {
                        status = "Paused. Go back to the game to continue.".localized
                    } else if game == nil {
                        status = "Switch to the game now.".localized
                    }
                } else if let foreground, Self.ignoredApps.contains(foreground) {
                    note("state: home screen (\(foreground))")
                    status = sawGame
                        ? "Paused. Go back to the game to continue.".localized
                        : "Switch to the game now.".localized
                } else if let foreground, let game, foreground != game {
                    // An ad opened another app (App Store, Safari…).
                    let recentlyInAd: Bool
                    if case .ad = phase {
                        recentlyInAd = true
                    } else {
                        recentlyInAd = Date().timeIntervalSince(lastAdEnded) < 90
                    }
                    note("state: \(foreground) is in front, not the game")
                    if (recentlyInAd || !sawGame) && !config.observeOnly {
                        log("action: activate \(game)")
                        _ = try? await client.call("activate_app", ["bundle_id": game], timeout: 20)
                    }
                } else if let foreground, game == nil, sawGame {
                    // The game itself could not be named, so a named app in
                    // front now is a different one, and there is no identifier
                    // to switch back with.
                    note("state: \(foreground) is in front; the game's identifier is unknown, cannot switch back")
                    status = "Another app is in front. Go back to the game.".localized
                } else {
                    // In the game: read the screen and decide.
                    if game == nil, let foreground {
                        game = foreground
                    }
                    sawGame = true
                    note("state: in the game (\(foreground ?? "unnamed app")); screen \(size) points")
                    var inAd = false
                    var adElapsed: TimeInterval = 0
                    if case .ad(let startedAt) = phase {
                        inAd = true
                        adElapsed = Date().timeIntervalSince(startedAt)
                    }

                    let texts = await readText()
                    if failedCalls > 0 {
                        // The screen could not be read. Nothing is decided on
                        // nothing; the top of the loop tries to recover.
                        stalls += 1
                        if stalls >= 2 {
                            status = "The control app is not responding. Open the iCTRL runner again.".localized
                        }
                        if stalls >= 6 {
                            log("the screen could not be read 6 times in a row; stopping")
                            stopNote = "The control app is not responding. Open the iCTRL runner again.".localized
                            break
                        }
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        continue
                    }
                    stalls = 0
                    var elements: [AdScreenItem] = []
                    let startInSight = Self.firstMatch(in: texts, keywords: config.startKeywords) != nil
                    if inAd || config.observeOnly {
                        elements = await readElements()
                    } else if !startInSight, Date().timeIntervalSince(lastIdleLook) >= 6 {
                        lastIdleLook = Date()
                        elements = await readElements()
                    }
                    if inAd {
                        // Even the game's own page reports one element. None at
                        // all means the control app lost sight of the screen.
                        emptyReads = (elements.isEmpty && failedCalls == 0) ? emptyReads + 1 : 0
                        if emptyReads >= 2, blindRepairs < 3, Date().timeIntervalSince(lastBlindRepair) >= 20 {
                            blindRepairs += 1
                            lastBlindRepair = Date()
                            log("the screen's elements cannot be read; asking the control app to look again")
                            if let result = try? await client.call("logs", ["max_elements": 8], timeout: 8),
                               let lines = result["lines"] as? [String] {
                                for line in lines.suffix(8) {
                                    log("control app log: " + String(line.prefix(170)))
                                }
                            }
                            _ = try? await client.call("reset", [:], timeout: 8)
                            if let game {
                                _ = try? await client.call("activate_app", ["bundle_id": game], timeout: 20)
                            }
                            elements = await readElements()
                            if !elements.isEmpty {
                                emptyReads = 0
                                log("the elements can be read again")
                            }
                        }
                    }

                    // Work out how the picture is turned, then put everything
                    // into the space the player sees.
                    geometry.deviceWidth = deviceWidth
                    geometry.deviceHeight = deviceHeight
                    if deviceWidth > 0, deviceHeight > 0 {
                        if let turned = Self.turnFromElements(elements, deviceWidth: deviceWidth) {
                            geometry.rotated = turned
                        } else if !inAd || !geometry.rotated, let turned = Self.looksRotated(texts) {
                            // During an ad the shapes of its text say little: a
                            // video gives a few garbled words of any shape. They
                            // may not turn the picture back upright.
                            geometry.rotated = turned
                        }
                    }
                    if geometry.rotated,
                       let vote = Self.flipVote(texts: texts, elements: elements, geometry: geometry,
                                                settled: flipKnown) {
                        geometry.flipped = vote
                        flipKnown = true
                    }
                    note("screen: content \(Int(geometry.width))x\(Int(geometry.height)) "
                         + "rotated=\(geometry.rotated) flipped=\(geometry.flipped)", kind: "geometry")
                    let width = geometry.width
                    let height = geometry.height
                    let items = texts.map { geometry.toContent($0) } + elements
                    let startItem = Self.firstMatch(in: items, keywords: config.startKeywords)
                    let loweredStart = config.startKeywords.map { $0.lowercased() }
                    // The whole label has to match, or a word such as "領取"
                    // also catches "全部領取" on some other page of the game.
                    let loweredConfirm = Set(config.confirmKeywords.map { $0.lowercased() })
                    let confirmItem = items.first { item in
                        let label = item.label.trimmingCharacters(in: .whitespaces).lowercased()
                        return loweredConfirm.contains(label)
                            && !loweredStart.contains(where: { label.contains($0) })
                    }

                    // Countdown bookkeeping for the ad on screen. The game's own
                    // page (start button showing) has timers too; those do not count.
                    var countdownLive = false
                    if inAd, startItem == nil {
                        if let running = Self.countdown(in: items, width: width, height: height) {
                            let label = running.label.trimmingCharacters(in: .whitespaces)
                            let value = Int(String(label.filter { $0.isASCII && $0.isNumber }.prefix(4)))
                            if countdownFirstSeen == nil {
                                countdownFirstSeen = Date()
                            }
                            if label != lastCountdownLabel {
                                // Only a number going down is a countdown. A
                                // score in a playable ad goes up or stays.
                                if let value, let previous = lastCountdownValue, value < previous {
                                    lastCountdownProgress = Date()
                                    sawCountdown = true
                                    if previous - value <= 10 {
                                        // A plausible step: trust the number for
                                        // when the countdown ends and where it is.
                                        countdownEnds = Date().addingTimeInterval(TimeInterval(value))
                                        countdownSpot = CGPoint(x: running.centerX, y: running.centerY)
                                    }
                                }
                                lastCountdownLabel = label
                                if let value {
                                    lastCountdownValue = value
                                }
                            }
                            countdownGoneSince = nil
                            // A few seconds to see which way the number moves,
                            // then it has to keep going down.
                            let sinceFirst = Date().timeIntervalSince(countdownFirstSeen ?? Date())
                            countdownLive = sinceFirst < 8 || Date().timeIntervalSince(lastCountdownProgress) < 20
                        } else if sawCountdown {
                            if Date() < countdownEnds {
                                // The number was not read this time, but it has
                                // not run out yet.
                                countdownLive = true
                            } else if countdownGoneSince == nil {
                                countdownGoneSince = Date()
                            }
                        }
                        // Some players state the ad's length ("59秒") without
                        // a number that text recognition can follow. Until that
                        // time is up there is no close button, and a tap on the
                        // ad only brings up the store page.
                        for element in elements {
                            let label = element.label.trimmingCharacters(in: .whitespaces)
                            if label.hasSuffix("秒"), let seconds = Double(label.dropLast()),
                               seconds >= 5, seconds <= 180, seconds > statedLength {
                                statedLength = seconds
                                log("the ad says it lasts \(Int(seconds)) seconds")
                            }
                        }
                        if statedLength > 0, adElapsed < statedLength + 3 {
                            countdownLive = true
                        }
                        if countdownLive || adElapsed < Self.minimumAdSeconds {
                            for control in Self.cornerControls(in: items, width: width, height: height) {
                                let spot = CGPoint(x: control.centerX, y: control.centerY)
                                if !Self.isNear(spot, any: earlySpots) {
                                    earlySpots.append(spot)
                                    log("control at \(Int(spot.x)),\(Int(spot.y)) is there before the ad can be closed; "
                                        + "it is not a close button")
                                }
                            }
                        }
                    }
                    let countdownGone = countdownGoneSince.map { Date().timeIntervalSince($0) >= 3 } ?? false
                    // The close button takes a moment to show once the countdown
                    // is over. A guessed tap before that lands on the ad and
                    // brings up the store page.
                    let blindHold = countdownGoneSince.map { Date().timeIntervalSince($0) < 5 } ?? false
                    // Small unlabelled controls at the top left. On the ads seen
                    // so far that is the report mark, and it moves when the ad
                    // changes its frame, so it is looked up again every time.
                    let leftControls = Self.cornerControls(in: items, width: width, height: height)
                        .filter { $0.centerX < width / 2 }
                        .map { CGPoint(x: $0.centerX, y: $0.centerY) }
                    if inAd, items.contains(where: { Self.isReportNetworkMark($0.label) }) {
                        cautiousLeft = true
                    }
                    // Look at the picture for a close mark that neither
                    // accessibility nor text recognition reports. Only while an
                    // ad's own view is on screen: the game has crosses too.
                    let adOnScreen = elements.contains(where: { $0.type == "WebView" })
                        || Self.adNetwork(in: items) != .unknown
                    let adFrame: CGRect? = elements.first(where: { $0.type == "WebView" }).map {
                        CGRect(x: $0.centerX - $0.width / 2, y: $0.centerY - $0.height / 2,
                               width: $0.width, height: $0.height)
                    }
                    if !adOnScreen {
                        crossSpots = []
                        markSpots = []
                    } else if inAd, !config.observeOnly, config.probeCorners, startItem == nil, !countdownLive,
                              adElapsed >= 10, Date().timeIntervalSince(lastIconScan) >= 5,
                              !items.contains(where: { $0.type == "NavigationBar" }) {
                        lastIconScan = Date()
                        let icons = await findIcons()
                        crossSpots = icons.filter { $0.isCross }.map { CGPoint(x: $0.x, y: $0.y) }
                        // Of the other marks only the one nearest each side edge
                        // is worth a try; the rest is the ad's own picture.
                        let plain = icons.filter {
                            !$0.isCross && max($0.width, $0.height) >= 8 && min($0.width, $0.height) >= 5
                        }
                        let frameMinX = Double(adFrame?.minX ?? 0)
                        let frameMaxX = Double(adFrame?.maxX ?? CGFloat(width))
                        var marks: [CGPoint] = []
                        if let right = plain.filter({ $0.x > width / 2 }).max(by: { $0.x < $1.x }),
                           frameMaxX - right.x <= 60 {
                            marks.append(CGPoint(x: right.x, y: right.y))
                        }
                        if let left = plain.filter({ $0.x <= width / 2 }).min(by: { $0.x < $1.x }),
                           left.x - frameMinX <= 60 {
                            marks.append(CGPoint(x: left.x, y: left.y))
                        }
                        if !marks.isEmpty {
                            markSpots = marks
                            marksSeenAt = Date()
                        } else if Date().timeIntervalSince(marksSeenAt) >= 12 {
                            // One look can miss a mark that is still there.
                            markSpots = []
                        }
                        let seen = icons.map {
                            "\($0.isCross ? "cross" : "mark") \(Int($0.x)),\(Int($0.y)) \(Int($0.width))x\(Int($0.height))"
                        }
                        note("picture: " + (seen.isEmpty ? "no marks near the top corners" : seen.joined(separator: "; ")),
                             kind: "icons")
                    }
                    if inAd, network == .unknown {
                        network = Self.adNetwork(in: items)
                        if network != .unknown {
                            log("ad network: \(network.rawValue)")
                        }
                    }
                    let leftIsSuspect = cautiousLeft || earlySpots.contains(where: { $0.x < width / 2 })
                        || network == .pangle || network == .mintegral || network == .liftoff
                    let probePoints = Self.probePoints(width: width, height: height, leftControls: leftControls,
                                                       earlySpots: earlySpots, badSpots: badSpots,
                                                       network: network, countdownSpot: countdownSpot,
                                                       storeSpots: storeSpots, avoidLeft: leftIsSuspect,
                                                       marks: markSpots, adFrame: adFrame, tried: probeTaps)
                    // The control app can keep naming the game after the player
                    // went to the home screen.
                    let onHomeScreen = Self.looksLikeHomeScreen(elements)
                    // A page that was just closed can still be reported for a
                    // moment, and the screen underneath has other controls in
                    // the same place. So the same spot waits before a second tap.
                    // A cross found in the picture that has not been used up.
                    var usableCross: CGPoint?
                    for spot in crossSpots {
                        if Self.isNear(spot, any: badSpots) || Self.isNear(spot, any: leftControls) {
                            continue
                        }
                        if Self.count(of: spot, in: crossStoreSpots) >= 1 || Self.count(of: spot, in: crossTaps) >= 3 {
                            continue
                        }
                        usableCross = spot
                        break
                    }
                    // A mark at the top right that is not a plain cross: a cross
                    // in a ring, an arrow. It showed up where close buttons go.
                    var usableMark: CGPoint?
                    if network != .appLovin, markTaps < 4 {
                        for spot in markSpots where spot.x > width / 2 {
                            if Self.isNear(spot, any: badSpots) || Self.count(of: spot, in: storeSpots) >= 1
                                || Self.count(of: spot, in: probeTaps) >= 3 {
                                continue
                            }
                            usableMark = spot
                            break
                        }
                    }
                    var recentCloseSpots: [CGPoint] = []
                    if let spot = lastCandidateTap, Date().timeIntervalSince(lastCandidateTapAt) < 8 {
                        recentCloseSpots.append(spot)
                    }
                    let storePageShowing = items.contains(where: { $0.type == "NavigationBar" })
                    // The store page can be up while its buttons cannot be read.
                    // Its text still gives it away.
                    let storeWordsSeen = Self.storePageWords.filter { word in
                        items.contains(where: { $0.label.contains(word) })
                    }.count
                    let storeByText = inAd && elements.isEmpty && storeWordsSeen >= 2 && width > height
                    // The game reports its whole screen as one text view. With
                    // nothing else in sight this is the game's own page, where a
                    // cross closes the page with the start button.
                    let onlyGameView = elements.isEmpty || elements.allSatisfy { $0.type == "TextView" }
                    let adLikely = adOnScreen || storePageShowing || !onlyGameView
                    if storePageShowing, let probe = lastProbe, Date().timeIntervalSince(lastProbeAt) < 10 {
                        // That spot is part of the ad, not its close button.
                        if lastProbeWasCross {
                            crossStoreSpots.append(probe)
                        } else {
                            storeSpots.append(probe)
                        }
                        lastProbe = nil
                        log("\(Int(probe.x)),\(Int(probe.y)) opened the store page instead of closing the ad")
                    }
                    // One line for the on-screen log, with a sample of what was
                    // read; the full list goes to the file only.
                    let sample = items.prefix(12).map { $0.label }.filter { !$0.isEmpty }.joined(separator: " / ")
                    note("tick phase=\(inAd ? "ad" : "idle") items=\(items.count): \(String(sample.prefix(140)))",
                         kind: "tick")
                    pendingDetails = []
                    for item in items.prefix(70) {
                        log("  " + item.summary)
                    }

                    if (inAd || config.observeOnly),
                       Date().timeIntervalSince(lastScreenshot) >= (config.observeOnly ? 6 : 20) {
                        lastScreenshot = Date()
                        await saveScreenshot(tag: inAd ? "ad" : "watch")
                    }

                    if config.observeOnly {
                        status = "Recording only. Nothing is tapped.".localized
                    } else if onHomeScreen {
                        note("state: the home screen is showing; nothing is tapped", kind: "wait")
                        status = "Paused. Go back to the game to continue.".localized
                    } else if !inAd {
                        // Right after an ad the game shows its reward window; a
                        // tap on the start button then goes nowhere.
                        if startItem == nil, adoptions < 2, adOnScreen || storePageShowing {
                            // An ad is showing although this run did not start it:
                            // left over from before, or started by hand. How long it
                            // has been playing is unknown; a countdown still counts.
                            adoptions += 1
                            log("an ad is already on screen; taking it from here")
                            phase = .ad(startedAt: Date().addingTimeInterval(-12))
                            probeIndex = 0
                            closeTaps = 0
                            lastCloseTap = nil
                            dismissTaps = 0
                            earlySpots = []
                            sawCountdown = false
                            countdownGoneSince = nil
                            lastCountdownLabel = ""
                            lastCountdownValue = nil
                            lastCountdownProgress = Date.distantPast
                            countdownFirstSeen = nil
                            openStoreTaps = 0
                            lastOpenStoreTap = Date.distantPast
                            storeClosedAt = nil
                            cautiousLeft = false
                            lastCandidateTap = nil
                            lastCandidateTapAt = Date.distantPast
                            // Spots are only meaningful within one ad.
                            badSpots = []
                            countdownSpot = nil
                            countdownEnds = Date.distantPast
                            storeSpots = []
                            lastProbe = nil
                            lastProbeAt = Date.distantPast
                            network = .unknown
                            crossSpots = []
                            markSpots = []
                            lastIconScan = Date.distantPast
                            crossTaps = []
                            probeTaps = []
                            crossStoreSpots = []
                            lastProbeWasCross = false
                            statedLength = 0
                            skipTaps = 0
                            lastSkipTap = Date.distantPast
                            mirrorPending = false
                            mirrorTaps = 0
                            nudges = 0
                            lastNudge = Date.distantPast
                            emptyReads = 0
                            blindRepairs = 0
                            lastBlindRepair = Date.distantPast
                            storeGuesses = 0
                            lastStoreGuess = Date.distantPast
                            markTaps = 0
                            status = "Ad started. Waiting for the close button…".localized
                        } else if startItem == nil, adOnScreen || storePageShowing {
                            note("an ad is on screen and could not be closed", kind: "wait")
                            if config.restartGame, let game, gameRestarts < Self.maximumGameRestarts,
                               Date().timeIntervalSince(lastGameRestart) >= 60 {
                                gameRestarts += 1
                                lastGameRestart = Date()
                                await restartGame(game, why: "the ad could not be closed", count: gameRestarts)
                                lastAdEnded = Date()
                                adoptions = 0
                            } else {
                                status = "Could not close this ad. Close it by hand.".localized
                            }
                        } else if let startItem, Date().timeIntervalSince(lastAdEnded) >= 5 {
                            log("action: tap start \(startItem.summary)")
                            await tap(x: startItem.centerX, y: startItem.centerY)
                            phase = .ad(startedAt: Date())
                            probeIndex = 0
                            closeTaps = 0
                            lastCloseTap = nil
                            dismissTaps = 0
                            earlySpots = []
                            sawCountdown = false
                            countdownGoneSince = nil
                            lastCountdownLabel = ""
                            lastCountdownValue = nil
                            lastCountdownProgress = Date.distantPast
                            countdownFirstSeen = nil
                            openStoreTaps = 0
                            lastOpenStoreTap = Date.distantPast
                            storeClosedAt = nil
                            cautiousLeft = false
                            lastCandidateTap = nil
                            lastCandidateTapAt = Date.distantPast
                            // Spots are only meaningful within one ad.
                            badSpots = []
                            countdownSpot = nil
                            countdownEnds = Date.distantPast
                            storeSpots = []
                            lastProbe = nil
                            lastProbeAt = Date.distantPast
                            network = .unknown
                            crossSpots = []
                            markSpots = []
                            lastIconScan = Date.distantPast
                            crossTaps = []
                            probeTaps = []
                            crossStoreSpots = []
                            lastProbeWasCross = false
                            statedLength = 0
                            skipTaps = 0
                            lastSkipTap = Date.distantPast
                            mirrorPending = false
                            mirrorTaps = 0
                            nudges = 0
                            lastNudge = Date.distantPast
                            emptyReads = 0
                            blindRepairs = 0
                            lastBlindRepair = Date.distantPast
                            storeGuesses = 0
                            lastStoreGuess = Date.distantPast
                            markTaps = 0
                            status = "Ad started. Waiting for the close button…".localized
                        } else if let confirmItem {
                            log("action: tap confirm \(confirmItem.summary)")
                            await tap(x: confirmItem.centerX, y: confirmItem.centerY)
                        } else if let claim = Self.claimButton(in: items, allowUntitled: false) {
                            log("action: tap claim \(claim.summary)")
                            await tap(x: claim.centerX, y: claim.centerY)
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
                            adoptions = 0
                            status = String(format: "Ads finished: %lld".localized, adsFinished)
                            if emptyStarts >= 4 {
                                // The button no longer starts an ad: the daily limit
                                // is probably used up.
                                log("the start button did not start an ad 4 times in a row; stopping")
                                stopNote = "No more ads seem to be available.".localized
                                break
                            }
                        }
                    } else if config.restartGame, config.probeCorners, let game,
                              gameRestarts < Self.maximumGameRestarts,
                              !countdownLive, adElapsed >= 60, Date().timeIntervalSince(lastTapAt) >= 60,
                              Date().timeIntervalSince(lastGameRestart) >= 60 {
                        // A minute without anything to tap: no close button is
                        // known here and none will come.
                        gameRestarts += 1
                        lastGameRestart = Date()
                        await restartGame(game, why: "nothing could be tapped for a minute", count: gameRestarts)
                        phase = .idle
                        lastAdEnded = Date()
                        adoptions = 0
                    } else if width > 0, height > 0, let sheet = Self.reportSheet(in: items) {
                        // A "report this ad" sheet is open: the control that was
                        // tapped was not a close button. Remember that spot, then
                        // get rid of the sheet. Its own button is only used when
                        // the player turned that on.
                        if let spot = lastCloseTap, !Self.isNear(spot, any: badSpots) {
                            badSpots.append(spot)
                            log("\(Int(spot.x)),\(Int(spot.y)) opened a report sheet; it will not be tapped again")
                        }
                        if dismissTaps < (config.submitReportSheet ? 4 : 8) {
                            // The ad's own close spot first, then beside the
                            // sheet.
                            // The spot was just added to the bad ones, so this
                            // list starts with its mirror image on the right.
                            let escape = Self.probePoints(width: width, height: height, leftControls: leftControls,
                                                          earlySpots: earlySpots, badSpots: badSpots).first
                                ?? Self.cornerPoints(width: width, height: height)[0]
                            let point: CGPoint
                            switch dismissTaps % 4 {
                            case 0: point = escape
                            case 1: point = CGPoint(x: width * 0.2, y: height * 0.5)
                            case 2: point = CGPoint(x: width * 0.8, y: height * 0.5)
                            default: point = CGPoint(x: width * 0.5, y: height * 0.96)
                            }
                            dismissTaps += 1
                            await saveScreenshot(tag: "report")
                            log("action: dismiss report sheet ('\(sheet.label)') at \(Int(point.x)),\(Int(point.y))")
                            await tap(x: point.x, y: point.y)
                        } else if config.submitReportSheet, reportSubmits < Self.maximumReportSubmits,
                                  Date().timeIntervalSince(lastReportSubmit) >= 6,
                                  let submit = Self.reportSubmitButton(in: items) {
                            // The sheet has no cancel button and nothing beside it
                            // closes it. The player chose this way out.
                            reportSubmits += 1
                            lastReportSubmit = Date()
                            await saveScreenshot(tag: "report")
                            log("action: tap the report sheet's button \(submit.summary) "
                                + "(\(reportSubmits) of \(Self.maximumReportSubmits) this run)")
                            await tap(x: submit.centerX, y: submit.centerY)
                        } else if config.submitReportSheet, reportSubmits < Self.maximumReportSubmits,
                                  Date().timeIntervalSince(lastReportSubmit) < 6 {
                            note("waiting: the report sheet's button was just tapped", kind: "wait")
                        } else {
                            note("the report sheet ('\(sheet.label)') could not be dismissed", kind: "wait")
                            status = "A report window is open. Close it by hand.".localized
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
                    } else if let claim = Self.claimButton(in: items, allowUntitled: !countdownLive) {
                        // The ad is over and the game is handing out the reward.
                        log("action: tap claim \(claim.summary)")
                        await tap(x: claim.centerX, y: claim.centerY)
                    } else if let done = Self.storeDoneButton(in: items, height: height) {
                        // The store page an ad opened: close it to get back.
                        log("action: tap store done \(done.summary)")
                        await tap(x: done.centerX, y: done.centerY)
                        storeClosedAt = Date()
                        if network == .appLovin, config.probeCorners, width > height, skipTaps < 10 {
                            // The skip mark shows for a few seconds once the
                            // store page is gone.
                            try? await Task.sleep(nanoseconds: 1_300_000_000)
                            log("action: tap the skip mark's place right after the store page")
                            await tap(x: 27, y: 82)
                            skipTaps += 1
                            lastSkipTap = Date()
                            mirrorPending = true
                            lastProbe = nil
                            lastIconScan = Date.distantPast
                        }
                    } else if storeByText, storeGuesses < 15, Date().timeIntervalSince(lastStoreGuess) >= 3 {
                        // Its close button is at the top left; where exactly
                        // depends on how wide the page is shown.
                        let guesses: [(Double, Double)] = [(42, 81), (98, 81), (60, 46), (116, 46), (70, 81)]
                        let guess = guesses[storeGuesses % guesses.count]
                        storeGuesses += 1
                        lastStoreGuess = Date()
                        log("action: the store page shows but its buttons cannot be read; "
                            + "trying its close button at \(Int(guess.0)),\(Int(guess.1))")
                        await tap(x: guess.0, y: guess.1)
                        storeClosedAt = Date()
                    } else if countdownLive {
                        // Closing while the countdown runs gives up the reward.
                        note("waiting: countdown '\(lastCountdownLabel)' is showing", kind: "wait")
                    } else if adElapsed >= Self.minimumAdSeconds, adLikely,
                              let closeItem = Self.closeCandidate(in: items, width: width, height: height,
                                                                  avoiding: badSpots + recentCloseSpots,
                                                                  earlyControls: earlySpots,
                                                                  allowLeft: !leftIsSuspect && probeIndex >= 4,
                                                                  allowArrow: storeClosedAt != nil || countdownGone
                                                                      || adElapsed >= TimeInterval(config.maxAdSeconds)) {
                        await saveScreenshot(tag: "close")
                        log("action: tap close \(closeItem.summary)")
                        await tap(x: closeItem.centerX, y: closeItem.centerY)
                        lastCloseTap = CGPoint(x: closeItem.centerX, y: closeItem.centerY)
                        lastCandidateTap = lastCloseTap
                        lastCandidateTapAt = Date()
                        closeTaps += 1
                        if storePageShowing {
                            // That was the store page an ad opened. The ad's own
                            // close button comes after it.
                            storeClosedAt = Date()
                            if network == .appLovin, config.probeCorners, width > height, skipTaps < 10 {
                                // The skip mark shows for a few seconds once the
                                // store page is gone.
                                try? await Task.sleep(nanoseconds: 1_300_000_000)
                                log("action: tap the skip mark's place right after the store page")
                                await tap(x: 27, y: 82)
                                skipTaps += 1
                                lastSkipTap = Date()
                                mirrorPending = true
                                lastProbe = nil
                                lastIconScan = Date.distantPast
                            }
                        }
                    } else if config.probeCorners, adElapsed >= 10, !storePageShowing,
                              Date().timeIntervalSince(lastProbeAt) >= 3, let cross = usableCross {
                        await saveScreenshot(tag: "cross")
                        log("action: tap the cross seen in the picture at \(Int(cross.x)),\(Int(cross.y))")
                        await tap(x: cross.x, y: cross.y)
                        crossTaps.append(cross)
                        lastCloseTap = cross
                        lastProbe = cross
                        lastProbeWasCross = true
                        lastProbeAt = Date()
                        closeTaps += 1
                    } else if config.probeCorners, adElapsed >= 10, adLikely, !storePageShowing,
                              Date().timeIntervalSince(lastProbeAt) >= 3, let mark = usableMark {
                        await saveScreenshot(tag: "mark")
                        log("action: tap the mark seen at the top right, \(Int(mark.x)),\(Int(mark.y))")
                        await tap(x: mark.x, y: mark.y)
                        markTaps += 1
                        lastCloseTap = mark
                        lastProbe = mark
                        lastProbeWasCross = false
                        lastProbeAt = Date()
                        probeTaps.append(mark)
                        closeTaps += 1
                    } else if config.probeCorners, network == .appLovin, width > height, adOnScreen,
                              !storePageShowing, mirrorPending, mirrorTaps < 2,
                              Date().timeIntervalSince(lastSkipTap) >= 2,
                              Date().timeIntervalSince(lastSkipTap) < 15 {
                        // After the skip mark this network's close button shows
                        // up across from it.
                        mirrorPending = false
                        mirrorTaps += 1
                        log("action: tap across from the skip mark at \(Int(width - 27)),82")
                        await tap(x: width - 27, y: 82)
                        lastProbe = nil
                        lastProbeAt = Date()
                        closeTaps += 1
                    } else if config.probeCorners, network == .appLovin, width > height, adOnScreen,
                              !storePageShowing, nudges < 8,
                              Date().timeIntervalSince(lastNudge) >= 6,
                              Date().timeIntervalSince(lastSkipTap) >= 5,
                              adElapsed >= TimeInterval(config.maxAdSeconds) || countdownGone || storeClosedAt != nil {
                        // The mark is hidden. A touch on its place brings it back,
                        // or brings up the store page, and closing that page
                        // brings it back too.
                        nudges += 1
                        lastNudge = Date()
                        log("action: touch the skip mark's place at 27,82 (\(nudges))")
                        await tap(x: 27, y: 82)
                        lastProbe = nil
                        closeTaps += 1
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        let after = await readElements()
                        if after.contains(where: { $0.type == "NavigationBar" }) {
                            log("the store page came up; the mark is tapped once that page is closed")
                        } else if Self.adNetwork(in: after) == .appLovin {
                            log("action: tap the skip mark's place again while it shows")
                            await tap(x: 27, y: 82)
                            skipTaps += 1
                            lastSkipTap = Date()
                            mirrorPending = true
                            lastIconScan = Date.distantPast
                        }
                    } else if adElapsed >= Self.minimumAdSeconds, adLikely, openStoreTaps < 3,
                              Date().timeIntervalSince(lastOpenStoreTap) >= 10,
                              let openStore = Self.firstMatch(in: items, keywords: Self.openStoreWords) {
                        // No close button yet, and the ad offers its store page:
                        // on these ads the close button comes after that page.
                        openStoreTaps += 1
                        lastOpenStoreTap = Date()
                        await saveScreenshot(tag: "store")
                        log("action: tap open store \(openStore.summary)")
                        await tap(x: openStore.centerX, y: openStore.centerY)
                    } else if config.probeCorners,
                              adElapsed >= TimeInterval(config.maxAdSeconds) || countdownGone
                                  || (openStoreTaps > 0 && Date().timeIntervalSince(lastOpenStoreTap) >= 8)
                                  || (storeClosedAt.map { Date().timeIntervalSince($0) >= 4 } ?? false),
                              width > 0, height > 0, adLikely, !storePageShowing, storeSpots.count < 5,
                              network != .appLovin || nudges >= 8 || width <= height,
                              !blindHold,
                              !probePoints.isEmpty {
                        var point = probePoints[probeIndex % probePoints.count]
                        if let spot = countdownSpot, let gone = countdownGoneSince, countdownSpotTapAt < gone,
                           probePoints.contains(where: { $0 == spot }) {
                            // The close button most often takes the countdown's
                            // place, so that spot goes first once it ran out.
                            point = spot
                            countdownSpotTapAt = Date()
                        } else {
                            probeIndex += 1
                        }
                        await saveScreenshot(tag: "probe")
                        log("action: probe corner \(Int(point.x)),\(Int(point.y))")
                        await tap(x: point.x, y: point.y)
                        lastCloseTap = point
                        lastProbe = point
                        lastProbeWasCross = false
                        lastProbeAt = Date()
                        probeTaps.append(point)
                        closeTaps += 1
                    } else if adElapsed >= Self.abandonAdSeconds {
                        log("gave up on this ad after \(Int(adElapsed))s")
                        phase = .idle
                        lastAdEnded = Date()
                        if config.restartGame, let game, gameRestarts < Self.maximumGameRestarts,
                           Date().timeIntervalSince(lastGameRestart) >= 60 {
                            gameRestarts += 1
                            lastGameRestart = Date()
                            await restartGame(game, why: "the ad could not be closed", count: gameRestarts)
                            lastAdEnded = Date()
                            adoptions = 0
                        }
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
                if consecutiveErrors >= 3 {
                    status = "The control app is not responding. Open the iCTRL runner again.".localized
                }
                if consecutiveErrors >= 8 {
                    log("the control app did not answer 8 times in a row; stopping")
                    stopNote = "The control app is not responding. Open the iCTRL runner again.".localized
                    break
                }
            } catch {
                log("error: \(error.localizedDescription)")
                consecutiveErrors += 1
                if consecutiveErrors >= 3 {
                    status = "The control app is not responding. Open the iCTRL runner again.".localized
                }
                if consecutiveErrors >= 8 {
                    log("the control app did not answer 8 times in a row; stopping")
                    stopNote = "The control app is not responding. Open the iCTRL runner again.".localized
                    break
                }
            }

            let spent = Date().timeIntervalSince(tickStart)
            let remaining = Self.tickInterval - spent
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
        if !Task.isCancelled, stopNote == nil, Date() >= deadline {
            log("the set time of \(config.runMinutes) minutes is up")
            stopNote = "The set time is up.".localized
        }
    }

    // MARK: - Opening the game

    /// Finds the game by name and brings it to the front through the control
    /// app. Returns its bundle identifier, or nil when it could not be opened.
    private func openGame(named name: String) async -> String? {
        let key = "adGameBundleIDs"
        var known = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]

        var candidates: [(id: String, title: String)] = []
        if let saved = known[name] {
            candidates.append((saved, name))
        }
        status = "Looking up the game…".localized
        do {
            let country = Locale.current.region?.identifier.lowercased() ?? "us"
            let result = try await client.call(
                "resolve_app",
                ["text": name, "country": country, "distance": 5],
                timeout: 25
            )
            for app in (result["apps"] as? [[String: Any]]) ?? [] {
                guard let id = app["bundle_id"] as? String, !id.isEmpty,
                      !candidates.contains(where: { $0.id == id }) else { continue }
                candidates.append((id, (app["name"] as? String) ?? id))
            }
            let listing = candidates.map { $0.title + " = " + $0.id }.joined(separator: ", ")
            log("resolve_app '\(name)' (\(country)): \(listing)")
        } catch {
            log("resolve_app failed: \(error.localizedDescription)")
        }

        for candidate in candidates.prefix(6) {
            if Task.isCancelled { return nil }
            status = String(format: "Opening %@…".localized, candidate.title)
            do {
                _ = try await client.call("activate_app", ["bundle_id": candidate.id], timeout: 20)
                log("opened \(candidate.title) = \(candidate.id)")
                known[name] = candidate.id
                UserDefaults.standard.set(known, forKey: key)
                return candidate.id
            } catch {
                // Not installed, or not the right app: try the next match.
                log("could not open \(candidate.id): \(error.localizedDescription)")
            }
        }
        log("no installed app matched '\(name)'")
        return nil
    }

    // MARK: - Reading the screen

    private func readText() async -> [AdScreenItem] {
        do {
            // The accurate level is required: the fast one cannot read Chinese.
            let result = try await client.call("screen_text", timeout: 25)
            failedCalls = 0
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
            failedCalls += 1
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
            failedCalls += 1
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

    /// Whether recognised text runs sideways, which is how a landscape game
    /// shows up in the device's portrait points. Nil when there is too little
    /// text to tell.
    private static func looksRotated(_ texts: [AdScreenItem]) -> Bool? {
        let words = texts.filter { $0.label.trimmingCharacters(in: .whitespaces).count >= 3 }
        guard words.count >= 3 else { return nil }
        let sideways = words.filter { $0.height > $0.width * 1.3 }.count
        if sideways * 3 >= words.count * 2 { return true }
        if sideways * 3 <= words.count { return false }
        return nil
    }

    /// How the picture is turned, from the frames of large accessibility
    /// elements, which are in the points of the picture as the player sees it.
    /// Nil when no large element is in sight or they disagree.
    private static func turnFromElements(_ elements: [AdScreenItem], deviceWidth: Double) -> Bool? {
        var wide = 0
        var tall = 0
        for element in elements where element.width >= 200 && element.height >= 40 {
            if element.width > deviceWidth + 20 {
                wide += 1
            } else if element.height > deviceWidth + 20 {
                tall += 1
            }
        }
        if wide > 0, tall == 0 { return true }
        if tall > 0, wide == 0 { return false }
        return nil
    }

    /// Which way round the picture is turned, from texts that show up both as
    /// recognised text and as an accessibility element. Nil when none match.
    private static func flipVote(texts: [AdScreenItem], elements: [AdScreenItem],
                                 geometry: AdScreenGeometry, settled: Bool) -> Bool? {
        var normal = geometry
        normal.flipped = false
        var turned = geometry
        turned.flipped = true
        var normalVotes = 0
        var turnedVotes = 0
        for element in elements {
            let label = element.label.trimmingCharacters(in: .whitespaces).lowercased()
            // A countdown is read at two slightly different moments, so numbers
            // match when they are close.
            guard label.count >= 2,
                  let text = texts.first(where: {
                      let other = $0.label.trimmingCharacters(in: .whitespaces).lowercased()
                      if other == label { return true }
                      if let a = Int(other), let b = Int(label) { return abs(a - b) <= 3 }
                      return false
                  }) else { continue }
            let first = normal.toContent(text)
            let second = turned.toContent(text)
            let firstDistance = hypot(first.centerX - element.centerX, first.centerY - element.centerY)
            let secondDistance = hypot(second.centerX - element.centerX, second.centerY - element.centerY)
            // A text near the middle of the screen is in nearly the same place
            // either way round and says nothing.
            guard min(firstDistance, secondDistance) < 60,
                  abs(firstDistance - secondDistance) >= 80 else { continue }
            if firstDistance < secondDistance {
                normalVotes += 1
            } else {
                turnedVotes += 1
            }
        }
        if normalVotes == turnedVotes { return nil }
        let wantsTurned = turnedVotes > normalVotes
        if settled, wantsTurned != geometry.flipped {
            // Turning the picture round sends every tap to the opposite
            // corner. Once it is known, one text is not enough to change it.
            let inFavour = wantsTurned ? turnedVotes : normalVotes
            let against = wantsTurned ? normalVotes : turnedVotes
            if inFavour < 2 || against > 0 { return nil }
        }
        return wantsTurned
    }

    /// Small unlabelled buttons or images in a top corner.
    private static func cornerControls(in items: [AdScreenItem], width: Double, height: Double) -> [AdScreenItem] {
        guard width > 0, height > 0 else { return [] }
        return items.filter { item in
            item.source == .element
                && (item.type == "Button" || item.type == "Image")
                && item.label.trimmingCharacters(in: .whitespaces).isEmpty
                && (12...64).contains(item.width) && (12...64).contains(item.height)
                && (item.centerX < width * 0.22 || item.centerX > width * 0.78)
                && item.centerY < height * 0.3
        }
    }

    private static func isNear(_ point: CGPoint, any spots: [CGPoint]) -> Bool {
        spots.contains { abs($0.x - point.x) < 28 && abs($0.y - point.y) < 28 }
    }

    /// The title of a "report this ad" sheet, when one is open.
    private static func reportSheet(in items: [AdScreenItem]) -> AdScreenItem? {
        guard let title = firstMatch(in: items, keywords: reportSheetTitles),
              firstMatch(in: items, keywords: reportSheetButtons) != nil else {
            return nil
        }
        return title
    }

    /// The button that sends the report sheet. An accessibility element is
    /// preferred because its frame is exact.
    private static func reportSubmitButton(in items: [AdScreenItem]) -> AdScreenItem? {
        let matches = items.filter {
            reportSubmitLabels.contains($0.label.trimmingCharacters(in: .whitespaces).lowercased())
        }
        return matches.first(where: { $0.source == .element && $0.type == "Button" }) ?? matches.first
    }

    /// "Done" in the upper part of the screen, as on the store page.
    private static func storeDoneButton(in items: [AdScreenItem], height: Double) -> AdScreenItem? {
        guard height > 0 else { return nil }
        return items.first { item in
            item.centerY < height * 0.3
                && storeDoneLabels.contains(item.label.trimmingCharacters(in: .whitespaces).lowercased())
        }
    }

    /// The button that collects the reward. Without a reward title on screen
    /// only an unmistakable label counts, and only when the caller allows it.
    private static func claimButton(in items: [AdScreenItem], allowUntitled: Bool) -> AdScreenItem? {
        let titled = firstMatch(in: items, keywords: rewardTitles) != nil
        guard titled || allowUntitled else { return nil }
        return items.first { item in
            let label = item.label.trimmingCharacters(in: .whitespaces).lowercased()
            return claimLabels.contains(label) || (titled && acknowledgeLabels.contains(label))
        }
    }

    /// A countdown near a top corner: a bare number such as "5", or a short
    /// text such as "5 秒後可關閉".
    private static func countdown(in items: [AdScreenItem], width: Double, height: Double) -> AdScreenItem? {
        guard width > 0, height > 0 else { return nil }
        return items.first { item in
            guard item.centerY < height * 0.3,
                  item.centerX < width * 0.3 || item.centerX > width * 0.7 else {
                return false
            }
            let label = item.label.trimmingCharacters(in: .whitespaces).lowercased()
            guard !label.isEmpty, label.count <= 14, label.contains(where: { $0.isNumber }) else { return false }
            if clockMarks.contains(where: { label.contains($0) }) {
                return false
            }
            if countdownWords.contains(where: { label.contains($0) }) {
                return true
            }
            var digits = label
            if digits.hasSuffix("s") {
                digits.removeLast()
            }
            guard digits.count <= 3, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(digits) else {
                return false
            }
            return value > 0
        }
    }

    /// The most likely close control, or nil when none is on screen yet.
    private static func closeCandidate(in allItems: [AdScreenItem], width: Double, height: Double,
                                       avoiding badSpots: [CGPoint], earlyControls: [CGPoint],
                                       allowLeft: Bool, allowArrow: Bool) -> AdScreenItem? {
        let marks = allItems.filter {
            infoGlyphs.contains($0.label.trimmingCharacters(in: .whitespaces).lowercased())
        }
        // Leave out spots that turned out wrong, and anything sitting on an
        // information or report mark.
        let items = allItems.filter { item in
            let center = CGPoint(x: item.centerX, y: item.centerY)
            if isNear(center, any: badSpots) { return false }
            return !marks.contains { abs($0.centerX - item.centerX) < 24 && abs($0.centerY - item.centerY) < 24 }
        }
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
        // Early on the arrow would skip the ad and lose the reward.
        if allowArrow, let arrow = texts.first(where: {
            nextGlyphs.contains($0.label.trimmingCharacters(in: .whitespaces))
                && $0.centerX > width * 0.78 && $0.centerY < height * 0.3
        }) {
            return arrow
        }
        // Text inside the ad's own picture can say "close" too, so a
        // recognised word only counts near a top corner or when it is short.
        if let word = texts.first(where: {
            isCloseWord($0) && (isNearTopCorner($0) || $0.label.trimmingCharacters(in: .whitespaces).count <= 4)
        }) {
            return word
        }
        // 3. A small unlabelled button or image in a top corner. Close buttons
        // sit on the right far more often than on the left, where report and
        // information marks usually are, so the right-most one goes first.
        // An unlabelled one on the left opened a report sheet that could not
        // be closed again, so the left only counts when the caller allows it.
        return cornerControls(in: items, width: width, height: height)
            .filter { !isNear(CGPoint(x: $0.centerX, y: $0.centerY), any: earlyControls) }
            .filter { allowLeft || $0.centerX > width / 2 }
            .max { $0.centerX < $1.centerX }
    }

    /// Where to try for a close button that nothing on screen announces. The
    /// report mark on the left has the close button as its mirror image on
    /// the right, so those spots come first; then the usual corners.
    private static func probePoints(width: Double, height: Double, leftControls: [CGPoint],
                                    earlySpots: [CGPoint], badSpots: [CGPoint],
                                    network: AdNetwork = .unknown, countdownSpot: CGPoint? = nil,
                                    storeSpots: [CGPoint] = [], avoidLeft: Bool = false,
                                    marks: [CGPoint] = [], adFrame: CGRect? = nil,
                                    tried: [CGPoint] = []) -> [CGPoint] {
        guard width > 0, height > 0 else { return [] }
        var points: [CGPoint] = []
        func add(_ point: CGPoint, storeLimit: Int = 1) {
            guard point.x > 0, point.y > 0 else { return }
            if isNear(point, any: badSpots) || isNear(point, any: earlySpots) || isNear(point, any: leftControls) {
                return
            }
            // A spot that brought up the store page is part of the ad.
            if count(of: point, in: storeSpots) >= storeLimit {
                return
            }
            // Three tries without effect are enough for one spot.
            if count(of: point, in: tried) >= 3 {
                return
            }
            if points.contains(where: { abs($0.x - point.x) < 8 && abs($0.y - point.y) < 8 }) {
                return
            }
            points.append(point)
        }
        // Where the countdown was: on several networks the close button
        // takes its place when it runs out.
        if let spot = countdownSpot, spot.x > width / 2, spot.y < height * 0.3 {
            add(spot)
        }
        if let frame = adFrame, frame.width > 100, frame.height > 100 {
            // The ad's own top right corner. Its view is often smaller than
            // the screen, and it moves once a store page was shown.
            add(CGPoint(x: Double(frame.maxX) - 29, y: Double(frame.minY) + 30))
        }
        if network == .appLovin, width > height {
            // Its skip control sits at the top left and is not exposed to
            // accessibility or text recognition. It may show the store page
            // first and close the ad on the next tap, hence two tries.
            add(CGPoint(x: 27, y: 82), storeLimit: 2)
            add(CGPoint(x: width - 27, y: 82))
        }
        if network == .pangle, width > height {
            // Its close button takes the place of the timer at the top right.
            add(CGPoint(x: width - 30, y: 38))
        }
        let leftKnown = leftControls + (earlySpots + badSpots).filter { $0.x < width * 0.3 }
        for spot in leftKnown {
            add(CGPoint(x: width - spot.x, y: spot.y))
        }
        for mark in marks {
            // A mark seen in the picture. On the left only where that side is
            // not known for its report control.
            if mark.x < width / 2 && network != .appLovin && (avoidLeft || !leftKnown.isEmpty) {
                continue
            }
            add(mark)
        }
        for point in cornerPoints(width: width, height: height) {
            // With a known control on the left, a tap there can only go wrong.
            if (avoidLeft || !leftKnown.isEmpty) && point.x < width / 2 {
                continue
            }
            add(point)
        }
        return points
    }

    /// How many of the spots are this point, give or take a few points.
    private static func count(of point: CGPoint, in spots: [CGPoint]) -> Int {
        spots.filter { abs($0.x - point.x) < 8 && abs($0.y - point.y) < 8 }.count
    }

    /// Small light marks near the top corners of the picture: a cross, an
    /// arrow, a skip sign. `width` and `height` are the screen as the player
    /// sees it; the picture may arrive squeezed and is stretched back.
    private static func icons(in image: CGImage, width: Double, height: Double) -> [AdIcon] {
        let scale = 2.0
        let pixelWidth = Int(width * scale)
        let pixelHeight = Int(height * scale)
        guard pixelWidth > 40, pixelHeight > 40 else { return [] }
        var pixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: pixelWidth, height: pixelHeight,
                bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            return true
        }
        guard drawn else { return [] }

        // Searched: this far down, and this far in from each side.
        let top = min(pixelHeight, Int(135 * scale))
        let side = min(pixelWidth / 2, Int(150 * scale))
        let maximumSide = Int(34 * scale)
        let gap = Int(5 * scale)
        let margin = Int(5 * scale)
        var found: [AdIcon] = []

        for originX in [0, pixelWidth - side] {
            // Light, colourless pixels.
            var mask = [Bool](repeating: false, count: side * top)
            for y in 0..<top {
                for x in 0..<side {
                    let offset = (y * pixelWidth + originX + x) * 4
                    let red = Int(pixels[offset])
                    let green = Int(pixels[offset + 1])
                    let blue = Int(pixels[offset + 2])
                    let luminance = (red * 299 + green * 587 + blue * 114) / 1000
                    let spread = max(red, max(green, blue)) - min(red, min(green, blue))
                    mask[y * side + x] = luminance >= 185 && spread <= 45
                }
            }

            // Connected pixels.
            var seen = [Bool](repeating: false, count: side * top)
            var groups: [AdGlyph] = []
            for start in 0..<(side * top) {
                if !mask[start] || seen[start] {
                    continue
                }
                var part = AdGlyph(minX: start % side, minY: start / side, maxX: start % side, maxY: start / side,
                                   points: [], parts: 1)
                var stack = [start]
                seen[start] = true
                while let index = stack.popLast() {
                    part.points.append(index)
                    let x = index % side
                    let y = index / side
                    part.minX = min(part.minX, x)
                    part.maxX = max(part.maxX, x)
                    part.minY = min(part.minY, y)
                    part.maxY = max(part.maxY, y)
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let nextX = x + dx
                            let nextY = y + dy
                            if nextX < 0 || nextX >= side || nextY < 0 || nextY >= top {
                                continue
                            }
                            let next = nextY * side + nextX
                            if mask[next] && !seen[next] {
                                seen[next] = true
                                stack.append(next)
                            }
                        }
                    }
                }
                // Specks, and anything too large to be part of a mark.
                if part.points.count >= 6, part.maxX - part.minX <= maximumSide, part.maxY - part.minY <= maximumSide {
                    groups.append(part)
                }
            }
            // A picture full of light specks says nothing.
            if groups.count > 150 {
                continue
            }

            // Parts that belong together: the bar of a skip sign, a dot.
            var merged = true
            while merged {
                merged = false
                search: for first in 0..<groups.count {
                    for second in (first + 1)..<groups.count {
                        let a = groups[first]
                        let b = groups[second]
                        if b.minX <= a.maxX + gap, b.maxX >= a.minX - gap,
                           b.minY <= a.maxY + gap, b.maxY >= a.minY - gap {
                            groups[first].absorb(b)
                            groups.remove(at: second)
                            merged = true
                            break search
                        }
                    }
                }
            }

            for group in groups {
                let groupWidth = group.maxX - group.minX + 1
                let groupHeight = group.maxY - group.minY + 1
                let widthPoints = Double(groupWidth) / scale
                let heightPoints = Double(groupHeight) / scale
                let longer = max(widthPoints, heightPoints)
                let shorter = min(widthPoints, heightPoints)
                if longer < 7 || longer > 34 || shorter < 2.5 || group.parts > 4 {
                    continue
                }
                let fill = Double(group.points.count) / Double(groupWidth * groupHeight)
                if fill < 0.08 || fill > 0.8 {
                    continue
                }
                // Cut off by the edge of the searched area.
                if group.minY <= 0 || group.maxY >= top - 1 {
                    continue
                }
                // It has to stand alone: little else that is light around it.
                let ringMinX = max(0, group.minX - margin)
                let ringMinY = max(0, group.minY - margin)
                let ringMaxX = min(side - 1, group.maxX + margin)
                let ringMaxY = min(top - 1, group.maxY + margin)
                var light = 0
                for y in ringMinY...ringMaxY {
                    for x in ringMinX...ringMaxX where mask[y * side + x] {
                        light += 1
                    }
                }
                let ringArea = (ringMaxX - ringMinX + 1) * (ringMaxY - ringMinY + 1) - groupWidth * groupHeight
                let ringRatio = Double(light - group.points.count) / Double(max(1, ringArea))
                if ringRatio > 0.06 {
                    continue
                }
                // Shape, from how full each cell of a 6 by 6 grid is.
                var grid = [Int](repeating: 0, count: 36)
                for index in group.points {
                    let column = min(5, (index % side - group.minX) * 6 / groupWidth)
                    let row = min(5, (index / side - group.minY) * 6 / groupHeight)
                    grid[row * 6 + column] += 1
                }
                let cell = max(1.0, Double(groupWidth) / 6.0 * Double(groupHeight) / 6.0)
                var diagonal = 0.0
                for step in 0..<6 {
                    diagonal += Double(grid[step * 6 + step]) / cell
                    diagonal += Double(grid[step * 6 + (5 - step)]) / cell
                }
                diagonal /= 12.0
                let edgeCells = [2, 3, 32, 33, 12, 18, 17, 23]
                var edges = 0.0
                for edgeCell in edgeCells {
                    edges += Double(grid[edgeCell]) / cell
                }
                edges /= 8.0
                let aspect = widthPoints / heightPoints
                // Tall and thin is an exclamation or information mark.
                if aspect < 0.5 {
                    continue
                }
                let isCross = aspect >= 0.7 && aspect <= 1.4 && diagonal >= 0.45 && edges <= diagonal * 0.35
                let centerX = (Double(originX) + Double(group.minX + group.maxX) / 2.0) / scale
                let centerY = Double(group.minY + group.maxY) / 2.0 / scale
                found.append(AdIcon(isCross: isCross, x: centerX, y: centerY,
                                    width: widthPoints, height: heightPoints))
            }
        }
        return found
    }

    /// Which network's player is on screen, from its accessibility elements.
    private static func adNetwork(in items: [AdScreenItem]) -> AdNetwork {
        for item in items where item.source == .element {
            let label = item.label.lowercased()
            if label.contains("app lovin") || label.contains("applovin") {
                return .appLovin
            }
            if label == "pangle" {
                return .pangle
            }
            if label.contains("nemo ad renderer") || label.contains("liftoff") || label.contains("vungle") {
                return .liftoff
            }
            if label.contains("mutebtn") {
                return .mintegral
            }
        }
        return .unknown
    }

    /// Marks of an ad network whose top-left control reports the ad. The
    /// network's name is read from its logo, so near misses count too.
    private static func isReportNetworkMark(_ label: String) -> Bool {
        let lowered = label.lowercased()
        return lowered.contains("mutebtn") || lowered.contains("tegra") || lowered.contains("iegra")
    }

    /// App icons and the Dock: the home screen, not the game.
    private static func looksLikeHomeScreen(_ elements: [AdScreenItem]) -> Bool {
        if elements.contains(where: { $0.type == "Other" && $0.label == "Dock" }) {
            return true
        }
        return elements.filter { $0.type == "Icon" }.count >= 3
    }

    private static func cornerPoints(width: Double, height: Double) -> [CGPoint] {
        // Portrait screens keep close buttons below the status bar area.
        if width > height {
            // Landscape ads are usually inset by the notch area on both
            // sides, so the inset corner comes first. Right before left.
            return [
                CGPoint(x: width - 95, y: 41),
                CGPoint(x: width - 32, y: 32),
                CGPoint(x: width - 62, y: 62),
                CGPoint(x: 32, y: 32),
                CGPoint(x: 95, y: 41),
                CGPoint(x: 62, y: 62),
            ]
        }
        return [
            CGPoint(x: width - 32, y: 72),
            CGPoint(x: 32, y: 72),
            CGPoint(x: width - 32, y: 100),
            CGPoint(x: 32, y: 100),
        ]
    }

    // MARK: - Actions

    /// Closes the game and opens it again: the way out of an ad that offers
    /// nothing to tap. The reward for that ad is lost; the run goes on once
    /// the page with the start button is back.
    private func restartGame(_ game: String, why: String, count: Int) async {
        await saveScreenshot(tag: "stuck")
        log("action: closing the game and opening it again (\(why)); "
            + "restart \(count) of \(Self.maximumGameRestarts)")
        status = "Restarting the game…".localized
        do {
            _ = try await client.call("terminate_app", ["bundle_id": game], timeout: 20)
        } catch {
            log("the game could not be closed: \(error.localizedDescription)")
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        do {
            _ = try await client.call("activate_app", ["bundle_id": game], timeout: 20)
            log("the game was opened again")
        } catch {
            log("the game could not be opened again: \(error.localizedDescription)")
        }
        lastTapAt = Date()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
    }

    /// Taps a point given in content points.
    private func tap(x: Double, y: Double) async {
        guard failedCalls == 0 else {
            log("  tap skipped: the control app did not answer")
            return
        }
        lastTapAt = Date()
        var place = geometry
        if !place.rotated, place.deviceWidth > 0, x > place.deviceWidth + 1 {
            // A point this far to the right only exists on a picture that lies
            // on its side.
            place.rotated = true
        }
        let point = place.toDevice(x: x, y: y)
        if place.rotated {
            log("  tap \(Int(x)),\(Int(y)) on screen = \(Int(point.x)),\(Int(point.y)) on the device")
        }
        do {
            _ = try await client.call("tap", ["x": Double(point.x), "y": Double(point.y), "settle": false, "fast": true],
                                      timeout: 20)
        } catch {
            let problem = error.localizedDescription
            log("tap failed: \(problem)")
            // A refused point is an answer; the control app is alive.
            if !problem.contains("out of bounds") {
                failedCalls += 1
            }
        }
    }

    /// The control app stopped answering calls that touch the screen. Its own
    /// log says which call is stuck; its reset call clears that state without
    /// going through the stuck queue, and bringing the game to the front again
    /// makes it reconnect to the screen.
    private func recoverRunner(game: String?) async {
        log("the control app is not answering; asking it to reset")
        if let result = try? await client.call("logs", ["max_elements": 10], timeout: 8),
           let lines = result["lines"] as? [String] {
            for line in lines.suffix(10) {
                log("control app log: " + String(line.prefix(170)))
            }
        }
        if (try? await client.call("reset", [:], timeout: 8)) != nil {
            log("reset done")
        } else {
            // Its log still answers while every other call hangs: the control
            // app is stuck inside itself, and only a new start helps.
            log("reset was not answered either; closing the control app and opening it again")
            status = "Restarting the control app…".localized
            if let problem = await relaunchRunner() {
                log("the control app could not be opened again from here: \(problem)")
            } else {
                var version: String?
                for _ in 0..<20 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    version = await client.runnerVersion()
                    if version != nil { break }
                }
                log(version == nil ? "the control app did not come back" : "the control app is back")
                // It needs a moment before it can bring another app forward.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        if let game {
            for attempt in 1...3 {
                if (try? await client.call("activate_app", ["bundle_id": game], timeout: 20)) != nil {
                    break
                }
                log("the game could not be brought back (try \(attempt))")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        failedCalls = 0
    }

    /// Closes the control app and starts it again over this app's own
    /// connection to the device, the way the app list starts an app. Returns
    /// what went wrong, or nil.
    private func relaunchRunner() async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let apps: [String: String]
                do {
                    apps = try JITEnableContext.shared.getAllApps()
                } catch {
                    continuation.resume(returning: error.localizedDescription)
                    return
                }
                guard let bundleID = apps.keys.first(where: { $0.lowercased().contains("ictrl.uitests") }) else {
                    continuation.resume(returning: "the control app is not in the list of installed apps")
                    return
                }
                let started = JITEnableContext.shared.launchAppWithoutDebug(bundleID, logger: nil)
                continuation.resume(returning: started ? nil : "it did not start")
            }
        }
    }

    /// Takes a sharp picture of the screen and looks for marks in it.
    private func findIcons() async -> [AdIcon] {
        guard geometry.width > 0, geometry.height > 0, failedCalls == 0 else { return [] }
        do {
            let result = try await client.call("screenshot", ["scale": 3, "quality": 0.5], timeout: 12)
            guard let base64 = result["data"] as? String, let data = Data(base64Encoded: base64),
                  let image = UIImage(data: data)?.cgImage else {
                return []
            }
            return Self.icons(in: image, width: geometry.width, height: geometry.height)
        } catch {
            failedCalls += 1
            log("picture for marks failed: \(error.localizedDescription)")
            return []
        }
    }

    private func saveScreenshot(tag: String) async {
        guard failedCalls == 0, screenshotCount < Self.maximumScreenshots, let folder = sessionFolder else { return }
        do {
            let result = try await client.call("screenshot", ["scale": 1, "quality": 0.5], timeout: 12)
            guard let base64 = result["data"] as? String, let data = Data(base64Encoded: base64) else { return }
            screenshotCount += 1
            let name = String(format: "%03d-%@.jpg", screenshotCount, tag)
            try data.write(to: folder.appendingPathComponent(name))
            log("screenshot \(name)")
        } catch {
            failedCalls += 1
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

    /// The run so far as plain text, short enough to paste into a message.
    func transcriptText() -> String {
        var lines: [String] = []
        if !previousTranscript.isEmpty {
            lines.append("=== previous run ===")
            lines += previousTranscript
            lines.append("=== latest run ===")
        }
        lines += transcript
        lines += pendingDetails
        return lines.joined(separator: "\n")
    }

    /// Logs a line unless it repeats the previous note, so a state that lasts
    /// many ticks shows once.
    private func note(_ message: String, kind: String = "state") {
        guard lastNotes[kind] != message else { return }
        lastNotes[kind] = message
        log(message)
    }

    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        let line = "\(formatter.string(from: Date())) \(message)"
        if let data = (line + "\n").data(using: .utf8) {
            try? logHandle?.write(contentsOf: data)
        }
        if message.hasPrefix("  ") && !message.hasPrefix("  tap ") {
            pendingDetails.append(line)
        } else {
            if message.hasPrefix("action:") || message.hasPrefix("waiting:") || message.hasPrefix("control at") {
                transcript.append(contentsOf: pendingDetails)
                pendingDetails = []
            }
            transcript.append(line)
            if transcript.count > 1500 {
                transcript.removeFirst(300)
            }
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
