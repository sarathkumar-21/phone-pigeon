import { useEffect, useMemo, useRef, useState } from "react";
import { CheckCheck, ChevronDown, Clock, KeyRound, ListFilter, MessagesSquare, MoreHorizontal, Phone, Pin, SquarePen, ArrowUp, Smile } from "lucide-react";
import { contactFor, currentData, displayName, markRead, notify, placeCall, sendText, state, useStore } from "../lib/store";
import { isDialable, normalizeNumber, otpIn, prettyNumber, timeLabel, type Message, type Thread } from "../lib/model";
import { Avatar, Empty, Modal, SearchField, Seg, SimChips, SimTag } from "../lib/ui";
import { ScheduleDialog } from "./Scheduled";

export function Messages() {
  const phoneId = useStore((s) => s.selected);
  const d = useStore(() => currentData());
  const sel = useStore((s) => s.selectedThread);
  const simFilter = useStore((s) => s.simFilter);
  const [query, setQuery] = useState("");
  const [unreadOnly, setUnreadOnly] = useState(false);
  const [compose, setCompose] = useState(false);

  const threads = useMemo(() => {
    const q = query.trim().toLowerCase();
    return [...d.threads]
      .filter((t) => t.messages.length)
      .filter((t) => simFilter === undefined || t.messages.some((m) => m.sim === simFilter))
      .filter((t) => !unreadOnly || t.messages.some((m) => !m.read && m.dir === "INCOMING"))
      .filter((t) => !q || displayName(phoneId, t.address).toLowerCase().includes(q) || t.address.includes(q) || t.messages.some((m) => m.body.toLowerCase().includes(q)))
      .sort((a, b) => Number(!!b.pinned) - Number(!!a.pinned) || b.messages.at(-1)!.ts - a.messages.at(-1)!.ts);
  }, [d.threads, d.threads.length, query, unreadOnly, phoneId, d.contacts.length, simFilter, state.selectedThread]);

  const thread = d.threads.find((t) => t.id === sel);
  useEffect(() => { if (phoneId && sel) markRead(phoneId, sel); }, [phoneId, sel, thread?.messages.length]);

  return (
    <div className="split" style={{ gridTemplateColumns: "372px 1fr" }}>
      <div className="pane">
        <div className="head">
          <div className="row"><h2 className="grow">Messages</h2>
            <button className="round" title="Unread only" onClick={() => setUnreadOnly(!unreadOnly)} style={{ background: unreadOnly ? "var(--primary)" : undefined, color: unreadOnly ? "#fff" : undefined }}><ListFilter size={16} /></button>
            <button className="round" title="New message" onClick={() => setCompose(true)}><SquarePen size={16} /></button></div>
          <SearchField value={query} onChange={setQuery} placeholder="Search messages" />
          {d.sims.length > 1 && (
            <Seg value={simFilter ?? -1} onChange={(v) => { state.simFilter = v === -1 ? undefined : v; notify(); }}
              options={[[-1, "All SIMs"], ...d.sims.map((s) => [s.subscription_id, s.carrier_name] as [number, string])]} />
          )}
        </div>
        <div className="list">
          {threads.length === 0 && <Empty icon={<MessagesSquare size={32} />} title={query ? "No results" : "Nothing here"} message={query ? "Try a different name, number or word." : "No conversations match this filter."} />}
          {threads.map((t) => <ThreadRow key={t.id} t={t} sel={t.id === sel} />)}
        </div>
      </div>
      <div className="pane main-pane">
        {thread ? <Conversation key={thread.id} thread={thread} /> : <Empty icon={<MessagesSquare size={32} />} title="Pick a conversation" message="Messages from every SIM on your phone appear here, end-to-end encrypted." action={<button className="primary" onClick={() => setCompose(true)}><SquarePen size={15} /> New Message</button>} />}
      </div>
      {compose && <NewMessage onClose={() => setCompose(false)} />}
    </div>
  );
}

function ThreadRow({ t, sel }: { t: Thread; sel: boolean }) {
  const phoneId = state.selected;
  const sims = currentData().sims;
  const last = t.messages.at(-1)!;
  const unread = t.messages.filter((m) => !m.read && m.dir === "INCOMING").length;
  const name = displayName(phoneId, t.address);
  const code = last.dir === "INCOMING" ? otpIn(last.body) : null;
  return (
    <div className={"item" + (sel ? " sel" : "")} onClick={() => { state.selectedThread = t.id; notify(); }}>
      {unread > 0 && <span className="unread-dot" />}
      <Avatar name={name} contact={contactFor(phoneId, t.address)} size={50} />
      <div className="grow">
        <div className="row"><span className="title grow">{t.pinned ? "📌 " : ""}{name}</span><span className="time" style={{ marginLeft: 0 }}>{timeLabel(last.ts)}</span></div>
        <div className="sub">{last.dir === "OUTGOING" ? "You: " : ""}{last.body}</div>
        <div className="tags"><SimTag sims={sims} subId={last.sim} />{code && <span className="code-chip"><KeyRound size={11} /> Code</span>}</div>
      </div>
    </div>
  );
}

function dayLabel(ts: number): string {
  const d = new Date(ts), now = new Date();
  const y = new Date(now); y.setDate(now.getDate() - 1);
  if (d.toDateString() === now.toDateString()) return "Today";
  if (d.toDateString() === y.toDateString()) return "Yesterday";
  return d.toLocaleDateString([], { weekday: "long", month: "short", day: "numeric" });
}

function Conversation({ thread }: { thread: Thread }) {
  const phoneId = state.selected!;
  const sims = currentData().sims;
  const [text, setText] = useState("");
  const [sim, setSim] = useState<number | undefined>();
  const [sched, setSched] = useState(false);
  const end = useRef<HTMLDivElement>(null);
  const name = displayName(phoneId, thread.address);
  const lastSim = thread.messages.at(-1)?.sim;
  const active = sim ?? lastSim ?? sims[0]?.subscription_id;
  const activeSim = sims.find((s) => s.subscription_id === active);
  useEffect(() => { end.current?.scrollIntoView({ block: "end" }); }, [thread.messages.length]);
  const send = () => { if (sendText(thread.address, text, active)) setText(""); };

  const rows: React.ReactNode[] = [];
  thread.messages.forEach((m: Message, i) => {
    const prev = thread.messages[i - 1];
    if (!prev || new Date(prev.ts).toDateString() !== new Date(m.ts).toDateString()) rows.push(<div key={"d" + m.id} className="day">{dayLabel(m.ts)}</div>);
    const out = m.dir === "OUTGOING";
    rows.push(<div key={m.id} className={"bubble" + (out ? " out" : "") + (m.status === "FAILED" ? " failed" : "")}>{m.body}</div>);
    rows.push(
      <div key={m.id + "m"} className={"bmeta" + (out ? " out" : "")}>
        <SimTag sims={sims} subId={m.sim} label={(() => { const s = sims.find((x) => x.subscription_id === m.sim); return s ? `SIM ${s.slot_index + 1} · ${s.carrier_name}` : undefined; })()} />
        <span>{new Date(m.ts).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}</span>
        {out && (m.status === "DELIVERED" ? <span className="ok"><CheckCheck size={14} /> Delivered</span> : m.status === "PENDING" ? <span><Clock size={12} /> Sending…</span> : m.status === "FAILED" ? <span style={{ color: "var(--red)" }}>Not delivered</span> : <span className="ok">Sent</span>)}
      </div>,
    );
  });

  return (
    <div className="convo">
      <div className="convo-head">
        <Avatar name={name} contact={contactFor(phoneId, thread.address)} size={46} />
        <div className="grow"><div className="nm">{name}</div>
          <div className="row small muted" style={{ gap: 8 }}><span>{prettyNumber(thread.address)}</span>{lastSim !== undefined && <><span>Replies via</span><SimTag sims={sims} subId={lastSim} label={(() => { const s = sims.find((x) => x.subscription_id === lastSim); return s ? `SIM ${s.slot_index + 1} · ${s.carrier_name}` : undefined; })()} /></>}</div></div>
        <button onClick={() => placeCall(thread.address, active)}><Phone size={15} /> Call <ChevronDown size={14} /></button>
        <button className="icon" title={thread.pinned ? "Unpin" : "Pin"} onClick={() => { thread.pinned = !thread.pinned; notify(); }}><Pin size={17} /></button>
        <button className="icon"><MoreHorizontal size={19} /></button>
      </div>
      <div className="bubbles">{rows}<div ref={end} /></div>
      <div className="composer-wrap">
        <SimChips sims={sims} value={active} onChange={setSim} hint />
        <div className="composer">
          <button className="icon" title="Schedule" onClick={() => setSched(true)}><Clock size={19} /></button>
          <button className="icon" title="Emoji" onClick={() => setText(text + "😊")}><Smile size={20} /></button>
          <textarea rows={1} placeholder={activeSim ? `Message via ${activeSim.carrier_name}` : "Text message"} value={text} onChange={(e) => setText(e.target.value)}
            onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); } }} />
          <button className="send" disabled={!text.trim()} onClick={send} title="Send"><ArrowUp size={18} /></button>
        </div>
      </div>
      {sched && <ScheduleDialog initialAddress={thread.address} onClose={() => setSched(false)} />}
    </div>
  );
}

export function NewMessage({ onClose }: { onClose: () => void }) {
  const d = currentData();
  const [to, setTo] = useState("");
  const [body, setBody] = useState("");
  const [sim, setSim] = useState<number | undefined>();
  const q = to.trim().toLowerCase();
  const matches = q.length >= 1 && !/^[+\d\s()-]+$/.test(to)
    ? d.contacts.filter((c) => c.display_name.toLowerCase().includes(q)).flatMap((c) => c.phone_numbers.map((n) => ({ c, n }))).slice(0, 8)
    : [];
  const dialable = isDialable(to);
  const go = (address: string) => {
    if (!body.trim()) return;
    if (sendText(address, body, sim)) { state.selectedThread = normalizeNumber(address); state.section = "messages"; notify(); onClose(); }
  };
  return (
    <Modal title="New Message" onClose={onClose}>
      <label className="field">To<input autoFocus placeholder="Name or number" value={to} onChange={(e) => setTo(e.target.value)} /></label>
      {matches.length > 0 && (
        <div className="card" style={{ padding: 4 }}>
          {matches.map(({ c, n }) => (
            <div key={c.contact_id + n} className="item" onClick={() => { setTo(n); }}>
              <Avatar name={c.display_name} contact={c} size={32} /><div className="grow"><div className="title">{c.display_name}</div><div className="sub">{prettyNumber(n)}</div></div>
            </div>
          ))}
        </div>
      )}
      <label className="field">Message<textarea rows={4} value={body} onChange={(e) => setBody(e.target.value)} /></label>
      <SimChips sims={d.sims} value={sim} onChange={setSim} />
      <div className="row"><div className="grow" /><button onClick={onClose}>Cancel</button>
        <button className="primary" disabled={!dialable || !body.trim()} onClick={() => go(to)}>Send</button></div>
    </Modal>
  );
}
