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
    /// The run as text for the clipboard: every main line, and what was on
    /// screen only for the ticks that led to an action.
    private var transcript: [String] = []
    private var pendingDetails: [String] = []
    private var previousTranscript: [String] = []
    private var runStartedAt = Date()

    private let client = AdRunnerClient.shared
    private static let tickInterval: TimeInterval = 2
    private static let minimumAdSeconds: TimeInterval = 5
    private static let abandonAdSeconds: TimeInterval = 240
    private static let maximumScreenshots = 240

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
        screenshotCount = 0
        stopNote = nil
        lastNotes = [:]
        geometry = AdScreenGeometry()
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
        let deadline = Date().addingTimeInterval(TimeInterval(config.runMinutes * 60))
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

        log("start; observeOnly=\(config.observeOnly) probe=\(config.probeCorners) maxAd=\(config.maxAdSeconds)s "
            + "game='\(config.gameName)' start=\(config.startKeywords) confirm=\(config.confirmKeywords)")
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
                    var elements: [AdScreenItem] = []
                    if inAd || config.observeOnly {
                        elements = await readElements()
                    }

                    // Work out how the picture is turned, then put everything
                    // into the space the player sees.
                    geometry.deviceWidth = deviceWidth
                    geometry.deviceHeight = deviceHeight
                    if deviceWidth > 0, deviceHeight > 0, let turned = Self.looksRotated(texts) {
                        geometry.rotated = turned
                    }
                    if geometry.rotated, let vote = Self.flipVote(texts: texts, elements: elements, geometry: geometry) {
                        geometry.flipped = vote
                    }
                    note("screen: content \(Int(geometry.width))x\(Int(geometry.height)) "
                         + "rotated=\(geometry.rotated) flipped=\(geometry.flipped)", kind: "geometry")
                    let width = geometry.width
                    let height = geometry.height
                    let items = texts.map { geometry.toContent($0) } + elements
                    let startItem = Self.firstMatch(in: items, keywords: config.startKeywords)
                    let loweredStart = config.startKeywords.map { $0.lowercased() }
                    let confirmItem = Self.firstMatch(
                        in: items.filter { item in
                            !loweredStart.contains(where: { item.label.lowercased().contains($0) })
                        },
                        keywords: config.confirmKeywords
                    )

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
                        } else if sawCountdown, countdownGoneSince == nil {
                            countdownGoneSince = Date()
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
                    let countdownGone = countdownGoneSince.map { Date().timeIntervalSince($0) >= 6 } ?? false
                    // Small unlabelled controls at the top left. On the ads seen
                    // so far that is the report mark, and it moves when the ad
                    // changes its frame, so it is looked up again every time.
                    let leftControls = Self.cornerControls(in: items, width: width, height: height)
                        .filter { $0.centerX < width / 2 }
                        .map { CGPoint(x: $0.centerX, y: $0.centerY) }
                    if inAd, items.contains(where: { Self.isReportNetworkMark($0.label) }) {
                        cautiousLeft = true
                    }
                    let leftIsSuspect = cautiousLeft || earlySpots.contains(where: { $0.x < width / 2 })
                    let probePoints = Self.probePoints(width: width, height: height, leftControls: leftControls,
                                                       earlySpots: earlySpots, badSpots: badSpots)
                    // The control app can keep naming the game after the player
                    // went to the home screen.
                    let onHomeScreen = Self.looksLikeHomeScreen(elements)
                    // A page that was just closed can still be reported for a
                    // moment, and the screen underneath has other controls in
                    // the same place. So the same spot waits before a second tap.
                    var recentCloseSpots: [CGPoint] = []
                    if let spot = lastCandidateTap, Date().timeIntervalSince(lastCandidateTapAt) < 8 {
                        recentCloseSpots.append(spot)
                    }
                    let storePageShowing = items.contains(where: { $0.type == "NavigationBar" })
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
                       Date().timeIntervalSince(lastScreenshot) >= 6 {
                        lastScreenshot = Date()
                        await saveScreenshot(tag: inAd ? "ad" : "watch")
                    }

                    if config.observeOnly {
                        status = "Recording only. Nothing is tapped.".localized
                    } else if onHomeScreen {
                        note("state: the home screen is showing; nothing is tapped", kind: "wait")
                        status = "Paused. Go back to the game to continue.".localized
                    } else if !inAd {
                        if let startItem {
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
                            status = String(format: "Ads finished: %lld".localized, adsFinished)
                            if emptyStarts >= 4 {
                                // The button no longer starts an ad: the daily limit
                                // is probably used up.
                                log("the start button did not start an ad 4 times in a row; stopping")
                                stopNote = "No more ads seem to be available.".localized
                                break
                            }
                        }
                    } else if width > 0, height > 0, let sheet = Self.reportSheet(in: items) {
                        // A "report this ad" sheet is open: the control that was
                        // tapped was not a close button. Remember that spot, then
                        // get rid of the sheet without submitting anything.
                        if let spot = lastCloseTap, !Self.isNear(spot, any: badSpots) {
                            badSpots.append(spot)
                            log("\(Int(spot.x)),\(Int(spot.y)) opened a report sheet; it will not be tapped again")
                        }
                        if dismissTaps < 8 {
                            // Beside the sheet first, then the corner where a
                            // close button usually is. Never "Submit".
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
                    } else if countdownLive {
                        // Closing while the countdown runs gives up the reward.
                        note("waiting: countdown '\(lastCountdownLabel)' is showing", kind: "wait")
                    } else if adElapsed >= Self.minimumAdSeconds,
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
                        }
                    } else if adElapsed >= Self.minimumAdSeconds, openStoreTaps < 3,
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
                              width > 0, height > 0, !storePageShowing,
                              !probePoints.isEmpty {
                        let point = probePoints[probeIndex % probePoints.count]
                        probeIndex += 1
                        await saveScreenshot(tag: "probe")
                        log("action: probe corner \(Int(point.x)),\(Int(point.y))")
                        await tap(x: point.x, y: point.y)
                        lastCloseTap = point
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

    /// Which way round the picture is turned, from texts that show up both as
    /// recognised text and as an accessibility element. Nil when none match.
    private static func flipVote(texts: [AdScreenItem], elements: [AdScreenItem],
                                 geometry: AdScreenGeometry) -> Bool? {
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
            guard min(firstDistance, secondDistance) < 60 else { continue }
            if firstDistance < secondDistance {
                normalVotes += 1
            } else {
                turnedVotes += 1
            }
        }
        if normalVotes == turnedVotes { return nil }
        return turnedVotes > normalVotes
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
        if let word = texts.first(where: { isCloseWord($0) }) {
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
                                    earlySpots: [CGPoint], badSpots: [CGPoint]) -> [CGPoint] {
        guard width > 0, height > 0 else { return [] }
        var points: [CGPoint] = []
        func add(_ point: CGPoint) {
            guard point.x > 0, point.y > 0 else { return }
            if isNear(point, any: badSpots) || isNear(point, any: earlySpots) || isNear(point, any: leftControls) {
                return
            }
            if points.contains(where: { abs($0.x - point.x) < 8 && abs($0.y - point.y) < 8 }) {
                return
            }
            points.append(point)
        }
        let leftKnown = leftControls + (earlySpots + badSpots).filter { $0.x < width * 0.3 }
        for spot in leftKnown {
            add(CGPoint(x: width - spot.x, y: spot.y))
        }
        for point in cornerPoints(width: width, height: height) {
            // With a known control on the left, a tap there can only go wrong.
            if !leftKnown.isEmpty && point.x < width / 2 {
                continue
            }
            add(point)
        }
        return points
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

    /// Taps a point given in content points.
    private func tap(x: Double, y: Double) async {
        let point = geometry.toDevice(x: x, y: y)
        if geometry.rotated {
            log("  tap \(Int(x)),\(Int(y)) on screen = \(Int(point.x)),\(Int(point.y)) on the device")
        }
        do {
            _ = try await client.call("tap", ["x": Double(point.x), "y": Double(point.y), "settle": false, "fast": true],
                                      timeout: 20)
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
