# Cask for the personal tap (github.com/mcglothi/homebrew-tap, Casks/portside.rb).
# Users install with:  brew install mcglothi/tap/portside
#
# Reference copy only — the tap is the source of truth. Scripts/release.sh now
# bumps the tap's cask automatically on every release (PORTSIDE_SKIP_TAP_BUMP=1
# opts out), so the version/sha256 below are NOT kept current. Read the tap.
cask "portside" do
  version "0.5.0"
  sha256 "REPLACE_WITH_RELEASE_ZIP_SHA256"

  url "https://github.com/mcglothi/portside/releases/download/v#{version}/Portside-#{version}.zip"
  name "Portside"
  desc "Native SSH session manager and terminal"
  homepage "https://github.com/mcglothi/portside"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Portside.app"

  zap trash: [
    "~/Library/Application Support/Portside",
    "~/Library/Caches/net.timmcg.portside",
    "~/Library/Preferences/net.timmcg.portside.plist",
  ]
end
