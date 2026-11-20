"""沿用原项目的拖放安装布局，以文件方式写入 Finder 设置。"""

from pathlib import Path


app = Path(defines["app"])
format = "ULMO"
filesystem = "HFS+"
files = [str(app)]
symlinks = {"Applications": "/Applications"}
background = defines["background"]
icon = str(app / "Contents/Resources/AppIcon.icns")
window_rect = ((200, 160), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 14
label_pos = "bottom"
arrange_by = None
include_icon_view_settings = True
include_list_view_settings = False
icon_locations = {app.name: (170, 180), "Applications": (490, 180)}
