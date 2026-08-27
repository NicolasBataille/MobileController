# Homebrew formula for simprobe, kept in this repository rather than in a separate
# `homebrew-simprobe` tap: one repository, one release, one thing to bump.
#
# `brew tap NicolasBataille/MobileController <url>` accepts a repository whose name does not
# start with `homebrew-` as long as the URL is given explicitly, and finds this file because
# Homebrew looks in `Formula/` before the repository root. Homebrew 6 then wants an explicit
# `brew trust nicolasbataille/mobilecontroller` before it will load anything from here.
#
# Bump with `scripts/bump-formula.sh <tag>` on every release: the URL and the checksum both
# move, and a formula pinned to an old tag installs an old binary without saying so.
class Simprobe < Formula
  desc "Pixel-stability probe and 1x screenshot tool for the iOS Simulator"
  homepage "https://github.com/NicolasBataille/MobileController"
  url "https://github.com/NicolasBataille/MobileController/archive/refs/tags/v0.3.0.tar.gz"
  sha256 "18e2028a9fb9309073823e3ec283de4d581490cb2c0c2e625b24093dd1f3cd6d"
  license "MIT"
  head "https://github.com/NicolasBataille/MobileController.git", branch: "main"

  # Xcode rather than the Command Line Tools: simprobe drives `xcrun simctl`, and a machine
  # with no Xcode has no simulators for it to drive.
  depends_on xcode: ["16.0", :build]
  depends_on :macos

  def install
    # --disable-sandbox: SwiftPM's own build sandbox denies the writes the manifest needs
    # under Homebrew's staging directory.
    system "swift", "build", "-c", "release", "--disable-sandbox"
    # Both products: `simprobe tap` and `simprobe tree` look for `simprobe-daemon` as a sibling of
    # the running binary rather than on PATH, so a fresh CLI is never paired with a stale daemon.
    bin.install ".build/release/simprobe"
    bin.install ".build/release/simprobe-daemon"
  end

  def caveats
    <<~EOS
      `simprobe frames`, `tap` and `tree` additionally need idb, which is not a dependency of
      this formula because every other verb works without it:

        brew install facebook/fb/idb-companion && pip3 install fb-idb

      `tap` and `tree` also need a warm daemon: `simprobe daemon start --udid <udid>`.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/simprobe --version")
    assert_match "wait-stable", shell_output("#{bin}/simprobe --help")
    assert_match "daemon", shell_output("#{bin}/simprobe --help")
    # The daemon is only ever started by `simprobe daemon start`, so with no arguments it prints
    # its usage and exits 1 — which is a check that needs neither a simulator nor idb.
    assert_match "usage: simprobe-daemon", shell_output("#{bin}/simprobe-daemon 2>&1", 1)
  end
end
