import Foundation
import SimProbeCLI

// The warm action daemon. Spawned by `simprobe daemon start`; see docs/plans/05-warm-daemon.md.
//
// Top-level code rather than `@main` because the gRPC stubs this links are macOS 15 only, while
// `simprobe` itself still deploys to macOS 14 — and an availability check is expressible here in
// a way it is not on a `@main` type.

guard let arguments = DaemonArguments.parse(CommandLine.arguments) else {
    FileHandle.standardError.write(Data((DaemonArguments.usage + "\n").utf8))
    exit(1)
}

if #available(macOS 15, *) {
    exit(await DaemonEntry.run(arguments))
} else {
    FileHandle.standardError.write(
        Data("simprobe-daemon: needs macOS 15 or newer; simprobe's other verbs do not\n".utf8))
    exit(2)
}
