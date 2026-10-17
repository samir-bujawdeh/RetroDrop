# dmgbuild settings for RetroDrop's disk image. Used by scripts/build.sh:
#   dmgbuild -s scripts/dmg-settings.py -D app=build/RetroDrop.app "RetroDrop" dist/RetroDrop.dmg
import os.path

app = defines.get("app", "build/RetroDrop.app")  # noqa: F821 (provided by dmgbuild)
appname = os.path.basename(app)

format = "UDZO"  # compressed, read-only
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = "Resources/AppIcon.icns"  # volume icon shown on the desktop while mounted

# Window: matches scripts/make-dmg-background.swift
background = "Resources/dmg-background.tiff"
window_rect = ((200, 120), (600, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {
    appname: (150, 200),
    "Applications": (450, 200),
}
