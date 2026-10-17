"""Tests for address detection and port fallback. Run from the repo root after scripts/build.sh:

    python3 tests/test_network.py

Launches build/RetroDrop.app several times with blocked ports. Quit any other running
RetroDrop first. The app's remembered port setting is saved and restored afterwards.
"""
import os, socket, subprocess, sys, tempfile, time, urllib.request

APP = os.path.abspath("build/RetroDrop.app")
EXE = APP + "/Contents/MacOS/RetroDrop"
DOMAIN = "io.github.samir-bujawdeh.RetroDrop"
BASE = 18765  # test ports, away from the real default 8765
results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(("PASS " if ok else "FAIL ") + name + (f"  ({detail})" if detail else ""), flush=True)


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout.strip()


def listening(port):
    return sh(f"lsof -nP -iTCP:{port} -sTCP:LISTEN -a -c RetroDrop") != ""


def block(port):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)  # ignore TIME_WAIT from earlier requests
    s.bind(("0.0.0.0", port))
    s.listen()
    return s


def launch(folder):
    subprocess.run(["open", "-n", APP, "--args", "--start", "-saveFolder", folder])
    time.sleep(3)


def quit_app():
    sh(f"pkill -f '{EXE}'")
    time.sleep(1.5)


saved_port = sh(f"defaults read {DOMAIN} webPort 2>/dev/null")
folder = tempfile.mkdtemp(prefix="rd-net-")
try:
    # --- Address detection ---
    ip = sh(f"'{EXE}' --print-ip")
    iface = sh("route -n get default 2>/dev/null | awk '/interface:/{print $2}'")
    expected = sh(f"ipconfig getifaddr {iface}") if iface.startswith("en") else ""
    check("address = default-route Wi-Fi/Ethernet address", ip == expected and ip != "", f"{ip} via {iface}")
    check("address is not self-assigned", not ip.startswith("169.254."))

    # --- Port fallback ---
    sh(f"defaults write {DOMAIN} webPort -int {BASE}")
    blocker = block(BASE)
    launch(folder)
    page = urllib.request.urlopen(f"http://127.0.0.1:{BASE + 1}/", timeout=5).read().decode() if listening(BASE + 1) else ""
    check("busy port -> next port serves the page", "<title>RetroDrop</title>" in page)
    check("new port is remembered", sh(f"defaults read {DOMAIN} webPort") == str(BASE + 1))
    check("mail route unaffected", listening(25) and listening(110))
    quit_app()
    blocker.close()

    launch(folder)
    check("remembered port reused after restart (bookmarks keep working)", listening(BASE + 1) and not listening(BASE))
    quit_app()

    # --- Every web port busy: mail route still runs ---
    sh(f"defaults write {DOMAIN} webPort -int {BASE}")
    blockers = [block(BASE + i) for i in range(20)]
    launch(folder)
    check("all web ports busy -> no web server", not any(listening(BASE + i) for i in range(21)))
    check("all web ports busy -> mail route still runs", listening(25) and listening(110))
    quit_app()
    for b in blockers:
        b.close()

    # --- Mail port busy: web still runs, half-started mail is cleaned up ---
    blocker = block(110)
    launch(folder)
    check("mail port busy -> web runs", listening(BASE))
    check("mail port busy -> SMTP not left half-running", not listening(25))
    quit_app()
    blocker.close()
finally:
    quit_app()
    if saved_port:
        sh(f"defaults write {DOMAIN} webPort -int {saved_port}")
    else:
        sh(f"defaults delete {DOMAIN} webPort 2>/dev/null")
    sh(f"rm -rf '{folder}'")

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
