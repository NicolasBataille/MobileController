/// Renders a `ProbeError` on the stream its consumer is already reading.
///
/// Human output puts the message on **stderr** and leaves stdout empty, so a shell pipeline
/// never mistakes a diagnostic for a result. `--json` output puts an error *object* on
/// **stdout**, so an agent parsing stdout never has to fall back to scraping stderr.
enum ErrorReporter {

    static func report(_ error: ProbeError, json: Bool, to output: any OutputWriting) {
        guard json else {
            output.writeErrorLine("simprobe: \(error)")
            return
        }
        let envelope = Envelope(
            error: Body(code: error.exitCode, kind: error.kind, message: error.description)
        )
        if let line = try? JSONLine.encode(envelope) {
            output.writeLine(line)
        } else {
            output.writeErrorLine("simprobe: \(error)")
        }
    }

    private struct Envelope: Encodable {
        let error: Body
    }

    private struct Body: Encodable {
        let code: Int32
        let kind: String
        let message: String
    }
}
