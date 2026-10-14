# dmgbuild settings for Pulse's DMG — packaging-time only, never shipped.
#
# PulseBar/Scripts/package.sh runs:
#
#   dmgbuild -s PulseBar/Packaging/DMG/settings.py \
#     -D app=<Pulse.app> -D layout=<layout.json> -D background=<background.png> \
#     -D icon=<AppIcon.icns> [-D guide=<first-open .txt>] Pulse <out.dmg>
#
# The geometry comes from layout.json, which scripts/make_dmg_art.py writes
# with the background it drew; nothing here restates a coordinate.
# dmgbuild executes this file with `defines` in scope. It writes the window
# settings straight into .DS_Store (ds_store / mac_alias) — no Finder,
# no AppleScript — so it works on a headless CI runner.
import json
import os.path

_layout = json.load(open(defines["layout"], encoding="utf-8"))  # noqa: F821
_app = defines["app"]  # noqa: F821
_guide = defines.get("guide") or None  # noqa: F821
_pos = _layout["positions"]
_win = _layout["window"]

files = [_app]
symlinks = {"Applications": "/Applications"}
icon_locations = {
    os.path.basename(_app): tuple(_pos["Pulse.app"]),
    "Applications": tuple(_pos["Applications"]),
}
hide_extensions = [os.path.basename(_app)]
if _guide:
    files.append(_guide)
    icon_locations[os.path.basename(_guide)] = tuple(_pos["guide"])
    hide_extensions.append(os.path.basename(_guide))

format = "UDZO"
compression_level = 9
filesystem = "HFS+"

icon = defines.get("icon") or None  # noqa: F821
background = defines.get("background") or None  # noqa: F821

default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
show_item_info = False
include_list_view_settings = False
arrange_by = None
label_pos = "bottom"
icon_size = _layout["icon_size"]
text_size = _layout["text_size"]

# WindowBounds is the window frame, title bar included: add it on top of the
# picture. Without a guide (a notarized build) the window stops above the
# guide's band — the background is anchored top-left, so it is just cut off.
_TITLE_BAR = 28
_height = _win["height"] if _guide else _win["compact_height"]
window_rect = ((200, 120), (_win["width"], _height + _TITLE_BAR))
