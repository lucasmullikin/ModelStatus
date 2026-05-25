# homebrew-tap

A Homebrew tap for [ModelStatus](https://github.com/lucasmullikin/ModelStatus) and other Lucrative Pictures tools.

## Install

```bash
brew tap lucasmullikin/tap
brew install --cask modelstatus
```

That installs `ModelStatus.app` into `/Applications`. Because the binary is currently unsigned, run once after install:

```bash
xattr -dr com.apple.quarantine /Applications/ModelStatus.app
```

Then launch from Spotlight or `open /Applications/ModelStatus.app`.

## Updating

```bash
brew update
brew upgrade --cask modelstatus
```

## Uninstall

```bash
brew uninstall --cask modelstatus
```

The cask’s `zap` stanza removes the JSON config and the LaunchAgent on `brew uninstall --zap modelstatus`.

## Publishing a new version

This tap is **separate from the homebrew/cask official tap**. To publish:

1. Tag a release in `lucasmullikin/ModelStatus` (e.g., `v3.0.1`). The release workflow attaches `ModelStatus-v3.0.1.zip` + `.sha256`.
2. Update `Casks/modelstatus.rb` here:
   - Bump `version`
   - Update `sha256` to the real value (replace `:no_check`)
3. Commit + push.
4. Users run `brew upgrade --cask modelstatus`.

## Notes

- The cask currently uses `sha256 :no_check` for the first release because the artifact hash isn’t known at tap-creation time. Replace it with the real hash after v3.0.0 is uploaded.
- Once the app is notarized (when an Apple Developer ID is in place), the `caveats` block telling users to `xattr -dr` can be removed and we can apply to submit ModelStatus to the official `homebrew/cask` tap for one-step `brew install --cask modelstatus`.
