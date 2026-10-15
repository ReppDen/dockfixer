#!/bin/bash
#
# Writes the Homebrew cask for one release, for ReppDen/homebrew-tap.
#
#   Scripts/cask.sh <version> <sha256> > Casks/dockfixer.rb
#
# `auto_updates true` because the app updates itself through Sparkle: Homebrew
# then leaves an installed copy alone on `brew upgrade` (unless --greedy) rather
# than fighting the updater over which version is current.
set -euo pipefail

VERSION="$1"
SHA="$2"

cat <<EOF
cask "dockfixer" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/ReppDen/dockfixer/releases/download/v#{version}/DockFixer-#{version}.zip"
  name "DockFixer"
  desc "Keeps windows away from the Dock"
  homepage "https://github.com/ReppDen/dockfixer"

  livecheck do
    url "https://github.com/ReppDen/dockfixer/releases/latest/download/appcast.xml"
    strategy :sparkle
  end

  auto_updates true
  depends_on macos: :sonoma

  app "DockFixer.app"

  # The app is signed with a self-signed certificate and not notarised, so
  # Gatekeeper refuses a quarantined copy. Updates arrive through Sparkle,
  # which does not quarantine what it installs.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/DockFixer.app"]
  end

  uninstall quit: "com.github.reppden.dockfixer"

  zap trash: [
    "~/Library/Application Support/DockFixer",
    "~/Library/Caches/com.github.reppden.dockfixer",
    "~/Library/HTTPStorages/com.github.reppden.dockfixer",
    "~/Library/Logs/DockFixer",
    "~/Library/Preferences/com.github.reppden.dockfixer.plist",
  ]
end
EOF
