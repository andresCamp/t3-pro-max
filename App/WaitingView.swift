// What a window shows while it cannot show T3 yet: the desktop app is not running,
// the window is pairing, or pairing failed. Opening T3 Code is the only step a user
// ever takes; the window connects by itself once the server answers.

import SwiftUI

@MainActor
final class WaitingModel: ObservableObject {
    enum State: Equatable {
        case notRunning
        case pairing
        case pairingFailed(String)
    }

    @Published var state: State = .pairing
    var onOpenT3: () -> Bool = { false }
    var onRetry: () -> Void = {}
    @Published var notInstalled = false
}

struct WaitingView: View {
    @ObservedObject var model: WaitingModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            switch model.state {
            case .notRunning:
                Button("Open T3 Code") { model.notInstalled = !model.onOpenT3() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                if model.notInstalled {
                    Link("T3 Code isn't installed. Get it at t3.codes", destination: URL(string: "https://t3.codes")!)
                }
            case .pairing:
                ProgressView().controlSize(.small)
            case .pairingFailed:
                Button("Try again", action: model.onRetry).controlSize(.large)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var symbol: String {
        switch model.state {
        case .notRunning: "macwindow.on.rectangle"
        case .pairing: "link"
        case .pairingFailed: "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch model.state {
        case .notRunning: "Waiting for T3 Code"
        case .pairing: "Connecting"
        case .pairingFailed: "Couldn't connect"
        }
    }

    private var detail: String {
        switch model.state {
        case .notRunning: "Open T3 Code and this window connects by itself."
        case .pairing: "Pairing this window with T3 Code."
        case .pairingFailed(let reason): reason
        }
    }
}
