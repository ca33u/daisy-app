# SPDX-License-Identifier: AGPL-3.0-only
# Copyright © 2026 Egor Sazanov, addicted. Additional terms: NOTICE.md
# dmgbuild settings — Daisy installer disk image
#
# Used by scripts/release.sh step [4/6] in place of `create-dmg` because
# create-dmg's AppleScript step silently fails on macOS Sequoia/Tahoe
# in the sub-step that writes the BkPa/pict background-picture alias
# into .DS_Store. The result: TIFF lands in .background/ correctly, but
# the Finder window opens in default view with no branded image.
#
# dmgbuild writes .DS_Store programmatically via the `ds_store` Python
# library — no AppleScript, no Finder, deterministic across macOS
# versions.
#
# Invocation:
#   dmgbuild \
#     -s scripts/dmgbuild_settings.py \
#     -D app_path=/abs/path/to/Daisy.app \
#     -D background=/abs/path/to/dmg-background.tiff \
#     "Daisy 1.0.1" \
#     build/Daisy-1.0.1.dmg
#
# Code-signing of the .dmg is done separately in release.sh after this
# step (dmgbuild doesn't sign).

import os

# ----------------------------------------------------------------------
# macOS Tahoe 26.2 workaround — emit Bookmark instead of Carbon Alias
# for icvp.backgroundImageAlias.
#
# dmgbuild 1.6.x calls mac_alias.Alias.for_file() to build the
# .DS_Store icvp.backgroundImageAlias field. That produces a ~338-byte
# legacy Carbon Alias (Alias Manager v2). Finder on macOS 26.2 silently
# ignores that format and shows the default empty background instead
# of the branded TIFF — even though .DS_Store is read for Iloc/bwsp.
#
# mac_alias.Bookmark.for_file() is already shipped alongside Alias and
# emits a modern BookmarkData blob (`book` magic, 600–1000+ bytes) that
# Finder still accepts. We monkey-patch dmgbuild.core.Alias so its
# .for_file() and .to_bytes() return Bookmark bytes instead, without
# touching the dmgbuild package source. Survives `pip install
# --upgrade dmgbuild`.
#
# Confirmed against:
#   - Plover #1804 (same symptom, fixed in 5.2.3)
#   - dmgbuild/core.py:653 — only call site of Alias.for_file()
#     for backgroundImageAlias
# ----------------------------------------------------------------------
import dmgbuild.core
from mac_alias import Bookmark

class _BookmarkShim:
    @classmethod
    def for_file(cls, path):
        bmk = Bookmark.for_file(path)
        class _Wrapped:
            def to_bytes(self_inner):
                return bmk.to_bytes()
        return _Wrapped()

dmgbuild.core.Alias = _BookmarkShim
# ----------------------------------------------------------------------

# ----------------------------------------------------------------------
# Defines passed via `-D key=value` on the dmgbuild command line.
# ----------------------------------------------------------------------
app_path   = defines.get("app_path")
background = defines.get("background")  # optional — may be None
if not app_path or not os.path.exists(app_path):
    raise SystemExit(
        f"dmgbuild_settings: app_path missing or doesn't exist: {app_path!r}"
    )

app_name = os.path.basename(app_path)

# ----------------------------------------------------------------------
# Disk-image basics.
# ----------------------------------------------------------------------
format            = "UDZO"   # compressed read-only
compression_level = 9

# Volume size is auto-computed by dmgbuild from the file list.
size = None

# What lives at the root of the mounted volume.
files    = [app_path]
symlinks = {"Applications": "/Applications"}

# Hide the .app extension in Finder.
hide_extension = [app_name]

# ----------------------------------------------------------------------
# Finder window layout.
# Matches the previous create-dmg invocation:
#   --window-pos 200 120
#   --window-size 540 360
#   --icon-size 100
#   --icon "Daisy.app" 150 180
#   --app-drop-link 390 180
# ----------------------------------------------------------------------
window_rect = ((200, 120), (540, 360))
icon_size   = 100
text_size   = 12

icon_locations = {
    app_name:       (150, 180),
    "Applications": (390, 180),
}

default_view     = "icon-view"
show_status_bar  = False
show_tab_view    = False
show_toolbar     = False
show_pathbar     = False
show_sidebar     = False
sidebar_width    = 180

# Optional background TIFF (multi-resolution, built by tiffutil in
# release.sh from dmg-background.png + dmg-background@2x.png).
if background and os.path.exists(background):
    # dmgbuild copies this into .background/ inside the DMG and records
    # the proper BkPa/pict alias in .DS_Store.
    pass  # `background` is read directly from the global namespace below
else:
    background = None
