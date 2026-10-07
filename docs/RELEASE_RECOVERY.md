# Release withdrawal and recovery

A recovery release restores known-good runtime code with a **newer version**.
Sparkle does not install an ordinary downgrade. Existing update preferences
still apply. Tags and published archives are never moved, deleted or replaced.

## If TUFF will not open

1. Quit the defective TUFF process if it is running. Disable its Background API
   in System Settings > General > Login Items if the listener also has a problem.
2. Keep `~/Library/Application Support/TUFF`. It holds chats, settings and models.
   Make a backup before changing applications. Do not erase that directory or
   replace its contents with data from an older installation.
3. Read the notice on [TUFF releases](https://github.com/rexmhall09/TUFF/releases).
   Download the newer recovery release and its checksum. Check the archive with
   `shasum -a 256 -c TUFF-vVERSION-macos-arm64.zip.sha256` in the download directory.
4. Extract the recovery app, then replace the defective app in your usual app
   location. Keep a copy of the defective app until recovery is verified.
5. If the recovery cannot read the data version on this Mac, leave the data
   untouched and report the version mismatch. A manual older-app installation
   bypasses the newer app's recovery gate, so it is not a safe substitute.

If TUFF opens, use **TUFF > Check for Recovery Update**. The first check only
looks for a recovery. Installation uses **Check for Updates** and Sparkle's
normal signed update process. No recovery available, offline and invalid-feed
results are reported without changing the app or local data.

## Maintainer withdrawal

Inspect the plan first:

```sh
python3 Scripts/release_recovery.py withdraw --withdrawn 7.0.0 --known-good 6.1.0
```

After authorization, add `--apply`. The destination feed must verify against
the client public key. A newer known-good recovery release can be selected.
The public 6.1.0 feed is unsigned. Selecting it requires the explicit
`--allow-unsigned-legacy-feed` flag for a temporary withdrawal: 7.0.0 clients
fail closed with a feed-signature error until a newer signed recovery is
published. Do not disable signature verification or overwrite legacy assets.
The workflow intentionally refuses unsigned destinations. The script marks the defective published
release as a prerelease, clears its latest status, adds a withdrawal notice to
its existing notes, and makes the stable known-good release latest. It never
removes tags or assets. Existing download URLs remain available for provenance.
The manual **Withdraw defective release** workflow runs the same command. Never
exercise it against a real release as a test.

Changing latest stops new feed checks from selecting the defective feed. It
cannot revoke a downloaded archive or prevent an already-running old updater
from completing. Publish a newer recovery promptly and warn affected users.
Clients with cached updates may need to quit and use the manual path above.

Homebrew uses the version and checksum pinned in `Casks/tuff.rb`, separately
from GitHub's latest-release flag and the Sparkle feed. Withdrawing a release
does not change that pin. Update the cask promptly so new installations do not
fetch the withdrawn build. Prefer publishing a newer, validated recovery and
pinning its ZIP with `Scripts/update_homebrew.py`; an older app may not read
newer chats or settings, and a Homebrew downgrade bypasses TUFF's recovery
gate. Verify both installation routes after a recovery release.

## Prepare a recovery locally

Start from a clean checkout. Select the explicit ancestor commit whose runtime
is known to work, determine the data versions it can read, and describe the
regression and restored behavior:

```sh
python3 Scripts/release_recovery.py prepare \
  --known-good GOOD_COMMIT --withdrawn 7.0.0 --version 7.0.1 \
  --reason 'Describe the regression and the behavior restored.' \
  --chats-schema 2 --app-settings 7 --background-settings 1
```

The default prints provenance. `--apply` creates normal revert commits, newest
first, and a recovery preparation commit. Merge commits use their first parent.
A conflict stops preparation for human resolution. Recovery transport and
settings-preservation files are retained and listed in provenance; review them
separately from the restored runtime. No push, tag or release happens here.

Review and qualify the resulting source. Earlier known-good source may need
small build or version integrations. Do not publish a mechanically reverted
tree just because preparation completed. Require all model-free checks,
packaging, applicable real-model checks, and local diff review.

The preparation commit writes release notes and `RELEASE_VERSION_RECOVERY.json`.
This JSON records the known-good commit, reverted commits, retained recovery
files, affected version, recovery version and supported data formats. Publish
it as `recovery-provenance.json` alongside the newer archive and signed feed.

## Signed feed and data gate

Packaged TUFF requires `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction`.
The appcast script embeds notes, adds the `tuff` namespace, and signs the final
XML after adding metadata. Recovery items carry `tuff:recovery`,
`tuff:withdrawnVersion`, `tuff:knownGoodCommit`, `tuff:chatsSchema`,
`tuff:appSettingsVersion` and `tuff:backgroundSettingsVersion`. Current formats
are chat schema 3, app settings 7 and background settings 1. A chat archive
without tool rounds, sources or search settings is still written as schema 2.

```sh
Scripts/package_app.sh 7.0.1 dist/v7.0.1
Scripts/generate_update_appcast.sh 7.0.1 dist/v7.0.1 \
  --recovery-provenance docs/RELEASE_7.0.1_RECOVERY.json
```

Production signing reads the TUFF Ed25519 key from the maintainer's keychain.
Only the owner can approve that prompt. Fixtures instead pass `--ed-key-file`
with an ephemeral key and use isolated bundles. Never use the production key
or installed app for fixture testing.

The updater delegate and standard user driver reject a recovery with missing format metadata, newer
local formats or unreadable local version stamps. No data is rewritten to make
an update fit. Settings saves also refuse to overwrite a newer on-disk file.
Resumed updates and the install choice are checked again. Every recovery target
must support the formats the running app can write, because a staged installation
may wait until quit. Normal signing and update preferences remain active.
