import type { ReactNode } from "react";
import { Bird, Search } from "lucide-react";
import { mediaUrl } from "./api";
import type { Contact, Sim } from "./model";

/** Same avatar palettes as the Mac app (two-stop diagonal gradients picked from the name). */
const palettes: [string, string][] = [
  ["#FF8A65", "#F4511E"], ["#7986CB", "#3949AB"], ["#4DB6AC", "#00897B"], ["#BA68C8", "#8E24AA"],
  ["#F06292", "#D81B60"], ["#64B5F6", "#1E88E5"], ["#FFD54F", "#FB8C00"], ["#81C784", "#43A047"],
];
export function paletteFor(name: string): [string, string] {
  let h = 5381;
  for (const ch of name) h = ((h * 33) ^ ch.codePointAt(0)!) >>> 0;
  return palettes[h % palettes.length];
}
export function colorFor(name: string): string { return paletteFor(name)[1]; }

export function Avatar({ name, contact, size = 40, icon }: { name: string; contact?: Contact; size?: number; icon?: ReactNode }) {
  const [a, b] = paletteFor(name);
  const letters = (name.match(/\p{L}|\d/gu) ?? []);
  const initials = (name.trim().includes(" ") ? [letters[0], name.trim().split(/\s+/).at(-1)!.charAt(0)] : letters.slice(0, 2)).join("").toUpperCase();
  const numeric = /^[+\d\s()-]+$/.test(name);
  const src = contact?.thumbnail_jpeg ? `data:image/jpeg;base64,${contact.thumbnail_jpeg}` : undefined;
  return (
    <div className="avatar" style={{ width: size, height: size, background: numeric ? "linear-gradient(135deg,#64B5F6,#1E88E5)" : `linear-gradient(135deg, ${a}, ${b})`, fontSize: size * 0.38 }}>
      {src ? <img src={src} alt="" /> : numeric ? (icon ?? <svg width={size * 0.5} height={size * 0.5} viewBox="0 0 24 24" fill="#fff"><circle cx="12" cy="8" r="4.2" /><path d="M4 21c0-4.2 3.6-7 8-7s8 2.8 8 7z" /></svg>) : initials}
    </div>
  );
}

export function Empty({ title, message, action, icon }: { title: string; message?: string; action?: ReactNode; icon?: ReactNode }) {
  return (
    <div className="empty">
      <div className="ico">{icon ?? <Bird size={34} />}</div>
      <h3>{title}</h3>
      {message && <div>{message}</div>}
      {action && <div style={{ marginTop: 14 }}>{action}</div>}
    </div>
  );
}

export function Modal({ title, onClose, children }: { title: string; onClose: () => void; children: ReactNode }) {
  return (
    <div className="overlay" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="modal" role="dialog" aria-label={title}>
        <h3>{title}</h3>
        {children}
      </div>
    </div>
  );
}

export function Seg<T extends string | number>({ value, options, onChange }: { value: T; options: [T, string][]; onChange: (v: T) => void }) {
  return (
    <div className="seg" role="tablist">
      {options.map(([v, label]) => (
        <button key={String(v)} className={v === value ? "on" : ""} onClick={() => onChange(v)}>{label}</button>
      ))}
    </div>
  );
}

/** Slot index of a SIM: the Mac app colors SIM 1 blue and SIM 2 orange. */
export const slotOf = (sims: Sim[], subId: number) => Math.max(0, sims.find((s) => s.subscription_id === subId)?.slot_index ?? 0);

export function SimTag({ sims, subId, label }: { sims: Sim[]; subId: number; label?: string }) {
  const s = sims.find((x) => x.subscription_id === subId);
  if (!s) return null;
  return <span className={"sim-chip" + (s.slot_index > 0 ? " s2" : "")}>{label ?? `SIM ${s.slot_index + 1}`}</span>;
}

export function SimChips({ sims, value, onChange, hint }: { sims: Sim[]; value?: number; onChange: (v: number | undefined) => void; hint?: boolean }) {
  if (sims.length < 2) return null;
  return (
    <div className="simbtns">
      {sims.map((s) => (
        <button key={s.subscription_id} className={`simbtn s${s.slot_index > 0 ? 2 : 1}` + (value === s.subscription_id ? " on" : "")}
          onClick={() => onChange(value === s.subscription_id ? undefined : s.subscription_id)}>
          {s.carrier_name}{hint ? <kbd> Ctrl {s.slot_index + 1}</kbd> : null}
        </button>
      ))}
    </div>
  );
}

export const Thumb = ({ phoneId, id, size = 320 }: { phoneId: string; id: number; size?: number }) => (
  <img loading="lazy" decoding="async" alt="" src={mediaUrl(phoneId, `/media/thumb/${id}`, { w: size, h: size })} />
);

export function datetimeLocal(ts: number): string {
  const d = new Date(ts - new Date(ts).getTimezoneOffset() * 60000);
  return d.toISOString().slice(0, 16);
}

export function SearchField({ value, onChange, placeholder }: { value: string; onChange: (v: string) => void; placeholder: string }) {
  return (
    <label className="search"><Search size={16} /><input placeholder={placeholder} value={value} onChange={(e) => onChange(e.target.value)} /></label>
  );
}
