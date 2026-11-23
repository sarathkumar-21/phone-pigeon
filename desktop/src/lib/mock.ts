// Design preview only: when the page is opened in a plain browser (no Tauri), fake the backend with sample data
// so every screen can be viewed and compared with the Mac app. Never active inside the real app.
import { mockIPC } from "@tauri-apps/api/mocks";

const now = Date.now();
const min = 60_000, hr = 60 * min;
const msg = (i: number, addr: string, body: string, dir: "INCOMING" | "OUTGOING", agoMs: number, sim = 1, read = true, status = "DELIVERED") =>
  ({ id: `m${i}`, thread: addr, sim, address: addr, body, dir, status, ts: now - agoMs, read });

const snapshot = {
  sims: [
    { subscription_id: 1, slot_index: 0, carrier_name: "Jio 5G", display_name: "Personal", phone_number: "+918637486451", accent_color_hex: "#3b6ff5", is_default_sms: true, is_default_voice: false },
    { subscription_id: 2, slot_index: 1, carrier_name: "Airtel", display_name: "Work", phone_number: "+919841879117", accent_color_hex: "#ff5b3a", is_default_sms: false, is_default_voice: true },
  ],
  contacts: [
    { contact_id: "c1", display_name: "Ananya Rao", phone_numbers: ["+919845012345"] }, { contact_id: "c2", display_name: "Rahul Menon", phone_numbers: ["+919845067890"] },
    { contact_id: "c3", display_name: "Mom", phone_numbers: ["+919845000001"] }, { contact_id: "c4", display_name: "Priya Sharma", phone_numbers: ["+919845011111", "+919845022222"] },
    { contact_id: "c5", display_name: "Arjun Nair", phone_numbers: ["+919845033333"] }, { contact_id: "c6", display_name: "Sara Thomas", phone_numbers: ["+919845044444"] },
  ],
  threads: [
    { id: "AX-HDFCBK", address: "AX-HDFCBK", messages: [msg(1, "AX-HDFCBK", "482913 is your OTP for txn of INR 3,999.00 at FLIPKART. Valid for 5 mins. Do not share it with anyone.", "INCOMING", 20 * min, 1, false)] },
    { id: "+919845012345", address: "+919845012345", messages: [
      msg(2, "+919845012345", "Hey! Landed in Bangalore ✈️", "INCOMING", 26 * hr), msg(3, "+919845012345", "Welcome back! Coffee tomorrow?", "OUTGOING", 25.5 * hr),
      msg(4, "+919845012345", "Absolutely. Third Wave at 10?", "INCOMING", 25 * hr), msg(5, "+919845012345", "See you there ☕", "OUTGOING", 24.6 * hr),
      msg(6, "+919845012345", "Also — can you send me the photos from Coorg when you get a sec?", "INCOMING", 31 * min, 1, false)] },
    { id: "+919845067890", address: "+919845067890", messages: [msg(7, "+919845067890", "PR for the relay hub is up. Mind reviewing before EOD?", "INCOMING", 55 * min, 2, false)] },
    { id: "VM-AIRTEL", address: "VM-AIRTEL", messages: [msg(8, "VM-AIRTEL", "Your Airtel bill of Rs 599 is due on 25-Nov. Pay via Airtel Thanks app to avoid late fee.", "INCOMING", 9 * hr, 2)] },
    { id: "+919845000001", address: "+919845000001", messages: [msg(9, "+919845000001", "Okay. Eat properly! 🙂", "INCOMING", 30 * hr)] },
    { id: "+919845011111", address: "+919845011111", messages: [msg(10, "+919845011111", "Fixed! Sending v3 now", "OUTGOING", 3 * 24 * hr, 2)] },
    { id: "+919845033333", address: "+919845033333", messages: [msg(11, "+919845033333", "I'm in ⚽", "OUTGOING", 4 * 24 * hr)] },
  ],
  calls: [
    { id: "k1", sim: 1, address: "+919845000001", dir: "incoming", startedAt: now - 2 * hr, duration: 734 },
    { id: "k2", sim: 2, address: "+919845067890", dir: "missed", startedAt: now - 3 * hr, duration: 0 },
    { id: "k3", sim: 1, address: "+919845012345", dir: "outgoing", startedAt: now - 28 * hr, duration: 312 },
    { id: "k4", sim: 2, address: "+918044556677", name: "Office Desk", dir: "outgoing", startedAt: now - 30 * hr, duration: 95 },
    { id: "k5", sim: 2, address: "+919845011111", dir: "incoming", startedAt: now - 3 * 24 * hr, duration: 1260 },
    { id: "k6", sim: 1, address: "+917012345678", dir: "rejected", startedAt: now - 3.2 * 24 * hr, duration: 0 },
    { id: "k7", sim: 1, address: "+919845033333", dir: "outgoing", startedAt: now - 4 * 24 * hr, duration: 48 },
  ],
  notifications: [
    { key: "n1", package_name: "com.ubercab", app_name: "Uber", title: "Your trip", text: "Your code: 7914. Never share this code with anyone.", sub_text: "", posted_at_ms: now - 5 * min, app_icon_png: "", can_dismiss: true },
    { key: "n2", package_name: "com.google.android.gm", app_name: "Gmail", title: "Weekly digest", text: "3 new messages in your inbox", sub_text: "", posted_at_ms: now - 40 * min, app_icon_png: "", can_dismiss: true },
  ],
  battery: { battery_percent: 36, is_charging: false, bluetooth_hfp_connected: false, storage_free_bytes: 11.92e9, storage_total_bytes: 128e9 },
  scheduled: [
    { id: "s1", kind: "sms", address: "+919845012345", body: "Sending them tonight, promise 😅", sim: 1, fireAt: now + 70 * min, status: "pending", autoRedial: false },
    { id: "s2", kind: "call", address: "+919845044444", body: "", sim: 1, fireAt: now + 5 * hr, status: "pending", autoRedial: true },
  ],
  callLogAccess: true,
};

export function installMock() {
  (window as any).__PIGEON_PREVIEW__ = true;
  const phone = { id: "demo", name: "vivo V2144", manufacturer: "Vivo", os_version: "15", paired_at_ms: now - 24 * hr, connected: true, host: "192.168.0.8", fingerprint: "298F · 3D7E · A580", media_ready: false };
  mockIPC((cmd) => {
    switch (cmd) {
      case "phones": return [phone];
      case "device_info": return { name: "Saraths-MacBook-Pro", fingerprint: "7F3A · 91C2 · 0B4E · D8A1", lan_port: 8443 };
      case "snapshot_load": return JSON.stringify(snapshot);
      case "settings_load": return "";
      case "nearby_phones": return [];
      case "nearby_state": return { state: "idle" };
      default: return null;
    }
  }, { shouldMockEvents: true });
}
