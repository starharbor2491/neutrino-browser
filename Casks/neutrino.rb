cask "neutrino" do
  version "1.0.4-preview.2"
  sha256 "a665b10fe6f6db11f581f21a9b1b4a977571ddbd9f4bdaa8e9eed81632d05138"

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
