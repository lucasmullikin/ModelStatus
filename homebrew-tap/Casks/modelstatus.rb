cask "modelstatus" do
  version "0.1.1-beta"
  sha256 "be52fa028d1c0085e1a588515aedc67059da41c789f4971975e6361878df7869"

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
