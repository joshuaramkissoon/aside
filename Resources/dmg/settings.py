# dmgbuild settings for the Aside installer window (scripts/release.sh passes -D app=… -D bg=…).
import os

app = defines["app"]          # noqa: F821 (provided by dmgbuild)
format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
background = defines["bg"]    # noqa: F821
window_rect = ((200, 160), (660, 472))  # 420 of background + Finder title and status bars
icon_size = 112
text_size = 13
show_status_bar = show_tab_view = show_toolbar = show_pathbar = show_sidebar = False
default_view = "icon-view"
show_icon_preview = False
arrange_by = None
label_pos = "bottom"
icon_locations = {os.path.basename(app): (170, 214), "Applications": (490, 214)}
hide_extension = [os.path.basename(app)]
