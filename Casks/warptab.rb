cask "warptab" do
  version "1.1.0"
  sha256 "c37eaa382668dcfcf938aa17e70c88fd233beaa4b318f8053f595b36bd943038"

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
