# Releasing Daisy

Daisy uses trunk development with a separate stable source line. Sparkle
channels decide who receives a build; git branches record the source that made
it.

- `main` is the active product line and normally ships beta builds.
- `stable` points to the source of the latest promoted stable build and is the
  base for stable hotfixes.
- `v<version>` tags map every published build to its app source.

The website repository owns the distribution state:

- `public/appcast.xml` is the Sparkle release history.
- `lib/latestVersion.ts` points the main download CTA to stable.
- `lib/betaVersion.ts` points opt-in users to the newest beta.
- `public/downloads/` keeps every referenced signed DMG.

`scripts/release.sh` finds daisy-web when it is the parent checkout or a
lowercase sibling. Set `DAISY_WEB_REPO=/absolute/path/to/daisy-web` for any
other layout. Read the current stable and beta versions from the generated
files above; do not duplicate those values in this document.

## 1. Cut a beta

Start from a clean, tested `main`. The build number must be greater than every
`sparkle:version` already in the appcast.

```sh
git switch main
DAISY_AUTO_PUSH=1 ./scripts/release.sh <version> <build> beta
git add Daisy.xcodeproj/project.pbxproj
git commit -m "<version> (b<build>)"
git push
git tag v<version>
git push origin v<version>
```

The script runs tests, archives, signs, notarizes, builds the DMG, publishes it
to daisy-web, injects the beta appcast item, updates `lib/betaVersion.ts`, and
commits the website. It never pushes the app repository.

After the archive it uploads the build's dSYMs to Sentry (project `daisy-mac`), so
crash reports people choose to send arrive symbolicated. It needs `sentry-cli`
(`brew install getsentry/tools/sentry-cli`) and an Organization Token in the
Keychain: service `daisy-sentry-auth-token`, account `sentry`. Without either it
prints a warning and the release goes on.

## 2. Promote a soaked beta to stable

Promotion reuses the already signed beta DMG; it does not rebuild it.

```sh
DAISY_AUTO_PUSH=1 ./scripts/release.sh promote <version>
git switch stable
git merge --ff-only v<version>
git push
git switch main
```

The command removes the beta channel tag from the existing appcast item,
updates `lib/latestVersion.ts` to the same artifact, and (with
`DAISY_AUTO_PUSH=1`) creates the GitHub Release `v<version>` with the DMG the
site serves. The beta's tag is already on GitHub, so the GitHub Release needs
no extra step.

## 3. Ship a stable hotfix

```sh
git switch stable
git switch -c hotfix/<short-description>
# implement and verify the fix
DAISY_AUTO_PUSH=1 ./scripts/release.sh <version> <build> stable
git switch stable
git merge --ff-only hotfix/<short-description>
git tag v<version>
git push origin stable v<version>
git switch main
./scripts/release.sh github-release <version>
git merge stable
```

Every stable version must also be a GitHub Release carrying the same DMG as
mydaisy.io — the site says so. `release.sh` tries it at the end of a stable
release, but the tag is usually not pushed yet then, so run
`github-release` once it is — always from `main`. Until `stable` contains
the 2026-10-07 `release.sh`, its older script reads `github-release <v>` as a
version and build and starts a full stable release. It uploads `daisy-web/public/downloads/Daisy-<version>.dmg`, never a
rebuild, marks it Latest only when it is the version the site's Download
button serves, and leaves an existing release alone. If a version is ever
republished with a new build under the same name, replace the asset by hand
(`gh release upload v<version> <dmg> --clobber`) so GitHub and the site still
match.

Always review both generated commits and verify the deployed download before
announcing a release. Keep all historical DMGs referenced by the appcast.
