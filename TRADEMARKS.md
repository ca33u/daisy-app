# Daisy's name, logo and icon

Daisy's code is open source under the GNU Affero General Public License, version 3 only (AGPL-3.0-only). Its name and its look are not part of that. The name "Daisy", the daisy mark, the app icon and the mydaisy.io domain say that an app comes from Daisy's author, Egor Sazanov (addicted), and the license does not let anyone else put them on their own work. The field photograph shown in What's New is not under that license either: all rights in it are reserved, and it travels only with unmodified copies of Daisy. The formal terms are in [`NOTICE.md`](./NOTICE.md); this page says the same in plain words.

The reason is simple: when someone installs an app called Daisy, it should be Daisy.

## What you can do without asking

- Say that your project is "based on Daisy" and link to <https://mydaisy.io> or to this repository. A modified version that you distribute has to say so anyway, among its legal notices.
- Refer to Daisy by name, truthfully: in a review, an article, a comparison, a talk, a tutorial, or a note that something works with Daisy.
- Share Daisy itself, unchanged, with its name, icon and logo in place.

## What you can't do

- Name a fork, or another app of its kind, "Daisy" or something close enough to be confused with it.
- Use the app icon, the daisy logo or the field photograph for a fork or another product: in the app, on its site, in a listing.
- Use mydaisy.io, or a domain that looks like it, for something that isn't Daisy.
- Suggest that Daisy's authors made, support or endorse your version.

## If you distribute a modified version

1. Give it its own name.
2. Replace the icon, the logo and the field photograph. The same files are named in [`NOTICE.md`](./NOTICE.md), under "The name and the brand artwork":
   - `Daisy/AppIcon.icon/` — the app icon (`icon.json` and `Assets/daisy-b-plus.svg`)
   - `Daisy/Assets.xcassets/DaisyMark.imageset/` — the daisy mark (`daisy_logo.svg`), used in the app and in the menu bar
   - `Daisy/Assets.xcassets/WhatsNewField.imageset/` — the field photograph shown in What's New (`daisy-field.jpg`)
   - `scripts/assets/dmg-background.svg`, `dmg-background.png` and `dmg-background@2x.png` — the installer background, which carries the mark
   - the places where the mark is drawn in code: the petal shape in `Daisy/DaisyWidget.swift`, the sign-in page in `Daisy/GoogleOAuthClient.swift`
3. Keep Daisy's author attribution, with the link to Daisy's source code, wherever your version shows its legal notices, as "Based on Daisy (https://mydaisy.io) by Egor Sazanov, addicted" or words to that effect.
4. Change the bundle identifier (`app.essazanov.Daisy`), the update feed and its key (`SUFeedURL` and `SUPublicEDKey` in `Info.plist`) and the crash-report DSN (`Daisy/CrashReports.swift`). Daisy's update feed and crash-report service are run for Daisy and are not something the license covers: point your version at its own.

The rest of what the license asks of a modified version is in [`LICENSE`](./LICENSE) and [`NOTICE.md`](./NOTICE.md).

## Questions

If you aren't sure whether a use is fine, or want to do something this page doesn't cover, write to <hello@mydaisy.io>.
