# Notice

Daisy for Mac

Copyright © 2026 Egor Sazanov, addicted

## License

Daisy is free software. You can redistribute it and modify it under the terms of the GNU Affero General Public License, version 3 only (SPDX: `AGPL-3.0-only`), as published by the Free Software Foundation, together with the additional terms and the additional permission below. Later versions of that license do not apply.

Daisy is distributed in the hope that it will be useful, but without any warranty; without even the implied warranty of merchantability or fitness for a particular purpose. The full text of the license, including the warranty disclaimer, is in [`LICENSE`](./LICENSE).

Unless a file says otherwise, every file in this repository is under these terms. Source files carry an SPDX line (`SPDX-License-Identifier: AGPL-3.0-only`).

## Additional terms under section 7 of the license

These terms supplement the license for the material in this repository whose copyright Egor Sazanov holds. Each is of a kind that section 7 of the license permits. They add no limit on selling or on the purposes Daisy may be used for. They apply when you convey a modified version or let other people use one over a network, not to changes you keep to yourself.

1. **Attribution — section 7(b).** Daisy shows this author attribution among its legal notices (the About window): "Daisy (https://mydaisy.io) by Egor Sazanov, addicted", with a link to its source code (<https://github.com/addicted-studio/daisy-app>). A modified version must preserve it, with that link, wherever it shows its legal notices, as "Based on Daisy (https://mydaisy.io) by Egor Sazanov, addicted" or words to that effect.

2. **Origin — section 7(c), and section 7(d) for endorsement.** A modified version must be marked as different from the original. It must not be presented as Daisy, or as made or endorsed by Daisy's authors, and their names may not be used to promote it beyond the attribution in term 1.

3. **Trademarks — section 7(e).** The license grants no rights under trademark law to the name "Daisy", the daisy mark, the app icon or the mydaisy.io domain. Stating truthfully that something is based on Daisy, or referring to Daisy by name, needs no such right. [`TRADEMARKS.md`](./TRADEMARKS.md) says this in plain words.

## Additional permission under section 7 of the license

Daisy links the Sentry Cocoa SDK for crash reports, and that SDK includes Apple-originated code under the Apple Public Source License 2.0 (listed in [`Daisy/Acknowledgements.txt`](./Daisy/Acknowledgements.txt)), so this permission is added:

> Additional permission under GNU AGPL version 3 section 7: if you modify this program, or any covered work, by linking or combining it with the Sentry Cocoa SDK (or a modified version of that library), which contains parts covered by the Apple Public Source License 2.0, the licensors of this program grant you additional permission to convey the resulting work.

## The name and the brand artwork

The name "Daisy" is handled as a trademark only: term 3 above.

The brand artwork — the app icon and the daisy logo, in the files below — is © Egor Sazanov, all rights reserved, and is not licensed under AGPL-3.0-only. These files are separate works shipped alongside the program, not part of the Program the license covers. They may be copied and distributed only in unmodified copies of Daisy, as source or as an app built from it unchanged, and in versions you change for your own use. A modified version that is distributed needs an icon and a logo of its own.

- `Daisy/AppIcon.icon/` — the app icon (`icon.json` and `Assets/daisy-b-plus.svg`)
- `Daisy/Assets.xcassets/DaisyMark.imageset/` — the daisy mark (`daisy_logo.svg`), used in the app and in the menu bar
- `scripts/assets/dmg-background.svg`, `dmg-background.png` and `dmg-background@2x.png` — the installer background, which carries the mark

Copies of these files published under the Apache License 2.0, in the commits named under History below, keep the terms they were published under. That license does not grant permission to use the licensor's names or marks, except to describe where the work comes from (its section 6).

The mark is also drawn in code in a few places (the petal shape in `Daisy/DaisyWidget.swift`, the sign-in page in `Daisy/GoogleOAuthClient.swift`). That code is under AGPL-3.0-only like the rest of the source, but term 3 applies to the mark it draws: the license gives no right to use it as the mark of a modified version.

## History

Every commit from [`310141b`](https://github.com/addicted-studio/daisy-app/commit/310141b287e9fca3cb5a00ef6473e5ecf869b049) (22 May 2026) up to and including [`94a45d1`](https://github.com/addicted-studio/daisy-app/commit/94a45d1bdbbcaadece1b2f14d30f11b8a0da1222) (28 November 2026), and every release built from them up to and including 1.0.8.59, was published under the Apache License 2.0 and remains available under it. Its text is the [`LICENSE` file at `94a45d1`](https://github.com/addicted-studio/daisy-app/blob/94a45d1bdbbcaadece1b2f14d30f11b8a0da1222/LICENSE). This notice does not change the terms that commits before `310141b` were published under. The license of any commit is the one in its own LICENSE file.

Everything after `94a45d1` is under AGPL-3.0-only with the terms in this file, except the brand artwork named above.

## Commercial license

For a company that cannot take the terms of AGPL-3.0-only, a separate commercial license can be arranged with the author. Write to <hello@mydaisy.io>.

## Third-party components and models

The libraries Daisy links keep their own licenses. Their texts and notices ship inside the app as [`Daisy/Acknowledgements.txt`](./Daisy/Acknowledgements.txt). The speech and summary models Daisy downloads are data under their authors' own terms, listed at <https://mydaisy.io/licenses>.
