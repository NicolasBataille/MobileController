import SwiftUI

/// Form tab — the fill / read-back / field-clear path.
///
/// `form.echoLabel` mirrors the field's exact current contents, so a tool can
/// verify what it actually typed without OCR. This is the screen that catches the
/// two known keyboard hazards: an AZERTY host layout mangling characters, and a
/// "clear" that silently leaves residue in the field.
struct FormView: View {
    /// Shown by the echo label when the field is empty, so the label always has
    /// a non-empty, unambiguous value to read back.
    static let emptyPlaceholder = "(empty)"

    @State private var text = ""

    private var echoText: String {
        text.isEmpty ? FormView.emptyPlaceholder : text
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Input") {
                    TextField("Type here", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .accessibilityIdentifier(AXID.textField)
                        .accessibilityLabel("Text input")

                    Button("Clear") {
                        text = ""
                    }
                    .disabled(text.isEmpty)
                    .accessibilityIdentifier(AXID.clearButton)
                }

                Section("Echo") {
                    Text(echoText)
                        .monospaced()
                        .accessibilityIdentifier(AXID.echoLabel)
                        .accessibilityLabel("Echo")
                        .accessibilityValue(echoText)

                    Text("\(text.count) characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AXID.characterCountLabel)
                        .accessibilityLabel("Character count")
                        .accessibilityValue("\(text.count)")
                }
            }
            .navigationTitle("Form")
            .accessibilityIdentifier(AXID.formRoot)
        }
    }
}

#Preview {
    FormView()
}
