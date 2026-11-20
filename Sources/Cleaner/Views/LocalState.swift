import SwiftUI

/// Drop-in replacement for SwiftUI's `@State`.
///
/// In the macOS 27 SDK `@State` is a Swift macro whose plugin ships only with full Xcode,
/// so it fails to compile with the Command Line Tools alone. `@Local` stores the value in a
/// `@StateObject` box instead, which needs no macro and behaves the same for view-local state.
@propertyWrapper
struct Local<Value>: DynamicProperty {
    private final class Box: ObservableObject {
        @Published var value: Value
        init(_ value: Value) { self.value = value }
    }

    @StateObject private var box: Box

    init(wrappedValue: Value) {
        _box = StateObject(wrappedValue: Box(wrappedValue))
    }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<Value> { $box.value }
}
