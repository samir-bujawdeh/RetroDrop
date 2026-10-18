"""Tests for sending photos and videos from the Mac to the phone. Run from the repo root after scripts/build.sh:

    python3 tests/test_send_to_phone.py

Needs ffmpeg/ffprobe (brew install ffmpeg). Launches build/RetroDrop.app with a scratch outbox and
photo folder, queues test files with --send, then checks the conversions, the Safari page and the
POP3 mailbox. Quit any other running RetroDrop first (the servers need ports 8765, 25 and 110).
"""
import email, json, os, poplib, shutil, socket, subprocess, sys, tempfile, time, urllib.request

APP = os.path.abspath("build/RetroDrop.app")
EXE = APP + "/Contents/MacOS/RetroDrop"
results = []


def check(name, ok, detail=""):
    results.append(bool(ok))
    print(("PASS " if ok else "FAIL ") + name + (f"  ({detail})" if detail else ""), flush=True)


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout.strip()


def probe(path):
    return json.loads(sh(f"ffprobe -v error -show_streams -of json '{path}'"))["streams"]


tmp = tempfile.mkdtemp(prefix="rd-send-")
media, outbox_dir, photos_dir = (os.path.join(tmp, d) for d in ("media", "outbox", "photos"))
for d in (media, outbox_dir, photos_dir):
    os.makedirs(d)

# --- Test media, like what a modern Mac has ---
swift = os.path.join(tmp, "make.swift")
open(swift, "w").write(r'''
import AppKit
import ImageIO
// 4000x3000 photo stored sideways (EXIF orientation 6, as iPhones do), Display P3, saved as HEIC.
let w = 4000, h = 3000
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setFillColor(CGColor(red: 1, green: 0.4, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, "public.heic" as CFString, 1, nil)!
CGImageDestinationAddImage(dst, ctx.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
CGImageDestinationFinalize(dst)
''')
heic = os.path.join(media, "Sideways Photo.HEIC")
sh(f"swift '{swift}' '{heic}'")
png = os.path.join(media, "transparent.png")
sh(f"sips -s format png -z 600 800 assets/icon.png --out '{png}'")
hevc = os.path.join(media, "1080p60 HEVC.mov")
sh(f"ffmpeg -v error -y -f lavfi -i testsrc2=size=1920x1080:rate=60:duration=3 -f lavfi -i sine=frequency=440:duration=3 "
   f"-c:v libx265 -tag:v hvc1 -pix_fmt yuv420p -c:a aac -shortest '{hevc}'")
portrait = os.path.join(media, "portrait.mov")
landscape = os.path.join(tmp, "landscape.mov")
sh(f"ffmpeg -v error -y -f lavfi -i testsrc2=size=1280x720:rate=30:duration=2 -c:v libx264 -pix_fmt yuv420p '{landscape}'")
# Same frames, flagged "display rotated 90°" the way phone cameras store portrait video.
sh(f"ffmpeg -v error -y -display_rotation 90 -i '{landscape}' -c copy '{portrait}'")
notes = os.path.join(media, "notes.txt")
open(notes, "w").write("not a photo")
check("test media created", all(os.path.getsize(f) > 0 for f in (heic, png, hevc, portrait)))

# An item left over from an earlier version: a 2048x1536 (3.1 MP) photo, too big for old Safari.
old = {"id": "oldbig01", "name": "Old Big.jpg", "kind": "photo", "added": 0}
sh(f"sips -s format jpeg -z 1536 2048 assets/icon.png --out '{os.path.join(outbox_dir, 'oldbig01.jpg')}'")
shutil.copy(os.path.join(outbox_dir, "oldbig01.jpg"), os.path.join(outbox_dir, "oldbig01-thumb.jpg"))
open(os.path.join(outbox_dir, "oldbig01.eml"), "w").write("placeholder")
json.dump([old], open(os.path.join(outbox_dir, "outbox.json"), "w"))

# --- Launch with the files queued ---
sh(f"pkill -f '{EXE}'")
subprocess.run(["open", "-n", APP, "--args", "-outboxDir", outbox_dir, "-saveFolder", photos_dir, "--start",
                "--send", heic, png, hevc, portrait, notes])
manifest = os.path.join(outbox_dir, "outbox.json")
items = []
for _ in range(120):
    time.sleep(0.5)
    try:
        items = json.load(open(manifest))
    except Exception:
        continue
    if len(items) >= 5:
        break
time.sleep(1)  # let the old-photo fix-up finish
items = json.load(open(manifest))
check("4 media files queued, text file skipped", len(items) == 5, f"{len(items) - 1} new items")
oldjpg = os.path.join(outbox_dir, "oldbig01.jpg")
od = sh(f"sips -g pixelWidth -g pixelHeight '{oldjpg}'")
ow = int(od.split("pixelWidth: ")[1].split()[0]); oh = int(od.split("pixelHeight: ")[1].split()[0])
check("photo queued by an older version shrunk under 2 MP", ow * oh <= 1_990_000, f"{ow}x{oh}")
oldmsg = email.message_from_bytes(open(os.path.join(outbox_dir, "oldbig01.eml"), "rb").read())
check("...and its email rebuilt with the smaller photo",
      any(p.get_payload(decode=True) == open(oldjpg, "rb").read() for p in oldmsg.walk() if p.get_filename()))
by_name = {i["name"]: i for i in items}
path = lambda item, which: os.path.join(outbox_dir, f"{item['id']}{which}")

try:
    # --- Photo conversion ---
    p = by_name.get("Sideways Photo.jpg")
    if p:
        out = path(p, ".jpg")
        dims = sh(f"sips -g pixelWidth -g pixelHeight -g format -g profile '{out}'")
        check("HEIC -> JPEG", "format: jpeg" in dims)
        w = int(dims.split("pixelWidth: ")[1].split()[0]); h = int(dims.split("pixelHeight: ")[1].split()[0])
        check("rotated upright (portrait)", h > w, f"{w}x{h}")
        check("under 2 megapixels (old Safari's limit) but not much smaller", 1_900_000 < w * h <= 1_990_000, f"{w * h:,} px")
        check("aspect ratio kept", abs(h / w - 4 / 3) < 0.01)
        check("colour converted to sRGB", "sRGB" in dims, dims.split("\n")[-1].strip())
    else:
        check("HEIC photo queued", False)
    t = by_name.get("transparent.jpg")
    check("transparent PNG -> 800x600 JPEG", t and "pixelWidth: 800" in sh(f"sips -g pixelWidth '{path(t, '.jpg')}'"))

    # --- Video conversion ---
    def video_ok(item, w, h):
        s = probe(path(item, ".mp4"))
        v = next(x for x in s if x["codec_type"] == "video")
        fps = eval(v["avg_frame_rate"])
        return v, (v["codec_name"] == "h264" and "Baseline" in v.get("profile", "") and v["level"] <= 30
                   and (v["width"], v["height"]) == (w, h) and fps <= 30.01), s
    v1 = by_name.get("1080p60 HEVC.mp4")
    if v1:
        v, ok, streams = video_ok(v1, 640, 360)
        check("HEVC 1080p60 -> H.264 Baseline 3.0, 640x360, <=30 fps", ok,
              f"{v['codec_name']} {v.get('profile')} L{v['level']} {v['width']}x{v['height']} {v['avg_frame_rate']}")
        a = [x for x in streams if x["codec_type"] == "audio"]
        check("audio -> AAC 44.1 kHz stereo", a and a[0]["codec_name"] == "aac" and a[0]["sample_rate"] == "44100" and a[0]["channels"] == 2)
        check("video duration kept", abs(v1["duration"] - 3) < 0.2, v1["duration"])
    else:
        check("HEVC video queued", False)
    v2 = by_name.get("portrait.mp4")
    if v2:
        v, ok, _ = video_ok(v2, 360, 640)
        check("rotated portrait video -> upright 360x640", ok, f"{v['width']}x{v['height']}")
    else:
        check("portrait video queued", False)

    # --- Safari page ---
    base = "http://127.0.0.1:8765"
    page = urllib.request.urlopen(base + "/", timeout=5).read().decode()
    check("page shows From your Mac with all items", "From your Mac" in page and all(i["id"] in page for i in items))
    check("no saveable thumbnail <img> on the main page", "-thumb.jpg\"" not in page.split("From your Mac")[1].split("<p>Tap a video")[0]
          and "<img src=\"/out/" not in page.split("From your Mac")[1].split("<p>Tap a video")[0])
    photo = by_name["Sideways Photo.jpg"]
    view = urllib.request.urlopen(f"{base}/view/{photo['id']}", timeout=5).read().decode()
    check("photo page shows the full-size photo", f'<img src="/out/{photo["id"]}.jpg"' in view and "Save Image" in view)
    check("photo page has Previous/Next between photos", "Previous" in view or "Next" in view)
    body = urllib.request.urlopen(f"{base}/out/{photo['id']}.jpg", timeout=5).read()
    check("full photo download identical", body == open(path(photo, ".jpg"), "rb").read())
    vid = path(v1, ".mp4")
    req = urllib.request.Request(f"{base}/out/{v1['id']}.mp4", headers={"Range": "bytes=100-1099"})
    r = urllib.request.urlopen(req, timeout=5)
    check("video range request -> 206 with the right bytes",
          r.status == 206 and r.read() == open(vid, "rb").read()[100:1100] and r.headers["Content-Range"].endswith(f"/{os.path.getsize(vid)}"))
    req = urllib.request.Request(f"{base}/out/{v1['id']}.mp4", headers={"Range": "bytes=-500"})
    check("suffix range (last 500 bytes)", urllib.request.urlopen(req, timeout=5).read() == open(vid, "rb").read()[-500:])
    def status(url, headers=None):
        try:
            return urllib.request.urlopen(urllib.request.Request(url, headers=headers or {}), timeout=5).status
        except urllib.error.HTTPError as e:
            return e.code
    check("out-of-range request -> 416", status(f"{base}/out/{v1['id']}.mp4", {"Range": "bytes=999999999-"}) == 416)
    check("unknown photo page -> 404", status(f"{base}/view/nope") == 404)
    check("can't fetch the manifest or other files", status(f"{base}/out/outbox.json") == 404 and status(f"{base}/out/..%2F..%2Fetc%2Fpasswd") == 404)

    # --- Mail (POP3) ---
    pop = poplib.POP3("127.0.0.1", 110, timeout=10)
    pop.user("retrodrop"); pop.pass_("x")
    count, total = pop.stat()
    check("mailbox has one message per item", count == len(items), f"{count} messages")
    uidls = [l.decode().split()[1] for l in pop.uidl()[1]]
    check("UIDLs are the item ids", sorted(uidls) == sorted(i["id"] for i in items))
    all_ok = True
    for n in range(1, count + 1):
        msg = email.message_from_bytes(b"\r\n".join(pop.retr(n)[1]))
        att = [p for p in msg.walk() if p.get_filename()]
        item = next(i for i in items if i["id"] == uidls[n - 1])
        want = open(path(item, ".jpg" if item["kind"] == "photo" else ".mp4"), "rb").read()
        all_ok &= len(att) == 1 and att[0].get_payload(decode=True) == want and item["name"].split(".")[0][:6] in msg["Subject"].replace("_", " ")
    check("every email carries its file, byte for byte", all_ok)
    top = pop.top(1, 2)[1]
    check("TOP returns headers and preview", any(l.startswith(b"Subject:") for l in top))
    pop.quit()
finally:
    sh(f"pkill -f '{EXE}'")
    time.sleep(1)
    shutil.rmtree(tmp, ignore_errors=True)

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
