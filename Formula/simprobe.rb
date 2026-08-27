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
  url "https://github.com/NicolasBataille/MobileController/archive/refs/tags/v0.2.0.tar.gz"
  sha256 "e0e758764c457e4138810eb3b9ef5944049bde89d0201ad473474713c3207583"
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
    bin.install ".build/release/simprobe"
  end

  def caveats
    <<~EOS
      `simprobe frames` additionally needs idb, which is not a dependency of this formula
      because every other verb works without it:

        brew install facebook/fb/idb-companion && pip3 install fb-idb
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/simprobe --version")
    assert_match "wait-stable", shell_output("#{bin}/simprobe --help")
  end
end
