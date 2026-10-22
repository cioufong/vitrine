import SwiftUI

/// A horizontal slider over a fixed list of values (CPU count, memory, disk size), with the chosen
/// value on the right and the range underneath. A drag is committed when it ends, so the VM config
/// isn't rewritten for every step; arrow keys and VoiceOver commit each step.
struct ValueSlider<Value: Comparable & Hashable>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    let values: [Value]
    let format: (Value) -> String

    @State private var position: Double = 0
    @State private var dragging = false

    init(_ title: LocalizedStringKey, selection: Binding<Value>, values: [Value], format: @escaping (Value) -> String) {
        self.title = title
        self._selection = selection
        self.values = values
        self.format = format
    }

    /// The allowed values plus the current one, so a value set elsewhere (CLI, another Mac) shows as is.
    private var options: [Value] { Array(Set(values + [selection])).sorted() }
    private var shown: Value { options[min(max(Int(position.rounded()), 0), options.count - 1)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(title) {
                Text(format(dragging ? shown : selection)).monospacedDigit().foregroundStyle(.primary)
            }
            if options.count > 1 {
                Group {
                    // Tick marks only while they stay readable; a long list (1 GB memory steps) slides freely
                    // and snaps to the nearest value.
                    if options.count <= 16 {
                        Slider(value: $position, in: 0...Double(options.count - 1), step: 1, onEditingChanged: editingChanged)
                    } else {
                        Slider(value: $position, in: 0...Double(options.count - 1), onEditingChanged: editingChanged)
                    }
                }
                .labelsHidden()
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(format(shown)))
                HStack {
                    Text(format(options[0]))
                    Spacer()
                    Text(format(options[options.count - 1]))
                }
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .onAppear(perform: sync)
        .onChange(of: selection) { _, _ in if !dragging { sync() } }
        .onChange(of: position) { _, _ in if !dragging { commit() } }
    }

    private func editingChanged(_ editing: Bool) {
        dragging = editing
        if !editing { commit() }
    }

    private func sync() {
        let i = Double(options.firstIndex(of: selection) ?? 0)
        if position != i { position = i }
    }

    private func commit() {
        let v = shown
        if v != selection { selection = v }
        sync()
    }
}
