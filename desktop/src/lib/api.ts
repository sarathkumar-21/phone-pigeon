import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

export interface PhoneInfo {
  id: string;
  name: string;
  manufacturer: string;
  os_version: string;
  paired_at_ms: number;
  connected: boolean;
  host: string | null;
  fingerprint: string;
  media_ready: boolean;
}

export interface NearbyPhone { id: string; name: string; model: string }

export type NearbyState =
  | { state: "idle" }
  | { state: "connecting"; phone: string }
  | { state: "confirm"; phone: string; code: string }
  | { state: "finishing"; phone: string }
  | { state: "failed"; message: string };

export interface TransferEvent {
  id: string; name: string; direction: "download" | "upload"; total: number; done: number;
  state: "running" | "done" | "failed"; error?: string | null; path?: string | null;
}

/** One protocol body: a single-key object such as `{ send_sms: {...} }`. */
export type Body = Record<string, any>;

export const api = {
  phones: () => invoke<PhoneInfo[]>("phones"),
  deviceInfo: () => invoke<{ name: string; fingerprint: string; lan_port: number }>("device_info"),
  send: (phoneId: string, body: Body) => invoke<boolean>("send", { phoneId, body }),
  nearbyPhones: () => invoke<NearbyPhone[]>("nearby_phones"),
  nearbyState: () => invoke<NearbyState>("nearby_state"),
  nearbyBegin: (id: string) => invoke<void>("nearby_begin", { id }),
  nearbyConfirm: () => invoke<void>("nearby_confirm"),
  nearbyCancel: () => invoke<void>("nearby_cancel"),
  nearbyDismiss: () => invoke<void>("nearby_dismiss"),
  removePhone: (phoneId: string) => invoke<void>("remove_phone", { phoneId }),
  snapshotLoad: (phoneId: string) => invoke<string | null>("snapshot_load", { phoneId }),
  snapshotSave: (phoneId: string, json: string) => invoke<void>("snapshot_save", { phoneId, json }),
  settingsLoad: () => invoke<string>("settings_load"),
  settingsSave: (json: string) => invoke<void>("settings_save", { json }),
  mediaDownload: (a: { phoneId: string; id: string; path: string; mediaId?: number; name: string; size: number; toTemp?: boolean }) =>
    invoke<string>("media_download", { phoneId: a.phoneId, id: a.id, path: a.path, mediaId: a.mediaId ?? null, name: a.name, size: a.size, toTemp: a.toTemp ?? false }),
  mediaUpload: (phoneId: string, id: string, local: string, folder: string) => invoke<void>("media_upload", { phoneId, id, local, folder }),
  screenStart: (phoneId: string) => invoke<void>("screen_start", { phoneId }),
  screenStop: (phoneId: string) => invoke<void>("screen_stop", { phoneId }),
  revealInFolder: (path: string) => invoke<void>("reveal_in_folder", { path }),
};

export function on<T>(event: string, cb: (payload: T) => void): Promise<UnlistenFn> {
  return listen<T>(event, (e) => cb(e.payload));
}

const isWindows = typeof navigator !== "undefined" && /windows/i.test(navigator.userAgent);

/** URL of a phone file served through the app's pinned-TLS proxy (usable in `<img>` and `<video>`). */
export function mediaUrl(phoneId: string, path: string, query: Record<string, string | number> = {}): string {
  const base = isWindows ? "http://pigeon.localhost" : "pigeon://localhost";
  const q = Object.entries(query).map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`).join("&");
  return `${base}/${encodeURIComponent(phoneId)}${path}${q ? `?${q}` : ""}`;
}

export const uuid = () => crypto.randomUUID();
