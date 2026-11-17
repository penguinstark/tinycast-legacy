import Foundation

/// The caret a field restores after a programmatic text change; SwiftUI's own type is macOS 15.
struct FormTextSelection: Equatable, Sendable {
    let range: Range<String.Index>
}
