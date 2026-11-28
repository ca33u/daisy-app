# Releasing Daisy

Daisy uses trunk development with a separate stable source line. Sparkle
channels decide who receives a build; git branches record the source that made
it.

- `main` is the active product line and normally ships beta builds.
- `stable` points to the source of the latest promoted stable build and is the
  base for stable hotfixes.
- `v<version>` tags map every published build to its app source. The tag is
  public before the build is: the appcast notes, the site's Download buttons
  and the GitHub Release all say «Source for this version:
  github.com/addicted-studio/daisy-app/tree/v<version>» (AGPL section 6: a
  build offered for download comes with its source).

The website repository owns the distribution state:

- `public/appcast.xml` is the Sparkle release history.
- `lib/latestVersion.ts` points the main download CTA to stable.
- `lib/betaVersion.ts` points opt-in users to the newest beta.

The signed DMGs are not in git. Each build is an object in Cloudflare R2,
`downloads/<build>/Daisy-<version>.dmg`, never overwritten; the appcast and the
site reach it as `mydaisy.io/downloads/…`, which daisy-web redirects to R2.

`scripts/release.sh` finds daisy-web when it is the parent checkout or a
lowercase sibling. Set `DAISY_WEB_REPO=/absolute/path/to/daisy-web` for any
other layout. Read the current stable and beta versions from the generated
files above; do not duplicate those values in this document.

## 1. Cut a beta

Start from a clean, tested `main`, with everything that goes into the build
committed. The build number must be greater than every `sparkle:version`
already in the appcast.

```sh
git switch main
DAISY_AUTO_PUSH=1 ./scripts/release.sh <version> <build> beta
git push origin main
```

The script runs tests, archives, signs, notarizes, builds the DMG, uploads it
to R2, injects the beta appcast item, updates `lib/betaVersion.ts`, and commits
those files in daisy-web.

Then, in this order:

1. In the app repository it commits the `project.pbxproj` bump as
   `<version> (b<build>)`, tags that commit `v<version>` and pushes the tag,
   and only the tag.
2. With the tag on GitHub, it pushes daisy-web's `main`, which deploys the
   site: the source link works the moment the appcast and the site show it.

It never pushes a branch of the app repository. `git push origin main`
afterwards publishes the branch; the closing summary reminds of it. The line
«Source for this version: …» in the notes and the GitHub Release is generated
from the version, so don't write it into `scripts/release-notes/`.

### What step 0 refuses (exit status 1, nothing built)

- With `DAISY_AUTO_PUSH=1`: changes in the app repository that are in no commit.
  Untracked files count, because Xcode builds them; dot-folders and
  `project.pbxproj` do not. Without `DAISY_AUTO_PUSH` this is a warning, and
  the commands that commit and tag are printed at the end.
- With `DAISY_AUTO_PUSH=1`: a `v<version>` already on GitHub that names other
  code than `HEAD`. A tag is never moved; a changed build needs its own version
  number. The same code may be released again under the tag with a new build.
- A daisy-web checkout that is not on `main`, or is ahead of or behind
  `origin/main`. That checkout is shared with other sessions and a push to its
  `main` is a deploy, so the release adds one commit, its own, and pushes that
  alone. Uncommitted files of other sessions are fine: the release commit names
  its files (`public/appcast.xml`, `lib/latestVersion.ts`, `lib/betaVersion.ts`)
  and touches nothing else.

### When the site push is held (exit status 2)

The script ends with «NOT published» and status 2 when the DMG is uploaded and
the daisy-web commit is made, but the push did not happen. Nothing a user sees
has changed. It prints the commands for the case; they are:

| What happened | To finish |
|---|---|
| `HEAD` moved during the build, or the tree changed during it | `git tag v<version> <commit the archive was made from>`, `git push origin v<version>`, then `git push origin main` in daisy-web. If the changes were built, no commit is the source: release again from a clean tree |
| The build held uncommitted changes (a run without `DAISY_AUTO_PUSH`) | commit them with the `project.pbxproj` bump as `<version> (b<build>)`, `git tag v<version>`, `git push origin v<version>`, then `git push origin main` in daisy-web |
| The tag was made but its push failed | `git push origin v<version>`, then `git push origin main` in daisy-web |
| A local `v<version>` names other code | if it is a leftover: `git tag -d v<version>`, `git tag v<version> <commit the archive was made from>`, push the tag, then daisy-web |
| `v<version>` on GitHub names other code (it appeared during the build) | nothing publishes this build under this version; take the daisy-web commit back as printed and release under a new version number |
| Another commit is ahead of `origin/main` in daisy-web | the script names it; `git push origin main` once it may go out with the release, or after its author has moved it |
| GitHub refused the daisy-web push, or `origin/main` moved during the build | `git pull --rebase --autostash`, then `git push origin main`, both in daisy-web |

A run without `DAISY_AUTO_PUSH` pushes nothing: it makes the tag and the
daisy-web commit locally, prints the same commands in order (tag first, then
the site) and ends with status 0.

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
git push origin stable
git switch main
```

The command removes the beta channel tag from the existing appcast item,
updates `lib/latestVersion.ts` to the same artifact, commits those two files in
daisy-web and pushes its `main`, and (with `DAISY_AUTO_PUSH=1`) creates the
GitHub Release `v<version>` with the DMG the site serves. The beta's tag is
already on GitHub, so the GitHub Release needs no extra step.

The daisy-web checkout has to be on `main` and level with `origin/main`, as in
section 1. If `v<version>` is not on GitHub, the script leaves the website
commit unpushed, prints the commands (push the tag, then daisy-web) and ends
with status 2: the main Download button would link to source that isn't
published.

## 3. Ship a stable hotfix

Cut `hotfix/<short-description>` from `stable`, implement, verify and commit
the fix there, then:

```sh
DAISY_AUTO_PUSH=1 ./scripts/release.sh <version> <build> stable
git switch stable
git merge --ff-only hotfix/<short-description>
git push origin stable
git switch main
git merge stable
```

The script tags and pushes `v<version>` here too (section 1), from the hotfix
branch; the fast-forward puts `stable` on the same commit. A hotfix branch
runs the `release.sh` it contains: until `stable` has the 2026-11-28 script,
take it from `main` first (`git checkout main -- scripts/release.sh`, commit),
or the tag is not pushed before the site and the notes carry no source line.

Every stable version must also be a GitHub Release carrying the same DMG as
mydaisy.io — the site says so. `release.sh` creates it at the end of a stable
release, with the tag already on GitHub. If the site push was held (status 2),
run `./scripts/release.sh github-release <version>` after finishing it —
always from `main` (a `release.sh` older than 2026-10-07 reads
`github-release <v>` as a version and build and starts a full release). It takes the DMG from R2 at the appcast item's build,
never a rebuild, marks it Latest only when it is the version the site's
Download button serves, and leaves an existing release alone. If a version is
ever republished with a new build under the same name, replace the asset by
hand (`gh release upload v<version> <dmg> --clobber`) so GitHub and the site
still match.

Always review both generated commits and verify the deployed download before
announcing a release. Keep every historical DMG the appcast references in R2.
