# Cask for the personal tap (github.com/mcglothi/homebrew-tap, Casks/portside.rb).
# Users install with:  brew install mcglothi/tap/portside
#
# On each release, update `version` and `sha256`:
#   shasum -a 256 build/updates/Portside-<version>.zip
# (Or automate the bump in Scripts/release.sh once the tap exists.)
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
