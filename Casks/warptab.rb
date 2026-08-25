cask "warptab" do
  version "1.1.1"
  sha256 "6159ae04602f85c9d49ff2bfcaf2c8890605e8f48d84e1795d7b3329bdfff911"

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
