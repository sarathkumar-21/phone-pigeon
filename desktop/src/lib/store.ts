import { useSyncExternalStore } from "react";
import { isPermissionGranted, requestPermission, sendNotification } from "@tauri-apps/plugin-notification";
import { api, on, uuid, type Body, type NearbyPhone, type NearbyState, type PhoneInfo, type TransferEvent } from "./api";
import {
  emptyPhone, isDialable, nameFromMachine, normalizeNumber, otpIn, prettyNumber, RedialLimits, ScheduleLimits,
  type CallEntry, type Contact, type LiveCall, type Message, type PhoneData, type ScheduledItem,
} from "./model";

export type Section = "overview" | "messages" | "calls" | "photos" | "files" | "notifications" | "scheduled" | "settings";

export interface Settings {
  appearance: "system" | "light" | "dark";
  autoRedialDelay: number;
  autoRedialMaxAttempts: number;
  notifyMessages: boolean;
  notifyCalls: boolean;
  notifyPhone: boolean;
  fullWindowCalls: boolean;
  /** Name used in the greeting; empty means "guess it from this computer's name". */
  userName: string;
}

export interface ScreenInfo { state: string; width: number; height: number; message: string; control: boolean }

export interface RedialState {
  phoneId: string; number: string; sim: number; attempt: number; max: number; delay: number; nextAt?: number; callId?: string;
}

export interface Toast { id: string; text: string; kind: "info" | "success" | "error" | "warning" }

interface State {
  ready: boolean;
  phones: PhoneInfo[];
  selected?: string;
  section: Section;
  data: Record<string, PhoneData>;
  live: Record<string, LiveCall | undefined>;
  screen: Record<string, ScreenInfo>;
  settings: Settings;
  toast?: Toast;
  nearby: NearbyState;
  nearbyList: NearbyPhone[];
  transfers: Record<string, TransferEvent>;
  redial?: RedialState;
  addingPhone: boolean;
  selectedThread?: string;
  simFilter?: number;
  device: { name: string; fingerprint: string; lan_port: number };
}

const defaultSettings: Settings = {
  appearance: "system", autoRedialDelay: 30, autoRedialMaxAttempts: 5,
  notifyMessages: true, notifyCalls: true, notifyPhone: true, fullWindowCalls: false, userName: "",
};

export const state: State = {
  ready: false, phones: [], section: "messages", data: {}, live: {}, screen: {}, settings: { ...defaultSettings },
  nearby: { state: "idle" }, nearbyList: [], transfers: {}, addingPhone: false, device: { name: "", fingerprint: "", lan_port: 0 },
};

let version = 0;
const listeners = new Set<() => void>();
export function notify() { version++; listeners.forEach((l) => l()); }
export function useStore<T>(select: (s: State) => T): T {
  useSyncExternalStore((cb) => { listeners.add(cb); return () => listeners.delete(cb); }, () => version);
  return select(state);
}

// ---------------------------------------------------------------- helpers

export const selectedPhone = () => state.phones.find((p) => p.id === state.selected);
export const phoneData = (id?: string): PhoneData => (id ? (state.data[id] ??= emptyPhone()) : emptyPhone());
export const currentData = () => phoneData(state.selected);

export function toast(text: string, kind: Toast["kind"] = "info") {
  const t = { id: uuid(), text, kind };
  state.toast = t;
  notify();
  setTimeout(() => { if (state.toast?.id === t.id) { state.toast = undefined; notify(); } }, 3500);
}

export function contactFor(phoneId: string | undefined, address: string): Contact | undefined {
  const n = normalizeNumber(address);
  return phoneData(phoneId).contacts.find((c) => c.phone_numbers.some((p) => normalizeNumber(p) === n));
}
export function displayName(phoneId: string | undefined, address: string): string {
  return contactFor(phoneId, address)?.display_name ?? prettyNumber(address);
}

function parseSettings(raw: string): Settings {
  try { return { ...defaultSettings, ...JSON.parse(raw) }; } catch { return { ...defaultSettings }; }
}
export function saveSettings(patch: Partial<Settings>) {
  state.settings = { ...state.settings, ...patch };
  api.settingsSave(JSON.stringify(state.settings));
  applyTheme();
  notify();
}
export function applyTheme() {
  const a = state.settings.appearance;
  if (a === "system") document.documentElement.removeAttribute("data-theme");
  else document.documentElement.setAttribute("data-theme", a);
}

// ---------------------------------------------------------------- persistence

const saveTimers: Record<string, number> = {};
function persist(phoneId: string) {
  clearTimeout(saveTimers[phoneId]);
  saveTimers[phoneId] = window.setTimeout(() => {
    const d = phoneData(phoneId);
    // Keep the saved file bounded: recent history only.
    const snap = { ...d, notifications: d.notifications.slice(0, 200), calls: d.calls.slice(0, 500) };
    api.snapshotSave(phoneId, JSON.stringify(snap));
  }, 1500);
}
export const touch = (phoneId: string) => { persist(phoneId); notify(); };

async function loadSnapshot(phoneId: string) {
  if (state.data[phoneId]) return;
  const raw = await api.snapshotLoad(phoneId);
  try { state.data[phoneId] = raw ? { ...emptyPhone(), ...JSON.parse(raw) } : emptyPhone(); } catch { state.data[phoneId] = emptyPhone(); }
}

// ---------------------------------------------------------------- requests (control plane over the encrypted channel)

const pending = new Map<string, (v: any) => void>();
export function request<T = any>(build: (requestId: string) => Body): Promise<T> {
  const phone = state.selected;
  if (!phone) return Promise.reject(new Error("No phone selected"));
  const id = uuid();
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error("The phone didn't answer in time.")); }, 20_000);
    pending.set(id, (v) => { clearTimeout(timer); resolve(v); });
    api.send(phone, build(id)).then((ok) => { if (!ok) { clearTimeout(timer); pending.delete(id); reject(new Error("The phone is not connected.")); } });
  });
}

// ---------------------------------------------------------------- notifications

async function desktopNotify(title: string, body: string) {
  if (document.hasFocus()) return;
  try {
    if (!(await isPermissionGranted())) { if ((await requestPermission()) !== "granted") return; }
    sendNotification({ title, body });
  } catch { /* no notification service available */ }
}

// ---------------------------------------------------------------- applying inbound payloads

function threadKey(address: string) { return normalizeNumber(address); }

function insertMessage(phoneId: string, m: Message, announce: boolean) {
  const d = phoneData(phoneId);
  let t = d.threads.find((x) => x.id === m.thread);
  if (!t) { t = { id: m.thread, address: m.address, messages: [] }; d.threads.push(t); }
  if (t.messages.some((x) => x.id === m.id)) return;
  // Messages nearly always arrive in order: append, else find the slot.
  const last = t.messages[t.messages.length - 1];
  if (!last || last.ts <= m.ts) t.messages.push(m);
  else {
    let lo = 0, hi = t.messages.length;
    while (lo < hi) { const mid = (lo + hi) >> 1; if (t.messages[mid].ts <= m.ts) lo = mid + 1; else hi = mid; }
    t.messages.splice(lo, 0, m);
  }
  const viewing = state.selectedThread === t.id && state.section === "messages" && state.selected === phoneId && document.hasFocus();
  if (viewing) m.read = true;
  if (announce && !viewing && state.settings.notifyMessages) {
    const otp = otpIn(m.body);
    desktopNotify(displayName(phoneId, m.address), otp ? `${m.body}\n\nCode: ${otp}` : m.body);
  }
}

function toMessage(e: any): Message {
  return {
    id: e.local_id, thread: threadKey(e.address), sim: e.subscription_id, address: normalizeNumber(e.address), body: e.body ?? "",
    dir: e.direction, status: e.status, ts: Number(e.timestamp_ms), read: !!e.is_read,
  };
}

export function applyPayload(phoneId: string, body: Body) {
  const d = phoneData(phoneId);
  const [key, v] = Object.entries(body)[0] ?? [];
  switch (key) {
    case "sim_inventory":
      d.sims = [...(v.sims ?? [])].sort((a: any, b: any) => a.slot_index - b.slot_index);
      break;
    case "contact_sync": {
      const pos = new Map(d.contacts.map((c, i) => [c.contact_id, i]));
      for (const c of v.contacts ?? []) {
        const contact: Contact = { contact_id: c.contact_id, display_name: c.display_name, phone_numbers: (c.phone_numbers ?? []).map(normalizeNumber), thumbnail_jpeg: c.thumbnail_jpeg || undefined };
        const i = pos.get(c.contact_id);
        if (i !== undefined) d.contacts[i] = contact; else { pos.set(c.contact_id, d.contacts.length); d.contacts.push(contact); }
      }
      break;
    }
    case "sms_thread_sync":
      for (const m of v.messages ?? []) insertMessage(phoneId, toMessage(m), false);
      break;
    case "sms_message": {
      const m = toMessage(v);
      insertMessage(phoneId, m, m.dir === "INCOMING");
      break;
    }
    case "sms_status": {
      for (const t of d.threads) {
        const m = t.messages.find((x) => x.requestId === v.client_request_id);
        if (m) {
          m.status = v.status;
          if (v.status === "FAILED") toast(`Message to ${displayName(phoneId, t.address)} failed${v.error_reason ? `: ${v.error_reason}` : ""}`, "error");
          break;
        }
      }
      break;
    }
    case "call_state": applyCall(phoneId, v); break;
    case "call_log_sync": mergeCallLog(phoneId, v); break;
    case "device_status": d.battery = v; break;
    case "notification": {
      const n = { ...v, app_name: v.app_name || v.package_name };
      d.notifications = [n, ...d.notifications.filter((x) => x.key !== n.key)];
      if (state.settings.notifyPhone && n.package_name !== "com.android.systemui") desktopNotify(n.app_name + (n.title ? ` · ${n.title}` : ""), n.text);
      break;
    }
    case "notification_removed": d.notifications = d.notifications.filter((n) => n.key !== v.key); break;
    case "screen_status":
      state.screen[phoneId] = { state: v.state, width: v.width ?? 0, height: v.height ?? 0, message: v.message ?? "", control: !!v.control };
      if (v.state === "SCREEN_STREAMING") api.screenStart(phoneId).catch((e) => toast(String(e), "error"));
      else if (["SCREEN_DENIED", "SCREEN_STOPPED", "SCREEN_ERROR", "SCREEN_IDLE"].includes(v.state)) {
        api.screenStop(phoneId);
        if (v.state === "SCREEN_DENIED" || v.state === "SCREEN_ERROR") toast(v.message || "Screen mirroring was not started.", "warning");
      }
      break;
    case "list_dir_res": case "search_res": case "list_gallery_res": case "file_op_res":
      pending.get(v.request_id)?.(v); pending.delete(v.request_id);
      return notify();
    default: break;
  }
  touch(phoneId);
}

// ---------------------------------------------------------------- calls

function applyCall(phoneId: string, e: any) {
  const prev = state.live[phoneId];
  const outgoing = e.state === "DIALING_OUTGOING" || (prev?.outgoing ?? false);
  const live: LiveCall = {
    id: e.call_id, sim: e.subscription_id, address: normalizeNumber(e.remote_address),
    name: e.contact_name || contactFor(phoneId, e.remote_address)?.display_name || "",
    state: e.state, startedAt: Number(e.started_at_ms) || prev?.startedAt || Date.now(), muted: !!e.is_muted, outgoing,
    photo: e.photo_jpeg || prev?.photo, route: e.audio_route,
  };
  if (e.state === "RINGING_INCOMING" && prev?.id !== e.call_id && state.settings.notifyCalls) {
    desktopNotify("Incoming call", live.name || prettyNumber(live.address));
  }
  if (e.state === "DISCONNECTED") {
    const wasActive = prev?.state === "ACTIVE" || prev?.state === "HOLDING";
    const dur = e.duration_s ?? (wasActive ? Math.round((Date.now() - prev!.startedAt) / 1000) : 0);
    const entry: CallEntry = {
      id: e.call_id, sim: live.sim, address: live.address, name: live.name || undefined,
      dir: outgoing ? "outgoing" : wasActive ? "incoming" : "missed",
      startedAt: live.startedAt, duration: dur,
    };
    const d = phoneData(phoneId);
    if (!d.calls.some((c) => c.id === entry.id)) d.calls.unshift(entry);
    state.live[phoneId] = undefined;
    handleRedialEnd(phoneId, e, wasActive);
  } else {
    state.live[phoneId] = live;
  }
}

/** Folds the phone's own call history into Recents (newest 500; rows already known are skipped). */
function mergeCallLog(phoneId: string, sync: any) {
  const d = phoneData(phoneId);
  if (typeof sync.access_granted === "boolean") d.callLogAccess = sync.access_granted;
  const known = new Set(d.calls.map((c) => c.id));
  const live = d.calls.filter((c) => !c.id.startsWith("log-"));
  const replaced = new Set<string>();
  const fresh: CallEntry[] = [];
  const entries = [...(sync.entries ?? [])].sort((a: any, b: any) => Number(b.started_at_ms) - Number(a.started_at_ms)).slice(0, 500);
  for (const e of entries) {
    const id = "log-" + e.id;
    if (known.has(id)) continue;
    const address = normalizeNumber(e.remote_address);
    const started = Number(e.started_at_ms);
    const dir = ({ OUTGOING: "outgoing", MISSED: "missed", REJECTED: "rejected" } as const)[e.direction as "OUTGOING"] ?? "incoming";
    const name = contactFor(phoneId, address)?.display_name ?? (e.contact_name || undefined);
    const i = live.findIndex((c) => normalizeNumber(c.address) === address && Math.abs(c.startedAt - started) < 90_000);
    if (i >= 0) { replaced.add(live[i].id); live.splice(i, 1); }
    fresh.push({ id, sim: e.subscription_id, address, name, dir, startedAt: started, duration: Number(e.duration_s ?? 0) });
    known.add(id);
  }
  if (!fresh.length) return;
  d.calls = [...d.calls.filter((c) => !replaced.has(c.id)), ...fresh].sort((a, b) => b.startedAt - a.startedAt).slice(0, 500);
}

export function placeCall(address: string, sim?: number, redial?: { attempt: number }) {
  const phone = state.selected;
  if (!phone) return;
  if (!isDialable(address)) return toast("That doesn't look like a phone number.", "warning");
  const d = phoneData(phone);
  const simId = sim ?? d.sims.find((s) => s.is_default_voice)?.subscription_id ?? d.sims[0]?.subscription_id ?? -1;
  const wantsRedial = !!redial;
  api.send(phone, {
    place_call: { request_id: uuid(), subscription_id: simId, phone_number: normalizeNumber(address), route_audio_to_mac: false, report_outcome: wantsRedial },
  }).then((ok) => { if (!ok) toast("The phone is not connected.", "error"); });
}

export function callAction(action: "ANSWER" | "REJECT" | "END_CALL" | "TOGGLE_MUTE" | "SEND_DTMF", dtmf = "") {
  const phone = state.selected ?? Object.keys(state.live).find((id) => state.live[id]);
  const call = phone ? state.live[phone] : undefined;
  if (!phone || !call) return;
  if (action === "END_CALL" || action === "REJECT") cancelRedial();
  api.send(phone, { call_action: { call_id: call.id, action, dtmf_digit: dtmf, target_audio_route: "AUDIO_ROUTE_UNSPECIFIED" } });
}

// ---------------------------------------------------------------- auto-redial

let redialTimer: number | undefined;

export function startRedial(address: string, sim?: number) {
  const phone = state.selected;
  if (!phone) return;
  const d = phoneData(phone);
  const simId = sim ?? d.sims.find((s) => s.is_default_voice)?.subscription_id ?? d.sims[0]?.subscription_id ?? -1;
  const max = Math.min(state.settings.autoRedialMaxAttempts, RedialLimits.maxAttempts);
  const delay = Math.max(state.settings.autoRedialDelay, RedialLimits.minDelay);
  state.redial = { phoneId: phone, number: normalizeNumber(address), sim: simId, attempt: 1, max, delay };
  notify();
  placeCall(address, simId, { attempt: 1 });
}

export function cancelRedial() {
  clearTimeout(redialTimer);
  if (state.redial) { state.redial = undefined; notify(); }
}

export function redialNow() {
  const r = state.redial;
  if (!r) return;
  clearTimeout(redialTimer);
  r.nextAt = undefined;
  r.attempt += 1;
  notify();
  placeCall(r.number, r.sim, { attempt: r.attempt });
}

function handleRedialEnd(phoneId: string, e: any, wasActive: boolean) {
  const r = state.redial;
  if (!r || r.phoneId !== phoneId) return;
  // answered === true or a call that connected = done; undefined with no connection counts as unanswered.
  const answered = e.answered === true || (e.answered === undefined && wasActive);
  if (answered) { toast(`${prettyNumber(r.number)} answered`, "success"); state.redial = undefined; return; }
  if (r.attempt >= r.max) { toast(`No answer after ${r.attempt} attempts`, "warning"); state.redial = undefined; return; }
  r.nextAt = Date.now() + r.delay * 1000;
  clearTimeout(redialTimer);
  redialTimer = window.setTimeout(redialNow, r.delay * 1000);
}

// ---------------------------------------------------------------- messages & scheduler

export function sendText(address: string, body: string, sim?: number): boolean {
  const phone = state.selected;
  if (!phone || !body.trim()) return false;
  const d = phoneData(phone);
  const to = normalizeNumber(address);
  const t = threadKey(to);
  const simId = sim ?? d.threads.find((x) => x.id === t)?.messages.at(-1)?.sim ?? d.sims.find((s) => s.is_default_sms)?.subscription_id ?? d.sims[0]?.subscription_id ?? -1;
  const requestId = uuid();
  insertMessage(phone, { id: "local-" + requestId, thread: t, sim: simId, address: to, body, dir: "OUTGOING", status: "PENDING", ts: Date.now(), read: true, requestId }, false);
  api.send(phone, { send_sms: { client_request_id: requestId, subscription_id: simId, recipient_address: to, body } }).then((ok) => {
    if (!ok) {
      const m = d.threads.find((x) => x.id === t)?.messages.find((x) => x.requestId === requestId);
      if (m) m.status = "FAILED";
      toast("The phone is not connected, so the message was not sent.", "error");
      touch(phone);
    }
  });
  touch(phone);
  return true;
}

export function markRead(phoneId: string, threadId: string) {
  const t = phoneData(phoneId).threads.find((x) => x.id === threadId);
  if (t?.messages.some((m) => !m.read)) { t.messages.forEach((m) => (m.read = true)); touch(phoneId); }
}

export function unreadTotal(phoneId?: string): number {
  return phoneData(phoneId).threads.reduce((n, t) => n + t.messages.filter((m) => !m.read && m.dir === "INCOMING").length, 0);
}

export function schedule(item: Omit<ScheduledItem, "id" | "status">): string | null {
  const phone = state.selected;
  if (!phone) return "No phone selected";
  const d = phoneData(phone);
  const lead = item.fireAt - Date.now();
  if (!isDialable(item.address)) return "That doesn't look like a phone number.";
  if (lead < ScheduleLimits.minLead) return "Pick a time at least 10 seconds from now.";
  if (lead > ScheduleLimits.maxLead) return "Pick a time within the next year.";
  if (item.kind === "sms" && (!item.body.trim() || item.body.length > ScheduleLimits.maxBody)) return "Write a message (up to 1600 characters).";
  if (d.scheduled.filter((s) => s.status === "pending").length >= ScheduleLimits.maxPending) return "Too many scheduled items.";
  d.scheduled.push({ ...item, id: uuid(), status: "pending", address: normalizeNumber(item.address) });
  touch(phone);
  return null;
}

/** Runs once a second: fires due items for connected phones; one text per pass so a backlog never floods the phone. */
function runScheduler() {
  const now = Date.now();
  for (const p of state.phones) {
    const d = state.data[p.id];
    if (!d) continue;
    let sentText = false;
    for (const s of d.scheduled) {
      if (s.status !== "pending" || s.fireAt > now) continue;
      const late = now - s.fireAt;
      if (late > (s.kind === "sms" ? 300_000 : 120_000)) { s.status = "missed"; s.finishedAt = now; s.note = "Not sent: the app was closed or the phone was offline."; touch(p.id); continue; }
      if (!p.connected) continue;
      if (s.kind === "sms") {
        if (sentText) continue;
        sentText = true;
        const prevSel = state.selected; state.selected = p.id;
        sendText(s.address, s.body, s.sim);
        state.selected = prevSel;
      } else {
        if (state.live[p.id]) continue;
        const prevSel = state.selected; state.selected = p.id;
        if (s.autoRedial) startRedial(s.address, s.sim); else placeCall(s.address, s.sim);
        state.selected = prevSel;
      }
      s.status = "sent"; s.finishedAt = now; touch(p.id);
    }
  }
}

// ---------------------------------------------------------------- startup

export async function selectPhone(id: string) {
  await loadSnapshot(id);
  state.selected = id;
  state.addingPhone = false;
  state.selectedThread = undefined;
  notify();
}

export async function init() {
  state.settings = parseSettings(await api.settingsLoad());
  applyTheme();
  state.device = await api.deviceInfo();
  state.phones = await api.phones();
  for (const p of state.phones) await loadSnapshot(p.id);
  state.selected = state.phones[0]?.id;
  // Design preview only: `#calls` or `#messages:+919845012345` opens that screen (used to take README screenshots).
  if ((window as any).__PIGEON_PREVIEW__) {
    const [sec, thread] = location.hash.slice(1).split(":");
    if (sec) state.section = sec as Section;
    if (thread) state.selectedThread = decodeURIComponent(thread);
  }
  state.ready = true;
  notify();

  await on<PhoneInfo[]>("phones", async (list) => {
    state.phones = list;
    for (const p of list) await loadSnapshot(p.id);
    if (!state.selected || !list.some((p) => p.id === state.selected)) state.selected = list[0]?.id;
    notify();
  });
  await on<{ phone_id: string; body: Body }>("payload", (e) => applyPayload(e.phone_id, e.body));
  await on<NearbyState>("nearby", (s) => { state.nearby = s; notify(); });
  await on<NearbyPhone[]>("nearby_list", (l) => { state.nearbyList = l; notify(); });
  await on<string>("paired", async (id) => { await loadSnapshot(id); state.selected = id; state.addingPhone = false; state.section = "overview"; notify(); toast("Paired", "success"); });
  await on<TransferEvent>("transfer", (t) => { state.transfers[t.id] = t; notify(); });
  state.nearbyList = await api.nearbyPhones();
  setInterval(runScheduler, 1000);
  setInterval(() => notify(), 30_000); // relative times and countdowns
}

export const hasPhones = () => state.phones.length > 0;

/** The name to greet: the one the user typed, else a guess from the computer's name, else nothing. */
export function greetingName(): string {
  return state.settings.userName.trim() || nameFromMachine(state.device.name);
}

export const otpHint = otpIn;
