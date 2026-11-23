import { useState } from "react";
import { currentData, notify, schedule, state, touch, useStore, displayName } from "../lib/store";
import { prettyNumber, type ScheduledItem } from "../lib/model";
import { CalendarClock, Clock, MessageSquare, Phone, Plus, Repeat, Send, X } from "lucide-react";
import { Empty, Modal, Seg, SimChips, SimTag, datetimeLocal } from "../lib/ui";

const LABEL: Record<ScheduledItem["status"], string> = { pending: "Scheduled", sent: "Done", failed: "Failed", missed: "Missed", cancelled: "Cancelled" };

export function Scheduled() {
  const d = useStore(() => currentData());
  const phoneId = useStore((s) => s.selected);
  const [adding, setAdding] = useState(false);
  const items = [...d.scheduled].sort((a, b) => (a.status === "pending" ? 0 : 1) - (b.status === "pending" ? 0 : 1) || a.fireAt - b.fireAt);
  const upcoming = items.filter((i) => i.status === "pending"), done = items.filter((i) => i.status !== "pending");
  const when = (ms: number) => {
    const diff = ms - Date.now();
    if (diff <= 0) return "now";
    const m = Math.round(diff / 60000);
    return m < 60 ? `in ${m} min` : m < 1440 ? `in ${Math.round(m / 60)} hour${Math.round(m / 60) === 1 ? "" : "s"}` : `in ${Math.round(m / 1440)} day${Math.round(m / 1440) === 1 ? "" : "s"}`;
  };
  const row = (s: ScheduledItem) => (
    <div key={s.id} className="item">
      <div className="sched-ic">{s.kind === "sms" ? <MessageSquare size={18} fill="currentColor" /> : <Phone size={18} fill="currentColor" />}</div>
      <div className="grow">
        <div className="row" style={{ gap: 8 }}><span className="title">{displayName(phoneId, s.address)}</span>{s.sim !== undefined && <SimTag sims={d.sims} subId={s.sim} />}{s.autoRedial && <Repeat size={13} className="muted" />}</div>
        <div className="sub" style={{ WebkitLineClamp: 1 }}>{s.kind === "sms" ? s.body : "Call"}</div>
        <div className="row small muted" style={{ gap: 5 }}><Clock size={12} /> {new Date(s.fireAt).toLocaleString([], { dateStyle: "medium", timeStyle: "short" })}{s.status === "pending" ? ` · ${when(s.fireAt)}` : ` · ${LABEL[s.status]}`}{s.note ? ` — ${s.note}` : ""}</div>
      </div>
      {s.status === "pending" && <>
        <button className="round" style={{ color: "var(--green)" }} title="Run now" onClick={() => { s.fireAt = Date.now() - 1; if (phoneId) touch(phoneId); }}>{s.kind === "sms" ? <Send size={15} /> : <Phone size={15} fill="currentColor" />}</button>
        <button className="round" style={{ color: "var(--red)" }} title="Cancel" onClick={() => { s.status = "cancelled"; if (phoneId) touch(phoneId); notify(); }}><X size={16} /></button></>}
    </div>
  );
  return (
    <div className="pane main-pane" style={{ height: "100%" }}>
      <div className="head" style={{ flexDirection: "row", alignItems: "center", padding: "18px 22px 12px" }}>
        <div className="grow"><h2 style={{ fontSize: 22 }}>Scheduled</h2><div className="small muted">Texts and calls PhonePigeon sends later</div></div>
        {done.length > 0 && <button onClick={() => { d.scheduled = d.scheduled.filter((s) => s.status === "pending"); if (phoneId) touch(phoneId); }}>Clear finished</button>}
        <button className="primary" onClick={() => setAdding(true)}><Plus size={15} /> New</button></div>
      <div className="list" style={{ padding: "0 14px" }}>
        {items.length === 0 && <Empty icon={<CalendarClock size={32} />} title="Nothing scheduled" message="Schedule a text or call for later. The app must be open and the phone connected at that time; a text more than 5 minutes late is dropped." />}
        {upcoming.length > 0 && <div className="group-h">Upcoming</div>}
        {upcoming.map(row)}
        {done.length > 0 && <div className="group-h">Finished</div>}
        {done.map(row)}
      </div>
      {adding && <ScheduleDialog onClose={() => setAdding(false)} />}
    </div>
  );
}

export function ScheduleDialog({ initialAddress = "", onClose }: { initialAddress?: string; onClose: () => void }) {
  const sims = currentData().sims;
  const [kind, setKind] = useState<"sms" | "call">("sms");
  const [address, setAddress] = useState(initialAddress);
  const [body, setBody] = useState("");
  const [when, setWhen] = useState(datetimeLocal(Date.now() + 3600_000));
  const [sim, setSim] = useState<number | undefined>();
  const [redial, setRedial] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const q = address.trim().toLowerCase();
  const names = q && !/^[+\d\s()-]+$/.test(address) ? currentData().contacts.filter((c) => c.display_name.toLowerCase().includes(q)).flatMap((c) => c.phone_numbers.map((n) => ({ c, n }))).slice(0, 6) : [];
  const save = () => {
    const e = schedule({ kind, address, body: kind === "sms" ? body : "", sim, fireAt: new Date(when).getTime(), autoRedial: kind === "call" && redial });
    if (e) setErr(e); else { onClose(); state.section = "scheduled"; notify(); }
  };
  return (
    <Modal title="Schedule" onClose={onClose}>
      <Seg value={kind} onChange={setKind} options={[["sms", "Text"], ["call", "Call"]]} />
      <label className="field">To<input value={address} onChange={(e) => setAddress(e.target.value)} placeholder="Name or number" /></label>
      {names.map(({ c, n }) => <div key={c.contact_id + n} className="item" onClick={() => setAddress(n)}><div className="grow"><div className="title">{c.display_name}</div><div className="sub">{prettyNumber(n)}</div></div></div>)}
      {kind === "sms" && <label className="field">Message<textarea rows={4} value={body} onChange={(e) => setBody(e.target.value)} /></label>}
      <label className="field">When<input type="datetime-local" value={when} onChange={(e) => setWhen(e.target.value)} /></label>
      <SimChips sims={sims} value={sim} onChange={setSim} />
      {kind === "call" && <label className="row small"><input type="checkbox" checked={redial} onChange={(e) => setRedial(e.target.checked)} /> Redial until answered</label>}
      {err && <div style={{ color: "var(--red)" }}>{err}</div>}
      <div className="row"><div className="grow" /><button onClick={onClose}>Cancel</button><button className="primary" onClick={save}>Schedule</button></div>
    </Modal>
  );
}
