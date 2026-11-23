import { useEffect, useMemo, useState } from "react";
import { Ban, CalendarClock, Delete, MessageSquare, MoreHorizontal, Phone, PhoneIncoming, PhoneMissed, PhoneOff, PhoneOutgoing, Repeat, Users } from "lucide-react";
import { callAction, cancelRedial, contactFor, currentData, displayName, notify, placeCall, redialNow, startRedial, state, useStore } from "../lib/store";
import { formatDuration, isDialable, normalizeNumber, prettyNumber, timeLabel, type CallEntry } from "../lib/model";
import { Avatar, Empty, SearchField, Seg, SimChips, SimTag } from "../lib/ui";
import { ScheduleDialog } from "./Scheduled";

const ICON: Record<CallEntry["dir"], JSX.Element> = {
  incoming: <PhoneIncoming size={13} />, outgoing: <PhoneOutgoing size={13} />, missed: <PhoneMissed size={13} />, rejected: <Ban size={13} />,
};
const LABEL: Record<CallEntry["dir"], string> = { incoming: "Incoming", outgoing: "Outgoing", missed: "Missed", rejected: "Declined" };
function dayGroup(ts: number): string {
  const d = new Date(ts), now = new Date();
  const y = new Date(now); y.setDate(now.getDate() - 1);
  if (d.toDateString() === now.toDateString()) return "Today";
  if (d.toDateString() === y.toDateString()) return "Yesterday";
  return "Earlier";
}

export function Calls() {
  const [tab, setTab] = useState<"recents" | "contacts">("recents");
  return (
    <div className="pane main-pane" style={{ height: "100%" }}>
      <div className="tabbar">
        <Seg value={tab} onChange={setTab} options={[["recents", "Recents & Dialer"], ["contacts", "Contacts"]]} />
      </div>
      <div style={{ flex: 1, minHeight: 0 }}>
        {tab === "recents" ? <div className="split" style={{ gridTemplateColumns: "400px 1fr" }}><Recents /><div className="pane main-pane"><Dialer /></div></div> : <Contacts />}
      </div>
    </div>
  );
}

function Recents() {
  const phoneId = useStore((s) => s.selected);
  const d = useStore(() => currentData());
  const [q, setQ] = useState("");
  const [missed, setMissed] = useState(false);
  const rows = useMemo(() => d.calls.filter((c) => (!missed || c.dir === "missed" || c.dir === "rejected") &&
    (!q || (c.name ?? displayName(phoneId, c.address)).toLowerCase().includes(q.toLowerCase()) || c.address.includes(q))), [d.calls, q, missed, phoneId]);
  const groups: [string, CallEntry[]][] = [];
  for (const c of rows) { const g = dayGroup(c.startedAt); const last = groups.at(-1); if (last && last[0] === g) last[1].push(c); else groups.push([g, [c]]); }
  return (
    <div className="pane">
      <div className="head"><div className="row"><h2 className="grow">Recents</h2><button className="icon"><MoreHorizontal size={19} /></button></div>
        <SearchField value={q} onChange={setQ} placeholder="Search calls" />
        <Seg value={missed ? 1 : 0} onChange={(v) => setMissed(v === 1)} options={[[0, "All"], [1, "Missed"]]} /></div>
      <div className="list">
        {rows.length === 0 && (d.callLogAccess
          ? <Empty icon={<Phone size={32} />} title="No calls" message="Calls made or received on any SIM will show here." />
          : <Empty icon={<PhoneOff size={32} />} title="Phone has not shared its call history" message={'On the phone, open PhonePigeon, tap "Allow call history" under Calls, and allow Call logs.'} />)}
        {groups.map(([g, list]) => (
          <div key={g}>
            <div className="group-h">{g}</div>
            {list.map((c) => {
              const name = c.name ?? displayName(phoneId, c.address);
              return (
                <div key={c.id} className="item" onDoubleClick={() => placeCall(c.address, c.sim)} title="Double-click to call back">
                  <Avatar name={name} contact={contactFor(phoneId, c.address)} size={46} />
                  <div className="grow"><div className="title" style={{ color: c.dir === "missed" ? "var(--red)" : undefined }}>{name}</div>
                    <div className="row small muted" style={{ gap: 6 }}>{ICON[c.dir]}<span>{LABEL[c.dir]}{c.duration ? ` · ${formatDuration(c.duration)}` : ""}</span><SimTag sims={d.sims} subId={c.sim} /></div></div>
                  <span className="time">{c.startedAt && dayGroup(c.startedAt) !== "Earlier" ? new Date(c.startedAt).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }) : timeLabel(c.startedAt)}</span>
                </div>
              );
            })}
          </div>
        ))}
      </div>
    </div>
  );
}

const KEYS: [string, string][] = [["1", ""], ["2", "ABC"], ["3", "DEF"], ["4", "GHI"], ["5", "JKL"], ["6", "MNO"], ["7", "PQRS"], ["8", "TUV"], ["9", "WXYZ"], ["*", ""], ["0", "+"], ["#", ""]];

function Dialer() {
  const d = useStore(() => currentData());
  const settings = useStore((s) => s.settings);
  const [num, setNum] = useState("");
  const [sim, setSim] = useState<number | undefined>();
  const [redial, setRedial] = useState(false);
  const [sched, setSched] = useState(false);
  const q = num.trim().toLowerCase();
  const names = q && !/^[+\d\s()*#-]+$/.test(num)
    ? d.contacts.filter((c) => c.display_name.toLowerCase().includes(q)).flatMap((c) => c.phone_numbers.map((n) => ({ c, n }))).slice(0, 6) : [];
  const call = () => { if (!isDialable(num)) return; if (redial) startRedial(num, sim); else placeCall(num, sim); setNum(""); };
  return (
    <div className="dialer">
      <input className="num" autoFocus placeholder="Enter number" value={num} onChange={(e) => setNum(e.target.value)} onKeyDown={(e) => { if (e.key === "Enter") call(); }} />
      {names.length > 0 && <div className="card" style={{ width: 360, padding: 4 }}>{names.map(({ c, n }) => (
        <div key={c.contact_id + n} className="item" onClick={() => setNum(n)}><Avatar name={c.display_name} contact={c} size={30} /><div className="grow"><div className="title">{c.display_name}</div><div className="sub">{prettyNumber(n)}</div></div></div>))}</div>}
      <div className="keys">{KEYS.map(([k, sub]) => <button key={k} className="key" onClick={() => setNum(num + k)}>{k}<small>{sub}</small></button>)}</div>
      <SimChips sims={d.sims} value={sim ?? d.sims.find((s) => s.is_default_voice)?.subscription_id} onChange={setSim} />
      <label className="row small muted" style={{ cursor: "pointer" }}><Repeat size={15} /> Auto-redial
        <input type="checkbox" checked={redial} onChange={(e) => setRedial(e.target.checked)} />
        <span>{redial ? `every ${settings.autoRedialDelay}s, up to ${settings.autoRedialMaxAttempts}×` : "off"}</span></label>
      <div className="row" style={{ gap: 22 }}>
        <button className="icon" title="Schedule a call or text" onClick={() => setSched(true)}><CalendarClock size={22} /></button>
        <button className="callbtn" disabled={!isDialable(num)} onClick={call} aria-label="Call"><Phone size={32} fill="currentColor" /></button>
        <button className="icon" title="Backspace" onClick={() => setNum(num.slice(0, -1))}><Delete size={22} /></button>
      </div>
      {sched && <ScheduleDialog initialAddress={isDialable(num) ? normalizeNumber(num) : ""} onClose={() => setSched(false)} />}
    </div>
  );
}

function Contacts() {
  const d = useStore(() => currentData());
  const [q, setQ] = useState("");
  const [sel, setSel] = useState<string | undefined>();
  const list = useMemo(() => [...d.contacts].filter((c) => !q || c.display_name.toLowerCase().includes(q.toLowerCase()) || c.phone_numbers.some((n) => n.includes(q)))
    .sort((a, b) => a.display_name.localeCompare(b.display_name)), [d.contacts, q]);
  const grouped: [string, typeof list][] = [];
  for (const c of list) { const k = /^\p{L}/u.test(c.display_name) ? c.display_name[0].toUpperCase() : "#"; const l = grouped.at(-1); if (l && l[0] === k) l[1].push(c); else grouped.push([k, [c]]); }
  const c = d.contacts.find((x) => x.contact_id === sel);
  return (
    <div className="split" style={{ gridTemplateColumns: "340px 1fr" }}>
      <div className="pane">
        <div className="head"><div className="row"><h2 className="grow">Contacts</h2><span className="muted">{d.contacts.length}</span></div><SearchField value={q} onChange={setQ} placeholder="Search contacts" /></div>
        <div className="list">
          {list.length === 0 && <Empty icon={<Users size={32} />} title="No contacts yet" message="Contacts sync from your phone after pairing." />}
          {grouped.map(([letter, items]) => (
            <div key={letter}>
              <div className="group-h">{letter}</div>
              {items.map((x) => (
                <div key={x.contact_id} className={"item" + (x.contact_id === sel ? " sel" : "")} onClick={() => setSel(x.contact_id)}>
                  <Avatar name={x.display_name} contact={x} size={36} />
                  <div className="grow"><div className="title">{x.display_name}</div>
                    <div className="sub">{prettyNumber(x.phone_numbers[0] ?? "")}{x.phone_numbers.length > 1 ? `  ·  +${x.phone_numbers.length - 1} more` : ""}</div></div>
                </div>
              ))}
            </div>
          ))}
        </div>
      </div>
      <div className="pane main-pane" style={{ alignItems: "center", padding: 28, overflow: "auto" }}>
        {!c ? <Empty icon={<Users size={32} />} title="Select a contact" message="Call or text anyone from your phone's address book, from either SIM." /> : (
          <div style={{ width: "min(440px, 100%)", display: "flex", flexDirection: "column", gap: 14, alignItems: "center", marginTop: 30 }}>
            <Avatar name={c.display_name} contact={c} size={108} />
            <h2 style={{ margin: 0, fontSize: 28, fontWeight: 800 }}>{c.display_name}</h2>
            {c.phone_numbers.map((n) => (
              <div key={n} className="card row" style={{ width: "100%" }}>
                <div className="grow"><div className="small muted">mobile</div><div style={{ userSelect: "text", fontWeight: 600 }}>{prettyNumber(n)}</div></div>
                <button className="round" title="Message" onClick={() => { state.selectedThread = normalizeNumber(n); state.section = "messages"; notify(); }}><MessageSquare size={16} /></button>
                <button className="round" style={{ background: "var(--green-d)", color: "#fff" }} title="Call" onClick={() => placeCall(n)}><Phone size={16} fill="currentColor" /></button>
              </div>
            ))}
            {d.calls.filter((x) => c.phone_numbers.includes(normalizeNumber(x.address))).slice(0, 5).map((x) => <div key={x.id} className="row small muted">{ICON[x.dir]} {LABEL[x.dir]} · {timeLabel(x.startedAt)}</div>)}
          </div>
        )}
      </div>
    </div>
  );
}

/** The call card: small by default, full-window when enabled in Settings. */
export function ActiveCall() {
  const phoneId = useStore((s) => Object.keys(s.live).find((id) => s.live[id]));
  const call = useStore((s) => (phoneId ? s.live[phoneId] : undefined));
  const full = useStore((s) => s.settings.fullWindowCalls);
  const [, tick] = useState(0);
  useEffect(() => { const t = setInterval(() => tick((x) => x + 1), 1000); return () => clearInterval(t); }, []);
  const [dtmf, setDtmf] = useState(false);
  if (!call || !phoneId) return null;
  const name = call.name || prettyNumber(call.address);
  const connected = call.state === "ACTIVE" || call.state === "HOLDING";
  const status = call.state === "RINGING_INCOMING" ? "Incoming call" : call.state === "DIALING_OUTGOING" ? "Calling…" : formatDuration((Date.now() - call.startedAt) / 1000);
  const photo = call.photo ? `data:image/jpeg;base64,${call.photo}` : undefined;
  const body = (
    <>
      {photo ? <div className="avatar" style={{ width: full ? 140 : 64, height: full ? 140 : 64 }}><img src={photo} alt="" /></div> : <Avatar name={name} size={full ? 140 : 64} />}
      <div className={full ? "who" : "title"} style={{ fontWeight: 700, fontSize: full ? undefined : 18 }}>{name}</div>
      <div className={full ? "" : "muted"}>{status}{connected ? " · audio on phone" : ""}</div>
      {dtmf && <div className="keys" style={{ gridTemplateColumns: "repeat(3, 52px)", gap: 8 }}>{KEYS.map(([k]) => <button key={k} className="key" style={{ height: 52, fontSize: 20 }} onClick={() => callAction("SEND_DTMF", k)}>{k}</button>)}</div>}
      <div className="ctrl">
        {call.state === "RINGING_INCOMING" ? (<><button className="danger" onClick={() => callAction("REJECT")}><PhoneOff size={16} /> Decline</button><button className="primary" style={{ background: "var(--green-d)" }} onClick={() => callAction("ANSWER")}><Phone size={16} fill="currentColor" /> Answer</button></>) : (<>
          <button onClick={() => callAction("TOGGLE_MUTE")}>{call.muted ? "Unmute" : "Mute"}</button>
          <button onClick={() => setDtmf(!dtmf)}>Keypad</button>
          <button className="danger" onClick={() => callAction("END_CALL")}><PhoneOff size={16} /> End</button></>)}
      </div>
    </>
  );
  return full ? <div className="callfull">{body}</div> : <div className="callcard">{body}</div>;
}

export function RedialBanner() {
  const r = useStore((s) => s.redial);
  const [, tick] = useState(0);
  useEffect(() => { const t = setInterval(() => tick((x) => x + 1), 500); return () => clearInterval(t); }, []);
  if (!r) return null;
  const left = r.nextAt ? Math.max(0, Math.ceil((r.nextAt - Date.now()) / 1000)) : 0;
  return (
    <div className="banner">
      <span>🔁</span>
      <span>{prettyNumber(r.number)} · attempt {r.attempt} of {r.max}{r.nextAt ? ` · next in ${left}s` : " · calling…"}</span>
      {r.nextAt && <button onClick={redialNow}>Call now</button>}
      <button className="danger" onClick={cancelRedial}>Stop</button>
    </div>
  );
}

