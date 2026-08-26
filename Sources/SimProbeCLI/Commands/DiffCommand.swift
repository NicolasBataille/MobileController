import ArgumentParser
import Foundation
import SimProbeCore

struct DiffCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Compare two image files on the same scale the live verbs use.",
        discussion: """
            Both images are reduced to the same 40x87 grayscale thumbnail before comparison, \
            so a diff of two saved screenshots is directly comparable with a `wait-stable` \
            reading. Exits 4 when the two differ by more than --tol, so `simprobe diff a b && \
            echo unchanged` reads naturally.
            """
    )

    @Argument(help: "The baseline image.")
    var before: String

    @Argument(help: "The image to compare against it.")
    var after: String

    @Option(help: "Mean absolute luminance difference below which the two count as the same.")
    var tol: Double = FrameDiff.defaultTolerance

    @Flag(help: "Emit one line of JSON instead of the human-readable form.")
    var json = false

    func run() throws {
        let output = StandardOutput()
        do {
            let options = DiffOptions(
                lhs: URL(fileURLWithPath: before),
                rhs: URL(fileURLWithPath: after),
                tolerance: tol,
                json: json
            )
            try CommandExit.finish(DiffRunner(options: options).run(to: output))
        } catch let error as ProbeError {
            ErrorReporter.report(error, json: json, to: output)
            throw ExitCode(error.exitCode)
        }
    }
}
