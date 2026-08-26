import ArgumentParser
import Foundation

struct ShotCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "shot",
        abstract: "Write one screenshot at 1x logical points and report what it cost.",
        discussion: """
            The default width is the device's logical point width, not a constant: a \
            coordinate read off the image then maps 1:1 onto the accessibility frame.

            The framebuffer scale is read from `simctl io <udid> enumerate`, which reports a \
            'Preferred UI Scale' for the integrated screen (3 on current iPhones, 2 on several \
            iPads). Pass --scale to skip that call, or to override it if a future simulator \
            stops reporting it.

            --udid accepts a UDID or a device name; omit it and the single booted \
            simulator is used, or exit 2 lists the candidates when that is ambiguous.
            """
    )

    @Option(help: "UDID or name of the simulator to capture. Defaults to the booted one.")
    var udid: String?

    @Option(help: "Where to write the JPEG.")
    var out: String = "shot.jpg"

    @Option(help: "Output width in pixels. Defaults to the device's logical point width (1x).")
    var width: Int?

    @Option(help: "JPEG quality, 1-100.")
    var quality: Int = ShotOptions.defaultQuality

    @Option(help: "Framebuffer pixels per point. Read from the simulator when omitted.")
    var scale: Double?

    @Flag(help: "Emit one line of JSON instead of the human-readable form.")
    var json = false

    func run() throws {
        try CommandExit.reporting(json: json) { output in
            let session = try ProbeSession.live()
            let resolved = try session.udid(for: udid)
            let options = ShotOptions(
                udid: resolved,
                outputPath: URL(fileURLWithPath: out),
                scale: try scale ?? session.displayMetrics.scale(udid: resolved),
                targetWidth: width,
                quality: quality,
                json: json
            )
            return try ShotRunner(options: options).run(in: session.environment(output: output))
        }
    }
}
