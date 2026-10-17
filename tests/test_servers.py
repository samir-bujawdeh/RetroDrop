"""End-to-end tests for RetroDrop's upload servers.

Start RetroDrop pointed at an empty scratch folder, then run:

    open build/RetroDrop.app --args --start -saveFolder /tmp/rd-test
    python3 tests/test_servers.py "$(ipconfig getifaddr en0)" /tmp/rd-test

Uses only the Python standard library. Test files are written into the scratch folder.
"""
import os, sys, time, glob, socket, poplib, smtplib, urllib.request, uuid, unicodedata
from email.message import EmailMessage
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText
from email.mime.base import MIMEBase
from email import encoders

ip, folder = sys.argv[1], sys.argv[2]
results = []

def check(name, ok, detail=""):
    results.append(ok)
    print(("PASS " if ok else "FAIL ") + name + (f"  ({detail})" if detail else ""), flush=True)

def files():
    return set(glob.glob(os.path.join(folder, "*")))

def new_files_after(fn):
    before = files()
    fn()
    time.sleep(0.6)
    return sorted(files() - before)

def contents(paths):
    return sorted(open(p, "rb").read() for p in paths)

photo = b"\xff\xd8\xff\xe0" + os.urandom(200 * 1024)  # JPEG-ish bytes; content is compared, not decoded
small_video = b"\x00\x00\x00\x14ftypqt  " + os.urandom(300 * 1024)
big = os.urandom(60 * 1024 * 1024)  # 60 MB, like a long 3GS video

def multipart_post(fields):
    boundary = "----WebKitFormBoundary" + uuid.uuid4().hex[:16]
    body = b""
    for name, filename, ctype, data in fields:
        body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"; filename=\"{filename}\"\r\n"
                 f"Content-Type: {ctype}\r\n\r\n").encode() + data + b"\r\n"
    body += f"--{boundary}--\r\n".encode()
    req = urllib.request.Request(f"http://{ip}:8765/", data=body, method="POST",
                                 headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    return urllib.request.urlopen(req, timeout=120).read().decode()

# --- Web ---
page = urllib.request.urlopen(f"http://{ip}:8765/", timeout=10).read().decode()
check("web: page loads", "<title>RetroDrop</title>" in page and 'accept="image/*,video/*"' in page)

out = new_files_after(lambda: multipart_post([("file", "image.jpg", "image/jpeg", photo),
                                              ("file", "trim.MOV", "video/quicktime", small_video)]))
names = [os.path.basename(p) for p in out]
check("web: photo + video in one upload", contents(out) == sorted([photo, small_video]) and any(n.endswith("-image.jpg") for n in names) and any(n.endswith("-trim.MOV") for n in names), names)

resp = []
out = new_files_after(lambda: resp.append(multipart_post([("file", "", "application/octet-stream", b"")])))
check("web: empty submit saves nothing and says so", out == [] and "Nothing received" in resp[0])

out = new_files_after(lambda: [multipart_post([("file", "image.jpg", "image/jpeg", photo)]) for _ in range(3)])
names = sorted(os.path.basename(p) for p in out)
check("web: same name, same second -> no overwrite", len(out) == 3 and contents(out) == [photo] * 3 and all(n.endswith((".jpg")) for n in names), names)

# Binary data that contains the boundary-ish text and CRLFs must survive.
tricky = b"\r\n--notreally\r\n" + os.urandom(5000) + b"\r\n--\r\n"
out = new_files_after(lambda: multipart_post([("file", "tricky.bin", "application/octet-stream", tricky)]))
check("web: binary with CRLF/dashes intact", contents(out) == [tricky])

t = time.time()
out = new_files_after(lambda: multipart_post([("file", "big.MOV", "video/quicktime", big)]))
check("web: 60 MB video intact", contents(out) == [big], f"{time.time() - t:.1f}s")

# --- POP (account verification on the phone) ---
p = poplib.POP3(ip, 110, timeout=10)
p.user("retrodrop"); p.pass_("anything")
check("pop: login + empty mailbox", p.stat() == (0, 0) and p.list()[1] == [])
p.quit()

# --- SMTP ---
def send(msg, auth=None):
    s = smtplib.SMTP(ip, 25, timeout=120)
    s.ehlo()
    if auth: s.login(*auth)
    s.send_message(msg)
    s.quit()

m = EmailMessage(); m["From"] = "retrodrop@mac.local"; m["To"] = "x@mac.local"; m["Subject"] = "Photo"
m.set_content("Sent from my iPhone")
m.add_attachment(photo, maintype="image", subtype="jpeg", filename="photo.JPG")
out = new_files_after(lambda: send(m))
check("smtp: photo (no auth)", contents(out) == [photo] and out[0].endswith("-photo.JPG"), [os.path.basename(p) for p in out])

out = new_files_after(lambda: send(m, auth=("retrodrop", "anything")))
check("smtp: photo with AUTH", contents(out) == [photo])

# iOS-style: multipart/mixed containing multipart/alternative text + several attachments
mm = MIMEMultipart("mixed"); mm["From"] = "retrodrop@mac.local"; mm["To"] = "x@mac.local"
alt = MIMEMultipart("alternative"); alt.attach(MIMEText("hi\n.\n..dots\n")); alt.attach(MIMEText("<p>hi</p>", "html")); mm.attach(alt)
for i, data in enumerate([photo, small_video, photo]):
    part = MIMEBase("video" if data is small_video else "image", "quicktime" if data is small_video else "jpeg")
    part.set_payload(data); encoders.encode_base64(part)
    part.add_header("Content-Disposition", "attachment", filename=f"IMG_000{i}.{'MOV' if data is small_video else 'JPG'}")
    mm.attach(part)
out = new_files_after(lambda: send(mm))
check("smtp: nested multipart, 3 attachments", contents(out) == sorted([photo, small_video, photo]), [os.path.basename(p) for p in out])

# Non-ASCII filename (RFC 2231) and quoted-printable encoding
q = EmailMessage(); q["From"] = "a@b"; q["To"] = "c@d"; q.set_content("x")
q.add_attachment(b"caf\xc3\xa9 notes =\r\nline two", maintype="text", subtype="plain", filename="café.txt", cte="quoted-printable")
out = new_files_after(lambda: send(q))
check("smtp: unicode filename + quoted-printable", len(out) == 1 and unicodedata.normalize("NFC", out[0]).endswith("café.txt") and open(out[0],"rb").read() == b"caf\xc3\xa9 notes =\r\nline two", [os.path.basename(p) for p in out])

mb = EmailMessage(); mb["From"] = "a@b"; mb["To"] = "c@d"; mb.set_content("big")
mb.add_attachment(big, maintype="video", subtype="quicktime", filename="long.MOV")
t = time.time()
out = new_files_after(lambda: send(mb))
check("smtp: 60 MB video intact", contents(out) == [big], f"{time.time() - t:.1f}s")

# Filename that tries to escape the folder
ev = EmailMessage(); ev["From"] = "a@b"; ev["To"] = "c@d"; ev.set_content("x")
ev.add_attachment(photo, maintype="image", subtype="jpeg", filename="../../escape.jpg")
out = new_files_after(lambda: send(ev))
check("smtp: path in filename stays in folder", len(out) == 1 and os.path.dirname(out[0]) == folder.rstrip("/")
      and not os.path.exists(os.path.join(folder, "..", "escape.jpg")))

# Idle connection that never speaks must not block others
idle = socket.create_connection((ip, 25)); idle.recv(100)
out = new_files_after(lambda: send(m))
check("smtp: works while another connection is idle", contents(out) == [photo])
idle.close()

print(f"\n{sum(results)}/{len(results)} passed")
sys.exit(0 if all(results) else 1)
