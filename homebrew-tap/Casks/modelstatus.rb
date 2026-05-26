cask "modelstatus" do
  version "0.2.0"
  sha256 "d4bf38c4f3611b19f98f2d9c444f61d698c37714d96e0698e14626c6d6014577"

  url "https://github.com/lucasmullikin/ModelStatus/releases/download/v#{version}/ModelStatus-v#{version}.zip"
  name "ModelStatus"
  desc "Menu bar monitor for Ollama, LM Studio, vLLM, and OpenAI-compatible servers"
  homepage "https://github.com/lucasmullikin/ModelStatus"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :ventura"

  app "ModelStatus.app"

  zap trash: [
    "~/Library/Preferences/com.lucrativepictures.ModelStatus.json",
    "~/Library/LaunchAgents/com.lucrativepictures.ModelStatus.plist",
  ]

  caveats <<~EOS
    ModelStatus is currently unsigned and un-notarized.
    First launch will be blocked by Gatekeeper.
    Run this once after install:

      xattr -dr com.apple.quarantine /Applications/ModelStatus.app

    To start at login:

      cp $(brew --prefix)/Caskroom/modelstatus/#{version}/LaunchAgent/com.lucrativepictures.ModelStatus.plist \\
         ~/Library/LaunchAgents/
      launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.lucrativepictures.ModelStatus.plist
  EOS
end
