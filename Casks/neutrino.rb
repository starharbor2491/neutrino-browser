cask "neutrino" do
  version "1.0.5-preview.1"
  sha256 "67f3c1a9f64417be9d5ec7be01255577f4a8236fbdeaadfc5cd022660dc16ecf"

  url "https://github.com/starharbor2491/neutrino-browser/releases/download/v#{version}/Neutrino-#{version}-AppleSilicon.app.zip"
  name "Neutrino"
  desc "Browser with Blink and WebKit engines and Arc, Vivaldi, GX and Brave layouts"
  homepage "https://github.com/starharbor2491/neutrino-browser"

  # Every release so far is a preview, which GitHub marks as a pre-release.
  livecheck do
    url :homepage
    strategy :git
    regex(/^v?(\d+(?:\.\d+)+(?:-preview\.\d+)?)$/i)
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Neutrino.app"

  # The same locations as the app's own Uninstall control; Keychain items are left to it.
  zap trash: [
    "~/Library/Application Support/org.neutrino.browser",
    "~/Library/Caches/org.neutrino.browser",
    "~/Library/Cookies/org.neutrino.browser.binarycookies",
    "~/Library/HTTPStorages/org.neutrino.browser",
    "~/Library/Preferences/org.neutrino.browser.plist",
    "~/Library/Saved Application State/org.neutrino.browser.savedState",
    "~/Library/WebKit/org.neutrino.browser",
  ]

  caveats <<~EOS
    Preview builds are not notarized by Apple. macOS blocks the first launch:
    open System Settings > Privacy & Security and choose Open Anyway.
  EOS
end
