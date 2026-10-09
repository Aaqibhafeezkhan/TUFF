# If an update breaks TUFF

A broken release gets fixed by a newer **recovery** release, never by
installing an older version. Your chats, settings and models stay put.

## If TUFF won't open

1. Quit TUFF if it's running. If the Background API is misbehaving too, turn
   TUFF off in System Settings > General > Login Items.
2. Leave `~/Library/Application Support/TUFF` alone. It holds your chats,
   settings and models. Back it up if you like, but don't delete it or copy
   an older version over it.
3. Check the [releases page](https://github.com/rexmhall09/TUFF/releases) for
   the recovery release, download it, and check it with
   `shasum -a 256 -c TUFF-vVERSION-macos-arm64.zip.sha256`.
4. Replace the broken app with the recovery one.
5. If the recovery can't read your data, leave the data as it is and
   [open a bug](https://github.com/rexmhall09/TUFF/issues/new?template=bug.yml).
   Don't install an older app to get around it.

If TUFF still opens, **TUFF > Check for Recovery Update** does this for you.

## For maintainers

**Withdraw a release.** Inspect first, then add `--apply`:

```sh
python3 Scripts/release_recovery.py withdraw --withdrawn 8.1.0 --known-good 8.0.2
```

This marks the bad release as a prerelease, makes the known-good one latest,
and adds a notice. It never deletes tags or assets. The **Withdraw defective
release** workflow runs the same thing; never test it on a real release.
Withdrawing doesn't change the Homebrew cask, so update `Casks/tuff.rb` too.

**Prepare a recovery** from a clean checkout:

```sh
python3 Scripts/release_recovery.py prepare \
  --known-good GOOD_COMMIT --withdrawn 8.1.0 --version 8.1.1 \
  --reason 'What broke and what this restores.' \
  --chats-schema 3 --app-settings 7 --background-settings 1
```

`--apply` makes revert commits and writes `RELEASE_VERSION_RECOVERY.json`.
Review and test the result like any release; a clean revert isn't proof it
works. Publish the JSON as `recovery-provenance.json` with the archive.

**Sign the feed:**

```sh
Scripts/package_app.sh 8.1.1 dist/v8.1.1
Scripts/generate_update_appcast.sh 8.1.1 dist/v8.1.1 \
  --recovery-provenance RELEASE_8.1.1_RECOVERY.json
```

Signing uses the Ed25519 key in the owner's keychain. The updater refuses a
recovery that can't read the user's current data formats (chat schema 3, app
settings 7, background settings 1), and nothing is rewritten to make an
update fit.
