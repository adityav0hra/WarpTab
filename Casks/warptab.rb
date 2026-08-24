cask "warptab" do
  version "1.0.0"
  sha256 "128808b7e6c783f96831e60850e227b4127b834895406dc4826decae86dc3240"

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
