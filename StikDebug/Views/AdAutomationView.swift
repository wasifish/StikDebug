//
//  AdAutomationView.swift
//  StikDebug
//

import SwiftUI

struct AdAutomationView: View {
    @ObservedObject private var engine = AdAutomationEngine.shared

    @AppStorage("adGameName") private var gameName = ""
    @AppStorage("adStartKeywords") private var startKeywords = ""
    @AppStorage("adConfirmKeywords") private var confirmKeywords = ""
    @AppStorage("adObserveOnly") private var observeOnly = false
    @AppStorage("adProbeCorners") private var probeCorners = true
    @AppStorage("adMaxSeconds") private var maxAdSeconds = 45
    @AppStorage("adRunMinutes") private var runMinutes = 30
    @AppStorage("adSubmitReportSheet") private var submitReportSheet = false

    @State private var copied = false

    private var runnerText: String {
        switch engine.runnerState {
        case .unknown:
            return "Checking…".localized
        case .notRunning:
            return "Not running".localized
        case .running(let version):
            return String(format: "Running (%@)".localized, version)
        }
    }

    private var canStart: Bool {
        engine.isPaired && engine.runnerState != .notRunning
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Control app", value: runnerText)
                LabeledContent("Connection", value: engine.isPaired ? "Connected".localized : "Not connected".localized)
                if engine.isPaired {
                    Button("Disconnect", role: .destructive) {
                        engine.disconnect()
                    }
                    .disabled(engine.isRunning)
                } else {
                    Button(engine.isConnecting ? "Connecting…".localized : "Connect".localized) {
                        Task { await engine.connect() }
                    }
                    .disabled(engine.isConnecting)
                }
                Button("Check Again") {
                    Task { await engine.refreshConnection() }
                }
            } header: {
                Text("Connection")
            } footer: {
                Text("Open the iCTRL runner app first. When you tap Connect, allow the request in its notification within 60 seconds.")
            }

            Section {
                TextField("Game name, as shown in the App Store", text: $gameName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Game")
            } footer: {
                Text("Start opens this game for you. Leave it empty to switch to the game yourself.")
            }
            .disabled(engine.isRunning)

            Section {
                TextField("Text on the button that starts an ad", text: $startKeywords)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Text to tap after the ad (optional)", text: $confirmKeywords)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Buttons")
            } footer: {
                Text("Type the words exactly as they appear in the game. Separate several with commas.")
            }
            .disabled(engine.isRunning)

            Section {
                Toggle("Record only, do not tap", isOn: $observeOnly)
                Toggle("Try the corners when no close button is found", isOn: $probeCorners)
                Stepper(value: $maxAdSeconds, in: 20...120, step: 5) {
                    Text(String(format: "Try the corners after %lld seconds".localized, maxAdSeconds))
                }
                Stepper(value: $runMinutes, in: 5...180, step: 5) {
                    Text(String(format: "Stop after %lld minutes".localized, runMinutes))
                }
                Toggle("Press Submit when a report window will not close", isOn: $submitReportSheet)
            } header: {
                Text("Options")
            } footer: {
                Text("Submit sends a report about the ad to the ad network. It is pressed at most 5 times per run.")
            }
            .disabled(engine.isRunning)

            Section {
                if engine.isRunning {
                    Button("Stop", role: .destructive) {
                        engine.stop()
                    }
                } else {
                    Button("Start Watching") {
                        engine.start(AdAutomationConfig(
                            gameName: gameName.trimmingCharacters(in: .whitespaces),
                            startKeywords: AdAutomationConfig.keywords(from: startKeywords),
                            confirmKeywords: AdAutomationConfig.keywords(from: confirmKeywords),
                            observeOnly: observeOnly,
                            probeCorners: probeCorners,
                            maxAdSeconds: maxAdSeconds,
                            runMinutes: runMinutes,
                            submitReportSheet: submitReportSheet
                        ))
                    }
                    .disabled(!canStart)
                }
                if !engine.status.isEmpty {
                    Text(verbatim: engine.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Leave the game on the page with the ad button. Come back here to stop.")
            }

            if let exportURL = engine.exportURL {
                Section {
                    ShareLink(item: exportURL) {
                        Label("Share the Run Log", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text("The log holds what was on screen and what was tapped during the last run.")
                }
            }

            if !engine.recentLog.isEmpty {
                Section {
                    Button(copied ? "Copied".localized : "Copy the Log".localized) {
                        UIPasteboard.general.string = engine.transcriptText()
                        copied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            copied = false
                        }
                    }
                } footer: {
                    Text("Paste it into the chat to report a problem.")
                }

                Section {
                    ForEach(Array(engine.recentLog.suffix(25).enumerated()), id: \.offset) { entry in
                        Text(verbatim: entry.element)
                            .font(.caption2.monospaced())
                    }
                } header: {
                    Text("Log")
                }
            }
        }
        .navigationTitle("Auto Ads")
        .task {
            await engine.refreshConnection()
        }
    }
}
