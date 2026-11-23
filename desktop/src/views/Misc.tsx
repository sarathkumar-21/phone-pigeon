import { useState } from "react";
import { Pencil } from "lucide-react";
import { BellOff, Bell, Cast, CalendarDays, CreditCard, Grip, HardDrive, Headphones, MessageSquare, MessagesSquare, Phone, PhoneMissed, Radio, ShieldCheck, SquarePen, Users, X } from "lucide-react";
import { api } from "../lib/api";
import { NewMessage } from "./Messages";
import { currentData, greetingName, notify, otpHint, placeCall, saveSettings, selectedPhone, state, toast, touch, unreadTotal, useStore, displayName } from "../lib/store";
import { FileUnit, formatDuration, nameFromMachine, timeLabel, prettyNumber } from "../lib/model";
import { Avatar, Empty, Seg, SimTag } from "../lib/ui";
import { RedialLimits } from "../lib/model";

export function Notifications() {
  const d = useStore(() => currentData());
  const phoneId = useStore((s) => s.selected)!;
  return (
    <div className="pane main-pane" style={{ height: "100%" }}>
      <div className="head" style={{ padding: "20px 24px 10px" }}><div className="row"><div className="grow"><h2>Notifications</h2>
        <div className="small muted">Mirrored from your phone. Dismissing one here dismisses it on the phone too.</div></div>
        {d.notifications.length > 0 && <button onClick={() => { d.notifications.filter((n) => n.can_dismiss).forEach((n) => api.send(phoneId, { notification_dismiss: { key: n.key } })); d.notifications = []; touch(phoneId); }}><BellOff size={15} /> Clear all</button>}</div></div>
      <div className="list" style={{ padding: "0 16px" }}>
        {d.notifications.length === 0 && <Empty icon={<Bell size={32} />} title="No notifications" message="Notifications from apps on your phone show up here." />}
        {d.notifications.map((n) => (
          <div className="item" key={n.key}>
            {n.app_icon_png ? <img src={`data:image/png;base64,${n.app_icon_png}`} width={42} height={42} style={{ borderRadius: 10 }} alt="" /> : <Avatar name={n.app_name} size={42} />}
            <div className="grow"><div className="title">{n.title || n.app_name}</div><div className="sub">{n.text}</div>
              <div className="small muted" style={{ marginTop: 2 }}>{n.app_name} · {timeLabel(n.posted_at_ms)}{otpHint(n.text) ? ` · code ${otpHint(n.text)}` : ""}</div></div>
            {otpHint(n.text) && <button onClick={() => { navigator.clipboard.writeText(otpHint(n.text)!); toast("Code copied", "success"); }}>Copy code</button>}
            {n.can_dismiss && <button className="icon" onClick={() => { api.send(phoneId, { notification_dismiss: { key: n.key } }); d.notifications = d.notifications.filter((x) => x.key !== n.key); touch(phoneId); }}><X size={16} /></button>}
          </div>
        ))}
      </div>
    </div>
  );
}

/** ", Name" after the greeting, taken from the computer's name unless the user typed one. Click to edit; empty goes back to the guess. */
function GreetingName() {
  const name = useStore(() => greetingName());
  const custom = useStore((s) => s.settings.userName);
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState("");
  const begin = () => { setDraft(custom || name); setEditing(true); };
  const commit = () => { saveSettings({ userName: draft.trim().slice(0, 40) }); setEditing(false); };
  if (editing) {
    return (
      <>, <input className="greet-input" autoFocus value={draft} maxLength={40} placeholder="Your name" size={Math.max(8, draft.length + 1)}
        onChange={(e) => setDraft(e.target.value)} onBlur={commit}
        onKeyDown={(e) => { if (e.key === "Enter") commit(); if (e.key === "Escape") setEditing(false); }} /></>
    );
  }
  return (
    <span className="greet-name" onClick={begin} title="Click to change the name used in the greeting">
      {name ? `, ${name}` : ""}<button className={"icon greet-pencil" + (name ? "" : " show")} aria-label={name ? "Edit your name" : "Add your name"}><Pencil size={15} />{name ? null : <span className="small"> Add your name</span>}</button>
    </span>
  );
}

export function Overview() {
  const phone = useStore(() => selectedPhone());
  const d = useStore(() => currentData());
  const screen = useStore((s) => (s.selected ? s.screen[s.selected] : undefined));
  const [compose, setCompose] = useState(false);
  if (!phone) return null;
  const b = d.battery;
  const mirroring = screen && (screen.state === "SCREEN_WAITING" || screen.state === "SCREEN_STREAMING");
  const startMirror = () => {
    if (!phone.media_ready) return toast("The phone's local media server isn't reachable. Both devices need to be on the same Wi-Fi.", "warning");
    state.screen[phone.id] = { state: "SCREEN_WAITING", width: 0, height: 0, message: "Waiting for you to approve on your phone…", control: false };
    notify();
    api.send(phone.id, { screen_req: { action: "SCREEN_START", max_dimension: 1280 } });
    toast(`Approve screen sharing on ${phone.name}`, "info");
  };
  const stopMirror = () => { api.send(phone.id, { screen_req: { action: "SCREEN_STOP", max_dimension: 0 } }); api.screenStop(phone.id); state.screen[phone.id] = { state: "SCREEN_IDLE", width: 0, height: 0, message: "", control: false }; notify(); };
  const hour = new Date().getHours();
  const greeting = hour < 5 ? "Good night" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening";
  const today = new Date().toDateString();
  const unread = unreadTotal(phone.id);
  const missedToday = d.calls.filter((c) => (c.dir === "missed" || c.dir === "rejected") && new Date(c.startedAt).toDateString() === today).length;
  const callsToday = d.calls.filter((c) => new Date(c.startedAt).toDateString() === today).length;
  const recentThreads = [...d.threads].filter((t) => t.messages.length).sort((a, b) => b.messages.at(-1)!.ts - a.messages.at(-1)!.ts).slice(0, 4);
  const pct = b?.battery_percent ?? 0;
  const circ = 2 * Math.PI * 56;
  return (
    <div className="page">
      <div className="greet">
        <div className="grow"><h1>{greeting}<GreetingName /></h1><div className="d">{new Date().toLocaleDateString([], { weekday: "long", day: "numeric", month: "long", year: "numeric" })}</div></div>
        <button className="btn-pill" onClick={mirroring ? stopMirror : startMirror}><Cast size={17} /> {mirroring ? (screen!.state === "SCREEN_WAITING" ? "Waiting for phone…" : "Stop Mirroring") : "Mirror Screen"}</button>
        <button className="btn-pill" onClick={() => { state.section = "calls"; notify(); }}><Grip size={17} /> Dialer</button>
        <button className="btn-pill primary" onClick={() => setCompose(true)}><SquarePen size={16} /> Compose</button>
      </div>

      <div className="hero">
        <div className="mock"><div className="scr"><span className="notch" /><b>{new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", hour12: false })}</b>
          <small>{new Date().toLocaleDateString([], { weekday: "short", day: "numeric", month: "short" })}</small><span className="dots"><i /><i /></span></div></div>
        <div className="grow">
          <div className="name">{phone.name}</div>
          <div className="muted" style={{ fontSize: 16 }}>{phone.manufacturer} · Android {phone.os_version}</div>
          <div style={{ marginTop: 10 }}><span className={"pill" + (phone.connected ? "" : " off")}><span className="dot" />{phone.connected ? "Local Network" : "Offline"}</span></div>
          <div className="facts">
            <div><div className="l"><HardDrive size={13} /> Storage</div><div className="v">{b && b.storage_total_bytes ? `${FileUnit(b.storage_free_bytes)} free` : "—"}</div></div>
            <div><div className="l"><Headphones size={13} /> Call audio</div><div className="v">On phone</div></div>
            <div><div className="l"><ShieldCheck size={13} /> Encryption</div><div className="v">ChaCha20</div></div>
            <div><div className="l"><CalendarDays size={13} /> Paired</div><div className="v">{new Date(phone.paired_at_ms).toLocaleDateString([], { day: "numeric", month: "short" })}</div></div>
          </div>
        </div>
        <div style={{ textAlign: "center" }}>
          <div className="ring">
            <svg width="130" height="130" viewBox="0 0 130 130"><circle cx="65" cy="65" r="56" fill="none" stroke="var(--field)" strokeWidth="9" />
              <circle cx="65" cy="65" r="56" fill="none" stroke={pct <= 20 && !b?.is_charging ? "var(--red)" : "url(#g)"} strokeWidth="9" strokeLinecap="round" strokeDasharray={`${(pct / 100) * circ} ${circ}`} transform="rotate(-90 65 65)" />
              <defs><linearGradient id="g" x1="0" x2="1"><stop offset="0" stopColor="#6b5bf9" /><stop offset="1" stopColor="#3b8cff" /></linearGradient></defs></svg>
            <span className="v">{b ? `${pct}%` : "—"}</span>
          </div>
          <div className="small muted" style={{ marginTop: 4 }}>{b?.is_charging ? "Charging" : "Battery"}</div>
        </div>
      </div>

      <div className="stats">
        <div className="stat"><div className="ic" style={{ background: "linear-gradient(135deg,#3b8cff,#2a6df0)" }}><MessageSquare size={22} fill="currentColor" /></div><div><b>{unread}</b><span>Unread messages</span></div></div>
        <div className="stat"><div className="ic" style={{ background: "linear-gradient(135deg,#ff6a5a,#f0392b)" }}><PhoneMissed size={22} /></div><div><b>{missedToday}</b><span>Missed today</span></div></div>
        <div className="stat"><div className="ic" style={{ background: "linear-gradient(135deg,#35d36a,#1fa347)" }}><Phone size={22} fill="currentColor" /></div><div><b>{callsToday}</b><span>Calls today</span></div></div>
        <div className="stat"><div className="ic" style={{ background: "linear-gradient(135deg,#d452f2,#a23cd8)" }}><Users size={22} fill="currentColor" /></div><div><b>{d.contacts.length}</b><span>Contacts synced</span></div></div>
      </div>

      {d.sims.length > 0 && <>
        <div className="sec-h"><CreditCard size={18} /> SIM Cards</div>
        <div className="simcards">
          {d.sims.map((sim) => (
            <div key={sim.subscription_id} className={"simcard " + (sim.slot_index > 0 ? "s2" : "s1")}>
              <div className="row" style={{ fontWeight: 800 }}><CreditCard size={18} /> SIM {sim.slot_index + 1}<span className="grow" /><Radio size={16} /></div>
              <h3>{sim.carrier_name}</h3>
              <div style={{ opacity: .85 }}>{prettyNumber(sim.phone_number || "")}</div>
              <div className="foot"><span>{sim.display_name.toUpperCase()}</span>{sim.is_default_sms && <span className="tagp">Default SMS</span>}{sim.is_default_voice && <span className="tagp" style={{ marginLeft: 6 }}>Default Calls</span>}</div>
            </div>
          ))}
        </div>
      </>}

      <div className="cols2">
        <div className="panelbox">
          <div className="ph"><MessagesSquare size={18} /> Recent Conversations<a onClick={() => { state.section = "messages"; notify(); }}>See all</a></div>
          {recentThreads.length === 0 && <div className="muted" style={{ padding: 14 }}>No messages yet.</div>}
          {recentThreads.map((t) => <div key={t.id} className="item" onClick={() => { state.section = "messages"; state.selectedThread = t.id; notify(); }}><Avatar name={displayName(phone.id, t.address)} size={42} />
            <div className="grow"><div className="title">{displayName(phone.id, t.address)}</div><div className="sub" style={{ WebkitLineClamp: 1 }}>{t.messages.at(-1)!.body}</div></div><span className="time">{timeLabel(t.messages.at(-1)!.ts)}</span></div>)}
        </div>
        <div className="panelbox">
          <div className="ph"><Phone size={18} /> Recent Calls<a onClick={() => { state.section = "calls"; notify(); }}>See all</a></div>
          {d.calls.length === 0 && <div className="muted" style={{ padding: 14 }}>No calls yet.</div>}
          {d.calls.slice(0, 4).map((c) => { const name = c.name ?? displayName(phone.id, c.address); return (
            <div key={c.id} className="item" onDoubleClick={() => placeCall(c.address, c.sim)}><Avatar name={name} size={42} />
              <div className="grow"><div className="title" style={{ color: c.dir === "missed" ? "var(--red)" : undefined }}>{name}</div>
                <div className="row small muted" style={{ gap: 6 }}><SimTag sims={d.sims} subId={c.sim} /><span>{c.dir[0].toUpperCase() + c.dir.slice(1)}{c.duration ? ` · ${formatDuration(c.duration)}` : ""}</span></div></div>
              <span className="time">{new Date(c.startedAt).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}</span>
              <button className="icon" style={{ color: "var(--green)" }} onClick={() => placeCall(c.address, c.sim)}><Phone size={17} fill="currentColor" /></button></div>); })}
        </div>
      </div>
      {compose && <NewMessage onClose={() => setCompose(false)} />}
    </div>
  );
}

export function Settings() {
  const s = useStore((x) => x.settings);
  const phone = useStore(() => selectedPhone());
  const device = useStore((x) => x.device);
  return (
    <div className="page" style={{ maxWidth: 760 }}>
      <h2 className="title">Settings</h2>
      <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
        <div className="card" style={{ display: "flex", flexDirection: "column", gap: 10 }}>
          <b>Your name</b>
          <input value={s.userName} placeholder={nameFromMachine(device.name) || "Used in the home page greeting"} maxLength={40} onChange={(e) => saveSettings({ userName: e.target.value })} />
          <div className="small muted">Shown in the greeting on the home page. Leave it empty to use the name of this computer.</div>
        </div>
        <div className="card" style={{ display: "flex", flexDirection: "column", gap: 10 }}>
          <b>Appearance</b>
          <Seg value={s.appearance} onChange={(v) => saveSettings({ appearance: v })} options={[["system", "Match system"], ["light", "Light"], ["dark", "Dark"]]} />
        </div>
        <div className="card" style={{ display: "flex", flexDirection: "column", gap: 10 }}>
          <b>Notifications</b>
          <label className="row"><input type="checkbox" checked={s.notifyMessages} onChange={(e) => saveSettings({ notifyMessages: e.target.checked })} /> New messages</label>
          <label className="row"><input type="checkbox" checked={s.notifyCalls} onChange={(e) => saveSettings({ notifyCalls: e.target.checked })} /> Incoming calls</label>
          <label className="row"><input type="checkbox" checked={s.notifyPhone} onChange={(e) => saveSettings({ notifyPhone: e.target.checked })} /> Phone app notifications</label>
        </div>
        <div className="card" style={{ display: "flex", flexDirection: "column", gap: 10 }}>
          <b>Calls</b>
          <label className="row"><input type="checkbox" checked={s.fullWindowCalls} onChange={(e) => saveSettings({ fullWindowCalls: e.target.checked })} /> Show calls full window (default is a small card)</label>
          <label className="row">Auto-redial delay
            <select value={s.autoRedialDelay} onChange={(e) => saveSettings({ autoRedialDelay: Number(e.target.value) })}>{RedialLimits.delays.map((d) => <option key={d} value={d}>{d < 60 ? `${d} s` : `${d / 60} min`}</option>)}</select></label>
          <label className="row">Give up after
            <select value={s.autoRedialMaxAttempts} onChange={(e) => saveSettings({ autoRedialMaxAttempts: Number(e.target.value) })}>{RedialLimits.attempts.map((d) => <option key={d} value={d}>{d} calls</option>)}</select></label>
          <div className="small muted">Auto-redial is off until you turn it on for a call. Call audio stays on the phone: Windows and Linux can't act as a Bluetooth headset for Android.</div>
        </div>
        <div className="card" style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          <b>This computer</b>
          <div className="small muted">{device.name} · listening on port {device.lan_port}</div>
          <div style={{ fontFamily: "ui-monospace, monospace", userSelect: "text" }}>{device.fingerprint}</div>
        </div>
        <div className="card" style={{ display: "flex", flexDirection: "column", gap: 10 }}>
          <b>Phones</b>
          <div className="row"><button onClick={() => { state.addingPhone = true; notify(); }}>Add a phone</button>
            {phone && <button className="danger" onClick={() => { if (confirm(`Remove “${phone.name}”? Its saved messages, calls and contacts on this computer are deleted.`)) api.removePhone(phone.id); }}>Remove “{phone.name}”</button>}</div>
        </div>
      </div>
    </div>
  );
}

