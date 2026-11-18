"""Generate Finder metadata inside the mounted installer, without UI automation."""
from pathlib import Path
import sys

from ds_store import DSStore
from mac_alias import Alias

root = Path(sys.argv[1]).resolve()
background = Alias.for_file(str(root / ".background" / "installer.png"))
# The volume identity and file IDs stay unchanged on conversion to UDZO.
# Do not expose the build machine's temporary mount path in the alias.
background.volume.posix_path = b"/Volumes/JSONic"
with DSStore.open(str(root / ".DS_Store"), "w+") as store:
    store["."]["vSrn"] = ("long", 1)
    store["."]["icvl"] = ("type", b"icnv")
    store["."]["bwsp"] = {
        "WindowBounds": "{{160, 160}, {660, 420}}",
        "ShowToolbar": False, "ShowStatusBar": False,
        "ShowSidebar": False, "ShowPathbar": False, "ShowTabView": False,
        "ContainerShowSidebar": False, "PreviewPaneVisibility": False,
    }
    store["."]["icvp"] = {
        "viewOptionsVersion": 1, "backgroundType": 2,
        "backgroundImageAlias": background.to_bytes(),
        "backgroundColorRed": 0.965, "backgroundColorGreen": 0.965,
        "backgroundColorBlue": 0.965,
        "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0,
        "arrangeBy": "none", "showIconPreview": True,
        "showItemInfo": False, "labelOnBottom": True,
        "textSize": 14.0, "iconSize": 104.0, "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
    }
    store["JSONic.app"]["Iloc"] = (170, 210)
    store["Программы"]["Iloc"] = (490, 210)

with DSStore.open(str(root / ".DS_Store"), "r") as store:
    assert store["JSONic.app"]["Iloc"] == (170, 210)
    assert store["Программы"]["Iloc"] == (490, 210)
    alias = Alias.from_bytes(store["."]["icvp"]["backgroundImageAlias"])
    assert alias.target.posix_path == "/.background/installer.png", repr(alias.target.posix_path)
print("Installer layout saved: 660×420, two icons, volume-relative background.")
