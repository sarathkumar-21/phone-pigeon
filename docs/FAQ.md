# PhonePigeon FAQ and troubleshooting

Start with the first section, "Quick fixes", if something stopped working. Everything else is organised by symptom.

- [Quick fixes](#quick-fixes)
- [Installing and the first launch (Mac)](#installing-and-the-first-launch-mac)
- [Pairing](#pairing)
- [Connecting and reconnecting](#connecting-and-reconnecting)
- [Re-pairing, duplicates and starting over](#re-pairing-duplicates-and-starting-over)
- [Messages](#messages)
- [Calls, Bluetooth audio, recording and auto-redial](#calls-bluetooth-audio-recording-and-auto-redial)
- [Scheduled calls and texts](#scheduled-calls-and-texts)
- [Notifications](#notifications)
- [Photos and files](#photos-and-files)
- [Screen mirroring and remote control](#screen-mirroring-and-remote-control)
- [The relay (connecting when you're not on the same Wi-Fi)](#the-relay)
- [Your data, privacy and resetting](#your-data-privacy-and-resetting)
- [Reporting a bug](#reporting-a-bug)

## Quick fixes

Try these in order. Most connection problems are solved by one of the first three.

1. **Same Wi-Fi.** The phone and the Mac must be on the same Wi-Fi network (the same router, not a guest network, not one on a VPN). Turn Wi-Fi off and on again on the phone.
2. **Reconnect.** On the Mac choose **Phone › Reconnect** (or **Settings › Connection › Reconnect Now**). Then open PhonePigeon on the phone once so Android wakes it.
3. **Check the Mac's run location.** The app must be in `/Applications` or `~/Applications`. Run from Downloads or Documents, macOS hides the local network from it and the phone is never found.
4. **Check Local Network permission.** On the Mac: **System Settings › Privacy & Security › Local Network › PhonePigeon** must be on. If it isn't listed, quit the app, move it to `~/Applications`, and open it again.
5. **Battery optimisation on the phone.** Set PhonePigeon to **Unrestricted** or **Don't optimise** (the path differs per maker, see [the phone goes offline](#the-phone-shows-connected-but-the-mac-says-offline-or-it-keeps-dropping)).
6. **Restart both apps.** Force-stop PhonePigeon on the phone and quit it on the Mac, then open the phone first and the Mac second.
7. **Still stuck?** [Re-pair](#re-pairing-duplicates-and-starting-over).

## Installing and the first launch (Mac)

### macOS says "Apple could not verify PhonePigeon is free of malware", "can't be opened" or "is damaged"

The release is not notarized (there is no paid Apple Developer ID behind it), so Gatekeeper blocks the first launch. Click **Done** (not *Move to Trash*), then do one of these:

- **System Settings › Privacy & Security**, scroll down to the PhonePigeon message, click **Open Anyway** and confirm.
- On macOS 14 or earlier only: right-click the app, choose **Open**, then **Open** again. (macOS 15 and later removed this.)
- In Terminal: `xattr -dr com.apple.quarantine /Applications/PhonePigeon.app`

Or build it from source (see the README); a build you make yourself is not quarantined.

### The Nearby phones list stays empty

Almost always one of three things:

1. The Mac app runs from a folder macOS treats as untrusted (Documents, Downloads, Desktop). Move it to `/Applications` or `~/Applications` and reopen it.
2. **Local Network** is off for PhonePigeon (see Quick fixes, step 4).
3. The phone's **Pair with your Mac** screen is not open. The phone is visible only while that screen is showing.

### macOS keeps asking for Keychain access

Builds signed ad hoc (every build you compile yourself, and the release DMG) have a signature macOS can't remember across updates, so it may ask again after you update. Click **Always Allow**. Setting `DEVELOPMENT_TEAM` in `macos/project.yml` gives a stable signature for builds you make.

### Which permissions does the Mac app ask for?

- **Local Network:** to find and talk to the phone.
- **Bluetooth:** for call audio over the phone's Bluetooth hands-free profile.
- **Microphone:** to carry your voice in a call, and for call recording.
- **Screen & System Audio Recording** (optional): so a call recording also captures the caller's voice. Without it only your own voice is recorded.
- **Notifications:** for message, call and phone-notification banners.

### The app opens but there is no window

Choose **Window › PhonePigeon** from the menu bar (or click the Dock icon). If the app seems stuck, quit it and open it again.

## Pairing

### How pairing works

There is no QR code. On the phone, open PhonePigeon and tap **Pair with your Mac**. On the Mac choose **File › Add Phone…** (⇧⌘N), pick your phone under **Nearby phones**, and confirm that both screens show the same six-digit code. Keep the phone's pairing screen open the whole time.

### The phone doesn't appear under Nearby phones

- The phone's **Pair with your Mac** screen must be open and in front.
- Same Wi-Fi network (see below). Some routers put the 2.4 GHz and 5 GHz bands on separate networks; make sure both devices are on the same one.
- Router **client isolation / AP isolation / guest network** blocks devices from seeing each other. Turn it off or use the main network.
- A **VPN** on either device can hide the local network. Turn it off while pairing.
- Some corporate, hotel and school Wi-Fi blocks the discovery (Bonjour/mDNS) traffic PhonePigeon uses. Use a home network or a phone hotspot (see next question).
- On the Mac, check Local Network permission and the app's run location (see above).
- Wait ten seconds, or press **Back** and **Add Phone…** again to restart the search.

### I'm on a network that blocks discovery. Is there a workaround?

Share your phone's hotspot to the Mac, or put both on a home router's main network. As an alternative, the optional [relay](#the-relay) lets paired devices reach each other without being on the same network, but you still pair once on a network where discovery works.

### "Couldn't reach the phone" or "The phone closed the connection"

The phone stopped listening (its pairing screen closed, or the phone went to sleep) or something between the two devices blocked the connection. On the phone, leave **Pair with your Mac** open with the screen on, then try again from the Mac. If you pressed Back on the phone, open **Pair with your Mac** again first.

### "The phone didn't answer in time"

The Mac waits two and a half minutes. Start again; on the phone make sure the pairing screen stays open and the screen doesn't turn off.

### The two codes don't match

Tap **Cancel** on both devices. A mismatch means the two sides did not talk directly to each other, which can mean someone on the network is interfering. Try again from the start on a network you trust. Never confirm a code that differs.

### The Mac's "Codes match" button doesn't respond

On purpose: it ignores clicks for the first 1.5 seconds after the code appears, and has no Return-key shortcut, so a stray key or click can't approve a pairing. Wait a moment and click it.

### I paired, but the Mac shows the phone as offline

Pairing and the everyday connection are separate steps. See [Connecting and reconnecting](#connecting-and-reconnecting).

### Pairing works with the Demo Phone but not my phone

The Demo Phone lives inside the Mac app, so it needs no network. If it works and your real phone doesn't, the problem is the network between the two devices: see the checklist above.

## Connecting and reconnecting

### How the connection works

The Mac listens for the phone on your local network (TCP port 8443 when free) and announces itself over Bonjour (`_pigeonmac._tcp`). The phone connects to it. Photos, files and screen mirroring use a second, separate connection to the phone's own small web server (port 8444). If the devices aren't on the same network, an optional relay carries only the encrypted messages.

### The Mac says Offline

1. Is the phone on the same Wi-Fi as the Mac, and awake? Open PhonePigeon on the phone and look at its home screen: it shows whether it is connected and to what address.
2. On the Mac: **Phone › Reconnect**.
3. Is the Mac asleep, or did its IP address change? Wait a few seconds after waking; the phone reconnects on its own.
4. Check [Quick fixes](#quick-fixes), steps 3 to 5.

### The phone shows "Connected" but the Mac says Offline, or it keeps dropping

This is usually the phone's battery saver closing the background service, or an old pairing on one side.

- **Battery optimisation.** Set PhonePigeon to unrestricted:
  - *Stock Android and Pixel:* Settings › Apps › PhonePigeon › Battery › **Unrestricted**.
  - *Samsung:* Settings › Apps › PhonePigeon › Battery › **Unrestricted**, and remove it from "Sleeping apps".
  - *Xiaomi / Redmi / Poco (MIUI, HyperOS):* Settings › Apps › Manage apps › PhonePigeon › Battery saver › **No restrictions**, and turn **Autostart** on.
  - *vivo / iQOO (Funtouch, OriginOS):* Settings › Battery › Background power consumption management › PhonePigeon › **Allow high background power consumption**, and allow **Autostart**. These phones also stop notification access in the background; see [notifications](#notifications).
  - *OPPO / Realme / OnePlus (ColorOS, OxygenOS):* Settings › Battery › PhonePigeon › **Allow background activity**, and enable **Auto-launch**.
  - *Huawei / Honor:* Settings › Battery › App launch › PhonePigeon › **Manage manually**, and enable all three switches.
  - *Not sure?* See the site [dontkillmyapp.com](https://dontkillmyapp.com) for your phone.
- **Lock the app in recents.** On many phones, open the recent-apps screen and lock or pin PhonePigeon.
- **Old pairing on one side.** If you unpaired or reinstalled on only one device, remove the pairing on both and pair again (see below).

### Reconnecting after the Mac restarts takes a long time

After a restart the phone and Mac have to agree on fresh keys again. The Mac tells the phone so, and normally everything resumes within seconds. If it doesn't: **Phone › Reconnect** on the Mac, then open PhonePigeon on the phone. If it still doesn't recover after a minute, [re-pair](#re-pairing-duplicates-and-starting-over).

### I see "Local Network" and sometimes "Cloud Relay". What's the difference?

**Local Network** means the phone is talking to the Mac directly over your Wi-Fi: fastest, and the only mode in which photos, files and screen mirroring work. **Cloud Relay** means messages travel through your own relay server, still end-to-end encrypted, for when you're not on the same network. The Mac uses the local network when it can and falls back to the relay if you've set one up.

### It works on Wi-Fi but not on mobile data or another network

Without the optional relay, the phone and Mac must share a network. See [The relay](#the-relay).

### The connection works for a while, then stops overnight

Usually the phone's battery saver (above) or the Mac sleeping. Turn off **Put hard disks to sleep** and allow network access while asleep if you need overnight connectivity, and keep PhonePigeon unrestricted on the phone. The phone reconnects by itself when both are awake again.

### Can two Macs use one phone? Can one Mac use several phones?

One Mac can pair with as many phones as you like (switch with the chevron next to the phone's name in the sidebar). A phone pairs with one Mac at a time.

## Re-pairing, duplicates and starting over

### When do I need to pair again?

- You **reinstalled** PhonePigeon on the phone, or cleared its storage/data. The phone gets a new identity, so the old pairing can't connect any more.
- You used **Generate New Identity Key** on the Mac.
- You see "Stored pairing keys … are invalid — please pair it again."
- The phone and Mac were unpaired on only one side and now can't agree.
- A connection that won't come back after the steps in [Quick fixes](#quick-fixes).

### How do I pair again cleanly?

1. **On the phone:** open PhonePigeon, tap the three-dot menu on the home screen, and choose **Unpair Mac**.
2. **On the Mac:** remove the old phone entry (the trash can next to the phone in the switcher at the top of the sidebar, or **Settings › Phone › Paired phones**). This also erases its saved messages on this Mac.
3. Pair again: on the phone **Pair with your Mac**, on the Mac **File › Add Phone…**.

You don't have to uninstall anything.

### I have the same phone listed twice

Reinstalling the Android app gives the phone a new identity, so it shows up as a second copy. After a new pairing the Mac offers to remove the old entry: choose **Remove Old**. You can also remove entries yourself: the trash can beside each phone in the sidebar switcher, or **Remove N offline phones…**.

### Will I lose my messages?

Messages on your phone are not touched. The Mac keeps its own copy of the conversations it has synced; removing a phone deletes that copy on the Mac, and pairing again syncs recent messages from the phone. Photos and files always stay on the phone.

### How do I wipe everything and start from nothing?

1. Unpair on both sides as above.
2. On the Mac: **Settings › Security › Generate New Identity Key…** creates a fresh Mac identity (this also unpairs every phone).
3. To erase the Mac app's local data completely, quit the app and delete its container folder: `~/Library/Containers/dev.phonepigeon.mac`. Remove the *PhonePigeon* items in Keychain Access too if you want no trace of the old keys.
4. On the phone: Settings › Apps › PhonePigeon › Storage › **Clear data**, or uninstall.

## Messages

### Messages are missing, or only some arrived

- The Mac syncs new messages live and the recent history when it pairs. Very old messages may not appear.
- **RCS / "chat" messages** (Google Messages chat features) are not SMS and never reach the Mac as messages. Their notifications do come through (see [notifications](#notifications)), but you can't reply to an RCS chat from the Mac.
- **Allow all** on the phone's permissions screen must have granted **Messages** (SMS) permission.
- The phone's home screen has a switch for sharing messages; make sure it is on.

### The reply goes out from the wrong SIM

Each conversation remembers the SIM it last used and follows the SIM of the newest incoming message. Pick the SIM at the bottom of the conversation (or press ⌘1 / ⌘2) before sending.

### My message shows "Failed"

The phone could not send it: no signal, no credit, or the phone's SMS permission was revoked. Check the phone, then send again. The phone also allows at most 20 texts a minute from the Mac.

### My message with an emoji uses more SMS parts

Texts with emoji or non-Latin letters are sent in a different encoding that fits fewer characters per part (70 instead of 160). The counter under the message box shows how many parts it will take.

### Can I send a GIF or a picture?

Not as a picture: SMS can't carry animated images and PhonePigeon doesn't support MMS. The **GIF** button adds a GIF *link* (browse GIPHY or Tenor, copy the link, paste it). Phones with RCS or link previews show it animated.

### Verification codes aren't detected

The Mac detects 4 to 8 digit codes in incoming messages and offers a one-click copy; the clipboard is cleared after the delay you set in Settings. If a code isn't recognised, open the message and copy it by hand.

## Calls, Bluetooth audio, recording and auto-redial

### I can place calls but there's no audio on the Mac

Call audio travels over Bluetooth hands-free, not over Wi-Fi.

1. Pair the phone with the Mac in **System Settings › Bluetooth** (a normal Bluetooth pairing, separate from PhonePigeon).
2. Allow **Bluetooth** for PhonePigeon on both the Mac and the phone.
3. During the call use the audio button (Mac, Phone speaker or Phone earpiece) to switch. If Bluetooth isn't connected, the call stays on the phone and the Mac says so.
4. The phone's home screen and the sidebar show a headphones icon when Bluetooth audio is connected.
5. Watch the line at the bottom of the call card. It says what the Mac's hands-free link is doing: *Connecting hands-free…*, *Linked… waiting for call audio*, *Hands-Free · your phone* (audio is on the Mac), or the reason it failed.
6. If it says the phone **didn't accept a hands-free link**: on the phone open Bluetooth settings, tap this Mac, and switch on **Phone calls** (call audio); if the Mac isn't listed, forget it on both sides and pair it again. Other Bluetooth headsets connected to the Mac can also grab the call audio: disconnect them for the call.
7. The phone showing as "Connected" in macOS Bluetooth settings is not enough: that is often only a low-energy link. Call audio needs the *hands-free* link, which macOS opens only to a phone that has paired with the Mac for calls.
8. Open **Settings › Phone › Set up call audio…** (or press **Fix…** on the call card). It checks four things in order (Bluetooth on, phone paired, phone offers a hands-free service, phone accepts the link) and shows what to do about the first one that fails.
9. **The On Mac button is missing.** PhonePigeon hides it until that check passes, so you are never offered something that won't work. The call still works on the Mac (answer, decline, dial, end) and the voice stays on the phone. Run the check again after you change something.
10. If the last step still fails after you forgot the Mac on the phone and paired it again *from the phone* (with System Settings › Bluetooth open on the Mac), macOS is refusing to act as a hands-free unit for that phone. That is a limit of macOS and Android together; it does not work with every phone, and nothing in PhonePigeon can force it.
11. The first time the check runs, macOS asks to allow Bluetooth for PhonePigeon. Choose **Allow**; until you do, nothing Bluetooth-related can work.

### A missed call stays on the Mac screen

Update the Android app (the phone tells the Mac when the ringing stops). If it still happens with the latest APK, press **Reconnect** in the PhonePigeon menu.

### The call timer starts before the other person answers

The phone reports a Mac-placed call as connected as soon as it starts dialling, so the timer may begin early. It does not affect the call.

### Recording a call

The **Record** button works when the call audio is on the Mac (Android doesn't let apps record call audio on the phone). The first time, you are asked to confirm you may record; laws differ by country and many require everyone's consent. Recordings go to `Music › PhonePigeon Recordings`. To capture the caller's voice as well as yours, allow **Screen & System Audio Recording** for PhonePigeon in System Settings; otherwise only your own voice is recorded.

### Auto-redial doesn't call again

- Turn **Auto-redial** on next to the dialer. It is off every time the app starts, and stays off until you switch it on.
- The phone needs the **Call history** permission (included in **Allow all**): that is how it learns whether the call was answered. Without it the Mac stops after the first try and says so instead of guessing.
- It stops by design when someone answers, when you hang up yourself, after the number of tries you chose, or when the phone goes offline.
- The wait is at least 5 seconds, and the phone refuses more than 30 Mac-started calls in 10 minutes.

### How do I get more call controls, or a bigger call screen?

Every call starts as a small card in the corner with the controls. The shrink arrows on the card make it a bar; the expand arrows on the card open the full-window call screen with the contact's photo. To start every call full window, turn on **Settings › General › Calls › Open calls full-window**.

## Scheduled calls and texts

### My scheduled message didn't send

Scheduled items run **on the Mac**, so the app must be open and the phone connected at that time. If the time passes while either is missing, a text more than 5 minutes late (a call, 2 minutes) is skipped on purpose, never sent late, and you get a notification and a "Missed" entry in **Scheduled**. Open the app a few minutes before important sends, and keep the Mac awake.

### Can I schedule something while the Mac is closed?

No. The phone knows nothing about the schedule. Use the phone's own app for that.

### How do I cancel or send one now?

Open **Scheduled** in the sidebar: the paper-plane or phone button sends/calls now, and the cross cancels.

## Notifications

### Not all of my phone's notifications show up on the Mac

- **Notification access** must be on for PhonePigeon in Android settings (the permissions screen opens the right page). The home screen also has an on/off switch for it.
- Some phones (vivo, Xiaomi, Huawei, OPPO…) silently stop notification listeners to save battery. PhonePigeon asks Android to start it again whenever the app or the Mac connection comes up. If notifications still stop, exclude PhonePigeon from battery optimisation (see [connecting](#the-phone-shows-connected-but-the-mac-says-offline-or-it-keeps-dropping)), and toggle Notification access off and on once.
- Left out on purpose: ongoing notifications (music, calls, navigation) and group summaries that only repeat their children.
- The phone's Messages app is included. The Mac hides only the *banner* when the same text just arrived as an SMS; the notification still appears in the **Notifications** list.
- Notification content hidden by Android (for example on a locked screen, or marked private by the app) arrives as Android's placeholder text.
- Mac banners appear only for notifications from the last two minutes; older ones sit in the list.
- Check macOS **System Settings › Notifications › PhonePigeon** and any Focus mode.
- Use **Send a test notification to the Mac** on the phone's home screen to check the whole path.

### Dismissing on the Mac doesn't clear it on the phone

Only notifications Android lets apps clear (it marks some as not clearable) can be dismissed from the Mac.

## Photos and files

### Thumbnails spin forever, or opening a photo shows "can't connect"

Photos, videos and files come straight from the phone's built-in web server (port 8444), only on the same network, over a connection the Mac verifies against the phone's certificate.

1. Both devices on the same Wi-Fi, not isolated (see pairing).
2. The phone is awake. Open PhonePigeon on the phone, and make sure it shows as connected.
3. **Browse and copy** (and for uploads **Upload and rename**) are switched on in the phone's **Mac access to files** section.
4. **All files access** is allowed on the phone for the Files section (needed on Android 11 and later).
5. **Phone › Reconnect**, then reopen the Photos tab. After a reinstall or re-pair the phone announces a new certificate; reconnecting refreshes it.

### "TLS", "certificate" or "pinned" errors

The Mac only trusts the exact certificate the phone announced when pairing. A reinstalled phone app has a new one. [Re-pair](#re-pairing-duplicates-and-starting-over).

### A video won't play (mkv, avi, webm…)

macOS can't play every format. PhonePigeon saves such files to Downloads and opens them in your default player; install VLC or IINA if you have none.

### Delete doesn't work from the Mac

Deleting phone files from the Mac is **off by default**. Turn on **Delete** in the phone's **Mac access to files** section.

### Search only finds files in the current folder

Search covers the whole phone (two or more letters, nearest folders first, up to 500 results). Make sure the phone is connected and **Browse and copy** is on.

### Drag and drop or paste doesn't upload

Needs **Upload and rename** on the phone, and a connected phone. Uploads need free space on the phone, and every transfer shows in the transfer queue with a cancel button.

## Screen mirroring and remote control

### Mirror Screen does nothing, or the phone never asks

- The phone must be connected over the local network (mirroring uses the phone's media server).
- **Screen mirroring** must be on in the phone's **Mac access to files** section.
- The phone shows a notification: tap it, then accept Android's own capture dialog. Nothing is captured before you do, and it asks every time.
- On Android 14 and later, choose **Entire screen** in that dialog (single-app sharing isn't supported).
- If nothing happens, press **Stop Mirroring** on the Mac and start again.

### Mirroring starts and then ends right away

Seen on some tablets and OEM Android builds. Try a lower-power state (not on a battery saver), keep the screen on, and start again. If it persists, open an issue with your phone model and the log (see [Reporting a bug](#reporting-a-bug)).

### Parts of the screen are black

Apps that block screenshots (banking apps, some video apps) appear black on purpose.

### Can I use the phone while it's mirrored?

Yes. Mirroring only shows the screen; you can keep using the phone normally.

### How do I turn on remote control?

It is off by default and needs three things:

1. The **Remote control** switch on in PhonePigeon's home screen on the phone.
2. The **PhonePigeon remote control** accessibility service enabled in Android settings (Settings › Accessibility). Android warns you about this powerful permission.
3. A mirroring session you approved is running.

Then click to tap, drag or scroll to swipe, right-click for Back, type to enter text into the focused field, and use the Back / Home / Recents buttons in the mirror window's title bar. The phone ignores input outside an approved session and caps it at 30 events a second.

### Remote control does nothing

Check all three items above, and that the accessibility service wasn't switched off by the phone's battery saver (some phones disable accessibility services in the background).

## The relay

### Do I need the relay?

No. On the same Wi-Fi everything works without it. The relay only helps messages, calls and notifications reach each other when the devices are on different networks. Photos, files and screen mirroring still need the same network.

### How do I set one up?

See the README: copy `backend/.env.example` to `.env`, fill it in, run `docker compose up -d`, then enter the relay's `wss://` URL in **Settings › Connection** on the Mac. Pair on a network where discovery works first.

### The relay URL in Settings says "yourdomain"

That is a placeholder. The relay is off until you replace it with your own server's address.

## Your data, privacy and resetting

### Where does the Mac keep my data?

In one sealed (encrypted) file inside the app's container: `~/Library/Containers/dev.phonepigeon.mac/Data/Library/Application Support/PhonePigeon/store.sealed`. The key is in your Keychain. Downloads go to your Downloads folder, call recordings to `Music › PhonePigeon Recordings`.

### Does anything go to a server?

Not unless you set up your own relay, and even then it only sees encrypted data. PhonePigeon has no account and no analytics.

### How do I remove my data from the Mac?

Unpair each phone (this erases its saved messages, calls and contacts on the Mac), or use the full wipe in [Re-pairing](#how-do-i-wipe-everything-and-start-from-nothing).

### Is it safe to use on public Wi-Fi?

Everything between the phone and Mac is end-to-end encrypted, and a new pairing needs both people to confirm a six-digit code. Still, avoid pairing on a network you don't trust.

## Reporting a bug

Please include:

- Mac model and macOS version, phone model and Android version, and whether you use a relay.
- What you did, what you expected, and what happened.
- Screenshots **without** private content (hide names, numbers and message text).

Useful logs (remove anything private before posting):

- **Android:** with the phone connected by USB and USB debugging on, run `adb logcat -d | grep -i phonepigeon`. If the app crashed, it offers to show the crash report the next time it opens; you can copy it from there.
- **Mac:** open **Console.app**, select your Mac, and search for `PhonePigeon`.

Report problems at <https://github.com/sarathkumar-21/phone-pigeon/issues>. Report **security** problems privately, as described in [SECURITY.md](../SECURITY.md).
