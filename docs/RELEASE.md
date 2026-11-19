# Release

Shimmer uses semantic versioning, starting at 1.0.0. Releases are tagged
`vMAJOR.MINOR.PATCH` on `main`. The version lives only in
`Glimmer/Version.xcconfig`: `MARKETING_VERSION` is the version people see, and
`CURRENT_PROJECT_VERSION` is a build number that only goes up (a `YYYYMMDD`
stamp). Sparkle orders updates by the build number.

Remotes: `shimmer` is this repository; `origin` is upstream glimmer, and pushing
to it is disabled. Every script here uses `shimmer`.

## Cutting a release

1. Write the `## <version>` section of `CHANGELOG.md`. It becomes the GitHub
   release notes and the "what's new" text in Sparkle's update window.
2. Bump both lines of `Glimmer/Version.xcconfig`, commit, and push `main`.
3. Run `make release-publish`. In order, it:
   - builds Release from a clean tree, signs it with Developer ID, and embeds
     the dylibs;
   - notarizes and staples the app, then builds the DMG;
   - zips the app and signs the ZIP with Shimmer's Sparkle key;
   - creates the GitHub release `v<version>` with the DMG, the ZIP and
     `SHA256SUMS.txt`;
   - adds the update to `appcast.xml` on `main`.

   Installed copies find the update at their next check.

`make dist` stops after the DMG, so you can inspect it before publishing. Set
`SHIMMER_DRAFT=1` to publish the GitHub release as a draft.

Before publishing, check the DMG on a Mac that has never run a development
build:

```sh
spctl -a -vv -t install build.noindex/dist/Shimmer-*.dmg
xcrun stapler validate build.noindex/dist/Shimmer-*.dmg
```

## One-time setup

Secrets live in `~/.config/shimmer/signing.env` (mode 0600, outside the repo).
`scripts/signing-creds.sh` is the only thing that reads or writes it.

- `make creds-init` writes the template.
- `make codesign-setup` imports the Developer ID Application certificate into a
  dedicated signing keychain.
- `make setup-notary` stores the notarytool profile (Apple ID, team ID and an
  app-specific password).
- `make sparkle-keys` creates the EdDSA update key (keychain account `shimmer`)
  and prints the public half for `SUPublicEDKey` in `Glimmer/Info.plist`.

Back up the Sparkle private key. If it is lost, installed copies can't verify
any later update. If it leaks, someone else could sign one.

`TAP_REPO` turns on the Homebrew cask bump (`scripts/homebrew-bump.sh`) once a
tap exists. It is empty for now.
