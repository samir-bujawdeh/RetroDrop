# RetroDrop setup guide

This guide walks through everything from installing RetroDrop to sending your first photo, for both
kinds of old iPhone. If you get stuck, jump to [Troubleshooting](#troubleshooting).

- [1. Install RetroDrop on your Mac](#1-install-retrodrop-on-your-mac)
- [2. Start the server](#2-start-the-server)
- [3. Find out which route your phone uses](#3-find-out-which-route-your-phone-uses)
- [4a. Send with Safari (iOS 6 and later)](#4a-send-with-safari-ios-6-and-later)
- [4b. Send with Mail (iOS 5 and earlier)](#4b-send-with-mail-ios-5-and-earlier)
- [5. Get your photos](#5-get-your-photos)
- [6. Send photos and videos to the phone](#6-send-photos-and-videos-to-the-phone)
- [Keep your Mac's address from changing](#keep-your-macs-address-from-changing)
- [Troubleshooting](#troubleshooting)

---

## 1. Install RetroDrop on your Mac

1. **[Download RetroDrop](https://github.com/samir-bujawdeh/RetroDrop/releases/latest/download/RetroDrop.dmg)**. You always get the latest version.
2. Open the downloaded **RetroDrop.dmg**. In the window that appears, drag **RetroDrop** onto the
   **Applications** folder, then eject the RetroDrop disk (in Finder's sidebar or on the desktop).

   <img src="../assets/install/1-open-dmg.png" width="460" alt="The RetroDrop disk image window: drag RetroDrop onto Applications">

3. Double-click RetroDrop to open it.

**"RetroDrop Not Opened": allowing it the first time**

macOS warns about RetroDrop because it's a free app that isn't notarized by Apple yet. Notarization
requires a paid Apple membership, and nothing was found wrong with the app. You only do this once:

1. On the warning, click **Done**, *not* Move to Trash.

   <img src="../assets/install/2-click-done.png" width="420" alt="The “RetroDrop Not Opened” message, with Done highlighted">

2. Open **System Settings → Privacy & Security**, scroll down to **Security**, and click
   **Open Anyway** next to the RetroDrop message.

   <img src="../assets/install/3-open-anyway-settings.png" width="560" alt="Privacy & Security settings, with the Open Anyway button highlighted">

3. In the confirmation, click **Open Anyway**, then enter your password or use Touch ID if asked.

   <img src="../assets/install/4-open-anyway-confirm.png" width="420" alt="The “Open RetroDrop?” confirmation, with Open Anyway highlighted">

<details>
<summary>Prefer the Terminal?</summary>

```bash
xattr -dr com.apple.quarantine /Applications/RetroDrop.app
```
</details>

A small phone icon appears in your menu bar. That's RetroDrop. There's no window or Dock icon.

**Optional:** in the RetroDrop menu, tick **Open at Login** so it's always there after a restart.

## 2. Start the server

Click the phone icon and choose **Start Server**. The icon changes to show a signal, and the menu shows:

- **iOS 6 and later · open in Safari**: an address like `http://192.168.1.23:8765`
- **iOS 5 and earlier · mail server**: your Mac's address, like `192.168.1.23`

Click either one to copy it.

**First time only:** if macOS asks *"Do you want the application RetroDrop to accept incoming network
connections?"*, click **Allow**. Without this, the phone can't reach your Mac.

> Make sure the phone and the Mac are on the **same Wi‑Fi network**.

## 3. Find out which route your phone uses

On the phone, open **Settings → General → About** and look at **Version**.

| Version | Use |
|---|---|
| 6.0 or higher | [Safari](#4a-send-with-safari-ios-6-and-later) |
| 5.x or lower | [Mail](#4b-send-with-mail-ios-5-and-earlier) |

(Safari on iOS 5 and earlier can't upload files at all. The *Choose File* button is greyed out,
which is why those phones use Mail instead.)

## 4a. Send with Safari (iOS 6 and later)

1. On the phone, open **Safari**.
2. Type the address from the RetroDrop menu, for example `http://192.168.1.23:8765`.
   Include the `http://` and the `:8765`.
3. Tap **Choose File** and pick one or more photos or videos.
4. Tap **Upload**.
5. Wait for the green **Saved** message. Videos can take a minute on an old phone's Wi‑Fi. Keep the
   page open until it finishes.

**Tip:** bookmark the page or add it to your Home Screen so next time it's one tap.

## 4b. Send with Mail (iOS 5 and earlier)

Here, the phone thinks it's sending an email. RetroDrop pretends to be the mail server and keeps the
attachments. Nothing is actually emailed, and nothing leaves your network.

### One-time setup (about 2 minutes)

Keep RetroDrop running on the Mac while you do this, because the phone checks the settings as you go.

1. On the phone, open **Settings → Mail, Contacts, Calendars → Add Account… → Other → Add Mail Account**.
2. Fill in:
   - **Name:** `RetroDrop`
   - **Address:** `retrodrop@mac.local`
   - **Password:** anything, e.g. `retro`
   - **Description:** `RetroDrop`
3. Tap **Next**, then choose **POP** at the top.
4. Under **Incoming Mail Server**:
   - **Host Name:** your Mac's address from the RetroDrop menu, e.g. `192.168.1.23`
   - **User Name:** `retrodrop`
   - **Password:** anything
5. Under **Outgoing Mail Server**:
   - **Host Name:** the same address, e.g. `192.168.1.23`
   - **User Name** and **Password:** leave blank
6. Tap **Save**.
7. If the phone asks *"Cannot connect using SSL. Do you want to try setting up the account without SSL?"*,
   tap **Yes**.

The account is saved. You only do this once, unless your Mac's address changes (see
[below](#keep-your-macs-address-from-changing)).

### Sending photos and videos

1. Open **Photos** and pick a photo or video.
   To send several photos at once, open an album, tap the share/edit button, select up to 5 photos,
   then tap **Share**.
2. Tap the share button, then **Email Photo** (or **Email Video**).
3. Make sure the **From** field shows `retrodrop@mac.local` (tap it to change).
4. Put any address in **To**, e.g. `mac@mac.local`. It's never used.
5. Tap **Send**.

They appear on your Mac within a few seconds.

> **Long videos:** Mail on old iOS may offer to send a smaller version, or refuse very long videos.
> Trim long clips on the phone first.

> **Tip:** when RetroDrop isn't running, the phone may say it *can't get mail* for this account.
> That's harmless. To silence it, turn the account off under **Settings → Mail, Contacts, Calendars →
> RetroDrop** and turn it back on when you need it.

## 5. Get your photos

Everything is saved in **Pictures/RetroDrop** on your Mac. You can change the folder with **Change Folder…**
in the menu.

From the RetroDrop menu:

- **This session** shows what arrived since you last pressed Start. **All photos** shows everything in
  the folder.
- **Drag** a thumbnail onto the desktop or into any app to copy it.
- **Double-click** a thumbnail to open it.
- Click **Saving to "RetroDrop"** to open the folder in Finder.

Files are named with the date and time they arrived, e.g. `20261018-143205-image.jpg`, so nothing is ever
overwritten.

Choose **Stop Server** when you're done.

## 6. Send photos and videos to the phone

RetroDrop also works the other way round: from your Mac to the phone.

1. In the RetroDrop menu, choose **Send Photos & Videos to Phone…**, or drop files onto the RetroDrop
   menu bar icon. You can also right-click a file in Finder and choose **Open With → RetroDrop**.
2. RetroDrop converts them so old iPhones can open them: photos become JPEGs (up to 2048 pixels),
   and videos become 640×480 H.264, which plays on any old iPhone. **Waiting on Phone** in the menu
   lists what's ready.
3. On the phone, with RetroDrop's server running:
   - **Safari** (any iOS version): open RetroDrop's address. Under **From your Mac**, tap a photo,
     then touch and hold it and tap **Save Image**. Safari can play videos, but it can't save them.
   - **Mail** (phones with the RetroDrop mail account): check mail in the RetroDrop account. Each
     photo or video arrives as its own email. Touch and hold it to save it to your Camera Roll.

Files stay in **Waiting on Phone** until you remove them, so several phones can pick them up.

## Keep your Mac's address from changing

Your router gives your Mac its address, and it can change after a restart. For the Safari route, just
check the RetroDrop menu each time. For the Mail route, a changed address means editing both Host Names
in the phone's account, so it's worth making the address permanent:

- **Best:** in your router's settings, look for **DHCP reservation**, **static lease** or **address
  reservation**, and reserve the current address for your Mac.
- **Alternative:** on the Mac, open **System Settings → Network → Wi‑Fi → Details… → TCP/IP**, set
  **Configure IPv4** to **Using DHCP with manual address**, and enter the current address.

## Troubleshooting

**The phone can't open the page / "Safari can't open the page"**
- Is the server running? The menu bar icon should show a signal.
- Are the phone and the Mac on the same Wi‑Fi? Guest networks often block devices from seeing each other.
- Check the address in the RetroDrop menu. It may have changed. Include `http://` and `:8765`.
- macOS firewall: open **System Settings → Network → Firewall → Options…** and make sure RetroDrop is set
  to **Allow incoming connections**.
- Some routers have **client isolation** or **AP isolation** turned on, which stops devices on Wi‑Fi from
  talking to each other. Turn it off in the router settings.

**The menu says "Port 8765 was busy…"**
Another app on your Mac was using RetroDrop's usual port, so RetroDrop moved to the next free one.
Use the new address shown in the menu and update any bookmarks on your phones. RetroDrop keeps using
the new port from now on.

**The menu says "Safari uploads are off"**
Twenty ports in a row were busy, which is very unusual. Restart the Mac, or quit developer tools and
servers you may be running. The Mail route still works in the meantime.

**"Choose File" is greyed out in Safari**
The phone is on iOS 5 or earlier. Use the [Mail route](#4b-send-with-mail-ios-5-and-earlier).

**Mail setup says it can't connect, or "Cannot Verify Server Identity"**
- Start the server on the Mac first. The phone checks the account during setup.
- Make sure both Host Names are your Mac's current address, and that SSL is off. You'll find the SSL
  setting under the account's **Advanced** settings.
- If the RetroDrop menu says **"Email uploads are off: Port 25 is already in use"**, another app on your
  Mac (often a developer tool or another mail server) is using the mail ports. Quit it and restart
  RetroDrop's server.

**The email sends but nothing arrives**
- Check that the email was sent **from** the RetroDrop account, not your regular email account.
- On the phone, open the **Outbox** in Mail. If messages are stuck there, the Mac's address has probably
  changed. Update the Outgoing Host Name.

**macOS won't open RetroDrop at all**
See [step 1](#1-install-retrodrop-on-your-mac). Use **Open Anyway** in Privacy & Security.

**Still stuck?** Open an issue on the project page and include your phone model, its iOS version, and what
the RetroDrop menu shows.
