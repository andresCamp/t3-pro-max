// What covers a window while it cannot show T3 yet: the page is loading (or pairing,
// which a person never needs to see), the desktop app is not running, or pairing failed. Opening T3 Code is the only step a user
// ever takes; the window connects by itself once the server answers.

import SwiftUI

@MainActor
final class WaitingModel: ObservableObject {
    enum State: Equatable {
        case loading
        case notRunning
        case pairingFailed(String)
    }

    @Published var state: State = .loading
    var onOpenT3: () -> Bool = { false }
    var onRetry: () -> Void = {}
    @Published var notInstalled = false
}

struct WaitingView: View {
    @ObservedObject var model: WaitingModel

    /// Most windows load in well under a second; the loader only appears for slower ones.
    @State private var showLoader = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if model.state == .loading {
                loader
            } else {
                message.transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.state)
    }

    private var loader: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            ProgressView().controlSize(.small)
        }
        .opacity(showLoader ? 1 : 0)
        .animation(.easeIn(duration: 0.3), value: showLoader)
        .task {
            try? await Task.sleep(for: .milliseconds(450))
            showLoader = true
        }
        .onDisappear { showLoader = false }
    }

    private var message: some View {
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
            case .loading:
                EmptyView()
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
        case .loading: ""
        case .pairingFailed: "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch model.state {
        case .notRunning: "Waiting for T3 Code"
        case .loading: ""
        case .pairingFailed: "Couldn't connect"
        }
    }

    private var detail: String {
        switch model.state {
        case .notRunning: "Open T3 Code and this window connects by itself."
        case .loading: ""
        case .pairingFailed(let reason): reason
        }
    }
}
