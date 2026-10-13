cask "tuff" do
  version "9.0.0"
  sha256 "c81a7f952960d64fbf38c1267893c29d45ceac2248d99ee1ac308fc07baa8801"

  url "https://github.com/rexmhall09/TUFF/releases/download/v#{version}/TUFF-v#{version}-macos-arm64.zip"
  name "TUFF"
  desc "Run local language models, including ones bigger than your memory"
  homepage "https://rexmhall09.github.io/TUFF/"

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "TUFF.app"
  binary "#{appdir}/TUFF.app/Contents/Resources/bin/tuff"

  caveats <<~EOS
    TUFF is ad-hoc signed and not notarized. macOS may require approval in
    System Settings > Privacy & Security before its first launch.
    Model weights are downloaded separately in the app.
  EOS
end
