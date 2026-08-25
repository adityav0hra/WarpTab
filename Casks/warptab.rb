cask "warptab" do
  version "2.0.0-beta.2"
  sha256 "7ab46e74c379298c94611292a74a15b6cab713ab3b45c4dd2bf0497e61827015"

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
