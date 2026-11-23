// Types and pure helpers for the app's state. Protocol field names stay snake_case, exactly as on the wire.

export interface Sim {
  subscription_id: number; slot_index: number; carrier_name: string; display_name: string;
  phone_number: string; accent_color_hex: string; is_default_sms: boolean; is_default_voice: boolean;
}

export interface Contact { contact_id: string; display_name: string; phone_numbers: string[]; thumbnail_jpeg?: string }

export interface Message {
  id: string; thread: string; sim: number; address: string; body: string;
  dir: "INCOMING" | "OUTGOING"; status: "PENDING" | "SENT" | "DELIVERED" | "FAILED"; ts: number; read: boolean; requestId?: string;
}

export interface Thread { id: string; address: string; messages: Message[]; pinned?: boolean }

export type CallDirection = "incoming" | "outgoing" | "missed" | "rejected";
export interface CallEntry { id: string; sim: number; address: string; name?: string; dir: CallDirection; startedAt: number; duration: number }

export interface LiveCall {
  id: string; sim: number; address: string; name: string;
  state: "RINGING_INCOMING" | "DIALING_OUTGOING" | "ACTIVE" | "HOLDING" | "DISCONNECTED";
  startedAt: number; muted: boolean; outgoing: boolean; photo?: string; route: string;
}

export interface PhoneNotification {
  key: string; package_name: string; app_name: string; title: string; text: string; sub_text: string;
  posted_at_ms: number; app_icon_png: string; can_dismiss: boolean;
}

export interface Battery {
  battery_percent: number; is_charging: boolean; bluetooth_hfp_connected: boolean;
  storage_free_bytes: number; storage_total_bytes: number;
}

export interface ScheduledItem {
  id: string; kind: "sms" | "call"; address: string; body: string; sim?: number; fireAt: number;
  status: "pending" | "sent" | "failed" | "missed" | "cancelled"; autoRedial: boolean; note?: string; finishedAt?: number;
}

export interface PhoneData {
  sims: Sim[]; contacts: Contact[]; threads: Thread[]; calls: CallEntry[]; notifications: PhoneNotification[];
  battery?: Battery; scheduled: ScheduledItem[]; callLogAccess: boolean;
}

export const emptyPhone = (): PhoneData => ({
  sims: [], contacts: [], threads: [], calls: [], notifications: [], scheduled: [], callLogAccess: true,
});

export const FileUnit = (n: number) => {
  if (n < 1024) return `${n} B`;
  const u = ["KB", "MB", "GB", "TB"];
  let i = -1;
  do { n /= 1024; i++; } while (n >= 1024 && i < u.length - 1);
  return `${n.toFixed(n < 10 ? 1 : 0)} ${u[i]}`;
};

/** Digits with an optional leading "+": the form used to match numbers, threads and contacts. */
export function normalizeNumber(raw: string): string {
  const t = raw.trim();
  const digits = t.replace(/\D/g, "");
  if (!digits) return t;
  return t.startsWith("+") ? "+" + digits : digits;
}

export function isDialable(raw: string): boolean {
  const n = normalizeNumber(raw);
  const d = n.startsWith("+") ? n.slice(1) : n;
  return d.length >= 3 && d.length <= 15 && /^\d+$/.test(d);
}

export function prettyNumber(raw: string): string {
  const n = normalizeNumber(raw);
  if (!n.startsWith("+") || n.length <= 8) return raw;
  const digits = n.slice(1);
  const ccLen = digits[0] === "1" || digits[0] === "7" ? 1 : 2;
  const cc = digits.slice(0, ccLen);
  const rest = digits.slice(ccLen);
  if (cc === "1" && rest.length === 10) return `+1 (${rest.slice(0, 3)}) ${rest.slice(3, 6)}-${rest.slice(6)}`;
  const groups = rest.length === 10 ? [5, 5] : rest.length === 9 ? [3, 3, 3] : [rest.length];
  const parts: string[] = [];
  let i = 0;
  for (const g of groups) { if (i >= rest.length) break; parts.push(rest.slice(i, i + g)); i += g; }
  return `+${cc} ${parts.join(" ")}`;
}

export function otpIn(text: string): string | null {
  const m = /(?:code|otp|pin|password|verification)[^0-9]{0,24}(\d{4,8})/i.exec(text) ?? /\b(\d{6})\b/.exec(text);
  return m ? m[1] : null;
}

export function formatDuration(sec: number): string {
  const s = Math.max(0, Math.round(sec));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60;
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}:${String(r).padStart(2, "0")}` : `${m}:${String(r).padStart(2, "0")}`;
}

export function timeLabel(ts: number): string {
  const d = new Date(ts), now = new Date();
  if (d.toDateString() === now.toDateString()) return d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
  const y = new Date(now); y.setDate(now.getDate() - 1);
  if (d.toDateString() === y.toDateString()) return "Yesterday";
  if (now.getTime() - ts < 6 * 864e5) return d.toLocaleDateString([], { weekday: "long" });
  return d.toLocaleDateString([], { year: "numeric", month: "short", day: "numeric" });
}

/** Limits that keep auto-redial from turning into harassment or a runaway loop. */
export const RedialLimits = { minDelay: 5, maxAttempts: 20, delays: [5, 10, 15, 30, 60, 120, 300], attempts: [3, 5, 10, 20] };
export const ScheduleLimits = { maxPending: 100, minLead: 10_000, maxLead: 366 * 864e5, maxBody: 1600 };

const NOT_NAMES = new Set(["desktop", "laptop", "pc", "ubuntu", "debian", "fedora", "arch", "mint", "localhost", "macbook", "imac", "mac", "windows", "win", "user", "admin", "root", "home", "work", "my", "the", "dell", "hp", "lenovo", "asus", "acer", "surface", "thinkpad"]);
const DEVICE_WORDS = /^(macbook|imac|mac|laptop|desktop|pc|air|pro|mini|studio|book|notebook|workstation|computer)/i;

/** A first name guessed from the computer's name ("Saraths-MacBook-Pro" gives "Sarath"), or "" when it holds none ("DESKTOP-4F2K9"). */
export function nameFromMachine(machine: string): string {
  const parts = machine.replace(/\.(local|lan|home)$/i, "").split(/[\s\-_.’'`]+/).filter(Boolean);
  if (!parts.length) return "";
  let t = parts[0];
  const next = parts[1] ?? "";
  // "Saraths-MacBook": a possessive whose apostrophe was dropped.
  if (DEVICE_WORDS.test(next) && /s$/i.test(t) && t.length > 3) t = t.slice(0, -1);
  if (NOT_NAMES.has(t.toLowerCase()) || !/^\p{L}{2,}$/u.test(t)) return "";
  if (/\d/.test(t)) return "";
  return t.charAt(0).toUpperCase() + t.slice(1).toLowerCase();
}
