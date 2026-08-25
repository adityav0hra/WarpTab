cask "warptab" do
  version "1.1.1"
  sha256 "89659f75b4d5026e7ec1700db5a8bf769e8ca9a0931737194380a84396cafb24"

  url "https://github.com/adityav0hra/WarpTab/releases/download/v#{version}/WarpTab-#{version}.zip"
  name "WarpTab"
  desc "Switch between individual application windows"
  homepage "https://github.com/adityav0hra/WarpTab"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "WarpTab.app"

  uninstall launchctl: "com.warptab.launch-at-login",
            quit:      "com.warptab.app",
            delete:    "~/Library/LaunchAgents/com.warptab.launch-at-login.plist"

  zap trash: "~/Library/Preferences/com.warptab.app.plist"
end
