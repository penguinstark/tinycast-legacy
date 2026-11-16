import AppKit
import SwiftUI

/// The scroll metrics macOS 14 exposes only through AppKit; macOS 15's `onScrollGeometryChange` reads them in SwiftUI.
struct ScrollGeometrySnapshot: Equatable {
    var contentOffset: CGPoint
    var contentSize: CGSize
    var containerSize: CGSize
    var contentInsets: ScrollInsets

    struct ScrollInsets: Equatable {
        var top: CGFloat
        var bottom: CGFloat
    }
}

extension View {
    /// Reports a derived scroll metric whenever the enclosing scroll view moves or resizes.
    func onScrollGeometryRead<Value: Equatable>(
        for type: Value.Type, of transform: @escaping (ScrollGeometrySnapshot) -> Value,
        action: @escaping (Value, Value) -> Void
    ) -> some View {
        modifier(ScrollGeometryReader(transform: transform, action: action))
    }

    /// Reports whether the enclosing scroll view is moving, with a short idle delay.
    func onScrollActivityChange(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(ScrollActivityReader(action: action))
    }
}

private struct ScrollGeometryReader<Value: Equatable>: ViewModifier {
    let transform: (ScrollGeometrySnapshot) -> Value
    let action: (Value, Value) -> Void

    @State private var previous: Value?

    func body(content: Content) -> some View {
        content.background {
            ScrollProbe { geometry in
                let value = transform(geometry)
                let old = previous ?? value
                previous = value
                if old != value { action(old, value) }
            } onActivity: { _ in
            }
        }
    }
}

private struct ScrollActivityReader: ViewModifier {
    let action: (Bool) -> Void

    func body(content: Content) -> some View {
        content.background {
            ScrollProbe(onGeometry: { _ in }, onActivity: action)
        }
    }
}

private struct ScrollProbe: NSViewRepresentable {
    let onGeometry: (ScrollGeometrySnapshot) -> Void
    let onActivity: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onGeometry: onGeometry, onActivity: onActivity)
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        context.coordinator.onGeometry = onGeometry
        context.coordinator.onActivity = onActivity
        nsView.coordinator = context.coordinator
    }

    static func dismantleNSView(_ nsView: ProbeView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class ProbeView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.attach(to: enclosingScrollView)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator {
        var onGeometry: (ScrollGeometrySnapshot) -> Void
        var onActivity: (Bool) -> Void

        private weak var scrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var idleTask: Task<Void, Never>?

        init(
            onGeometry: @escaping (ScrollGeometrySnapshot) -> Void,
            onActivity: @escaping (Bool) -> Void
        ) {
            self.onGeometry = onGeometry
            self.onActivity = onActivity
        }

        func attach(to scrollView: NSScrollView?) {
            guard self.scrollView !== scrollView else { return }
            detach()
            guard let scrollView else { return }
            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollView.documentView?.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                },
                center.addObserver(
                    forName: NSView.frameDidChangeNotification, object: scrollView.documentView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                },
            ]
            report()
        }

        func detach() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            idleTask?.cancel()
            scrollView = nil
        }

        private func report() {
            guard let scrollView else { return }
            let clip = scrollView.contentView
            let document = scrollView.documentView
            let insets = scrollView.contentInsets
            onGeometry(
                ScrollGeometrySnapshot(
                    contentOffset: clip.bounds.origin,
                    contentSize: document?.frame.size ?? .zero,
                    containerSize: clip.bounds.size,
                    contentInsets: .init(top: insets.top, bottom: insets.bottom)))
            onActivity(true)
            idleTask?.cancel()
            idleTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                self?.onActivity(false)
            }
        }
    }
}
