"""Tests for Check for Updates. Run from the repo root after scripts/build.sh:

    python3 tests/test_updater.py

Installs a copy of build/RetroDrop.app (as version 1.2.0) in a temporary folder, serves fake GitHub
"latest release" replies from a local server, and runs the updater non-interactively (--update-now)
against good and bad updates. Uses a throwaway signing key, never the real one. Quit any other running
RetroDrop server first (the success case starts the server, to check it comes back after relaunching).
"""
import http.server, json, os, plistlib, shutil, subprocess, sys, tempfile, threading, time

ROOT = os.getcwd()
results = []


def check(name, ok, detail=""):
    results.append(bool(ok))
    print(("PASS " if ok else "FAIL ") + name + (f"  ({detail})" if detail else ""), flush=True)


def run(cmd, env=None):
    return subprocess.run(cmd, capture_output=True, text=True, env={**os.environ, **(env or {})})


tmp = tempfile.mkdtemp(prefix="rd-update-")
feed_dir = os.path.join(tmp, "feed")
os.makedirs(feed_dir)
key = os.path.join(tmp, "test-key")
sign_env = {"RETRODROP_SIGNING_KEY": key}
pub = run(["swift", "scripts/update-signing.swift", "init"], sign_env).stdout.strip()
check("throwaway signing key created", len(pub) == 44, pub)


def make_app(dest_dir, version, bundle_id=None):
    """Copy of the built app with a different version (and optionally app ID), re-signed."""
    app = os.path.join(dest_dir, "RetroDrop.app")
    os.makedirs(dest_dir, exist_ok=True)
    shutil.rmtree(app, ignore_errors=True)
    run(["ditto", os.path.join(ROOT, "build/RetroDrop.app"), app])
    plist = os.path.join(app, "Contents/Info.plist")
    info = plistlib.load(open(plist, "rb"))
    info["CFBundleShortVersionString"] = version
    if bundle_id:
        info["CFBundleIdentifier"] = bundle_id
    plistlib.dump(info, open(plist, "wb"))
    run(["codesign", "--force", "--sign", "-", app])
    return app


def make_release(tag, app_version=None, bundle_id=None, signed=True, wrong_signature=False, has_sig=True):
    """Writes feed/latest.json, feed/RetroDrop.dmg and (optionally) feed/RetroDrop.dmg.sig."""
    staging = os.path.join(tmp, "staging")
    shutil.rmtree(staging, ignore_errors=True)
    make_app(staging, app_version or tag, bundle_id)
    dmg = os.path.join(feed_dir, "RetroDrop.dmg")
    if os.path.exists(dmg):
        os.remove(dmg)
    run(["hdiutil", "create", "-quiet", "-srcfolder", staging, "-volname", "RetroDrop", "-format", "UDZO", dmg])
    sig = dmg + ".sig"
    if os.path.exists(sig):
        os.remove(sig)
    if signed:
        if wrong_signature:  # a valid signature, but for different bytes
            other = os.path.join(tmp, "other.bin")
            open(other, "wb").write(b"not the dmg")
            run(["swift", "scripts/update-signing.swift", "sign", other], sign_env)
            shutil.move(other + ".sig", sig)
        else:
            run(["swift", "scripts/update-signing.swift", "sign", dmg], sign_env)
    assets = [{"name": "RetroDrop.dmg", "browser_download_url": f"{base}/RetroDrop.dmg"}]
    if has_sig and os.path.exists(sig):
        assets.append({"name": "RetroDrop.dmg.sig", "browser_download_url": f"{base}/RetroDrop.dmg.sig"})
    json.dump({"tag_name": "v" + tag, "body": "**Test** release", "html_url": base, "assets": assets},
              open(os.path.join(feed_dir, "latest.json"), "w"))


class Quiet(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=feed_dir, **kw)

    def log_message(self, *a):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Quiet)
base = f"http://127.0.0.1:{server.server_address[1]}"
threading.Thread(target=server.serve_forever, daemon=True).start()

installed = make_app(os.path.join(tmp, "Applications"), "1.2.0")
exe = os.path.join(installed, "Contents/MacOS/RetroDrop")
scratch = {d: os.path.join(tmp, d) for d in ("photos", "outbox")}
for d in scratch.values():
    os.makedirs(d)


def installed_version():
    return plistlib.load(open(os.path.join(installed, "Contents/Info.plist"), "rb"))["CFBundleShortVersionString"]


def update(extra=()):
    """Runs the updater; returns its output once the old app has quit."""
    log_path = os.path.join(tmp, "update.log")
    with open(log_path, "w") as log:
        p = subprocess.Popen([exe, "-updateFeedURL", base + "/latest.json", "-updatePublicKey", pub,
                              "-saveFolder", scratch["photos"], "-outboxDir", scratch["outbox"], *extra, "--update-now"],
                             stdout=log, stderr=log)
        p.wait(timeout=180)
    return open(log_path).read().strip()


def leftovers():
    return [n for n in os.listdir(tempfile.gettempdir()) if n.startswith("RetroDrop-update-")]


try:
    make_release("1.2.0")
    out = update()
    check("same version -> up to date, nothing installed", "up to date" in out and installed_version() == "1.2.0", out[-80:])

    make_release("1.1.9")
    out = update()
    check("older release -> up to date", "up to date" in out, out[-80:])

    make_release("1.2.1", wrong_signature=True)
    out = update()
    check("signature for other bytes -> refused", "signature doesn't match" in out and installed_version() == "1.2.0", out[-90:])

    make_release("1.2.1", has_sig=False)
    out = update()
    check("no signature -> refused", "no signature" in out and installed_version() == "1.2.0", out[-90:])

    make_release("1.2.1", bundle_id="com.example.NotRetroDrop")
    out = update()
    check("different app inside -> refused", "different app ID" in out and installed_version() == "1.2.0", out[-90:])

    make_release("1.2.1", app_version="1.3.0")
    out = update()
    check("version inside doesn't match the release -> refused", "expected 1.2.1" in out and installed_version() == "1.2.0", out[-90:])
    check("refused updates leave no temporary files behind", not leftovers(), leftovers())

    make_release("1.10.0")
    out = update(["--start"])  # server running, so the relaunched app should start it again
    for _ in range(60):
        time.sleep(0.5)
        if installed_version() == "1.10.0" and run(["pgrep", "-f", exe]).stdout.strip():
            break
    check("good update installed (1.10.0 > 1.2.0, compared as numbers)", installed_version() == "1.10.0", installed_version())
    check("new version relaunched", bool(run(["pgrep", "-f", exe]).stdout.strip()))
    time.sleep(2)
    listening = run(["lsof", "-nP", "-iTCP:8765", "-sTCP:LISTEN"]).stdout
    check("server running again after relaunch", "RetroDrop" in listening)
    check("old copy and staging files cleaned up",
          not os.path.exists(installed + ".old") and not leftovers())
    check("updated app's code signature intact", run(["codesign", "--verify", "--deep", "--strict", installed]).returncode == 0)
finally:
    run(["pkill", "-f", exe])
    server.shutdown()
    time.sleep(1)
    shutil.rmtree(tmp, ignore_errors=True)

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
