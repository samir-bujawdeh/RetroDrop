# Changelog

## Unreleased

- **Send photos and videos from the Mac to the phone.** Choose *Send Photos & Videos to Phone…*,
  drop files on the menu bar icon, or use Finder's *Open With → RetroDrop*. Files are converted for old
  iPhones (photos → sRGB JPEG up to 2048 px; videos → H.264 Baseline 640×480 + AAC). The phone picks
  them up from a new "From your Mac" section in Safari, or as emails in the RetroDrop Mail account.
- Mail server now supports TOP, LIST/UIDL for single messages, and DELE.

## 1.0.0

First public release.

- Menu bar app with start/stop, the Mac's current address, and a "How to Connect a Phone" guide
- Safari upload page for iOS 6 and later: photos and videos, several at once
- Built-in mail server for iOS 5 and earlier: send photos and videos with Share → Email
- Thumbnail grid in the menu: This session / All photos, drag out to copy, double-click to open,
  video length badges
- Picks the right address automatically (the connection the Mac actually uses; ignores VPNs and
  self-assigned addresses) and keeps it up to date in the menu and the connect guide
- If port 8765 is busy, moves to the next free port and remembers it; each upload route starts
  independently, so one blocked route never stops the other
- Configurable save folder (default: Pictures/RetroDrop); never overwrites files
- Open at Login option
- Native app with no dependencies, for Apple silicon and Intel (macOS 14+)
