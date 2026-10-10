cask "tuff" do
  version "8.2.0"
  sha256 "248a254ad68044b227aa74928c106f8f66e51fce9c0b13c450c539c12d29cf86"

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
