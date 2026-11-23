import { useEffect } from "react";
import { BatteryMedium, Bell, CalendarCheck, ChevronsUpDown, Folder, Images, MessagesSquare, Phone, Plus, Settings as Cog, Smartphone, SquarePen } from "lucide-react";
import { api } from "./lib/api";
import { init, notify, selectPhone, state, unreadTotal, useStore, type Section } from "./lib/store";
import { Onboarding } from "./views/Onboarding";
import { Messages, NewMessage } from "./views/Messages";
import { ActiveCall, Calls, RedialBanner } from "./views/Calls";
import { Photos } from "./views/Photos";
import { Files } from "./views/Files";
import { Notifications, Overview, Settings } from "./views/Misc";
import { Scheduled } from "./views/Scheduled";
import { ScreenViewer } from "./views/Screen";
import { useState } from "react";

const NAV: [Section, typeof Phone, string, string?][] = [
  ["messages", MessagesSquare, "Messages"], ["calls", Phone, "Calls & Dialer"], ["photos", Images, "Photos & Videos"],
  ["files", Folder, "Files", "files-i"], ["notifications", Bell, "Notifications"], ["scheduled", CalendarCheck, "Scheduled"],
];

export default function App() {
  const ready = useStore((s) => s.ready);
  const phones = useStore((s) => s.phones);
  const selected = useStore((s) => s.selected);
  const adding = useStore((s) => s.addingPhone);
  const section = useStore((s) => s.section);
  const toast = useStore((s) => s.toast);
  const notifCount = useStore((s) => (s.selected ? (s.data[s.selected]?.notifications.length ?? 0) : 0));
  const sims = useStore((s) => (s.selected ? (s.data[s.selected]?.sims ?? []) : []));
  const battery = useStore((s) => (s.selected ? s.data[s.selected]?.battery : undefined));
  const pendingSched = useStore((s) => (s.selected ? (s.data[s.selected]?.scheduled.filter((x) => x.status === "pending").length ?? 0) : 0));
  const unread = useStore(() => unreadTotal(state.selected));
  const [compose, setCompose] = useState(false);
  useEffect(() => { init(); }, []);
  useEffect(() => { document.title = unread > 0 ? `(${unread}) PhonePigeon` : "PhonePigeon"; }, [unread]);
  if (!ready) return null;
  if (phones.length === 0 || adding) return <><Onboarding />{toast && <div className={"toast " + toast.kind}>{toast.text}</div>}</>;
  const phone = phones.find((p) => p.id === selected) ?? phones[0];
  const nextPhone = () => { const i = phones.findIndex((p) => p.id === phone.id); selectPhone(phones[(i + 1) % phones.length].id); };

  return (
    <div className="app">
      <aside className="sidebar">
        <div className={"device" + (section === "overview" ? " sel" : "")} onClick={() => { state.section = "overview"; notify(); }} title="Phone overview">
          <div className="top">
            <div className="tile"><Smartphone size={24} /></div>
            <div className="grow"><div className="name">{phone.name}</div><div className="meta">{phone.manufacturer ? `Android ${phone.os_version}` : phone.os_version}</div></div>
            {phones.length > 1 && <button className="icon" title="Switch phone" onClick={(e) => { e.stopPropagation(); nextPhone(); }}><ChevronsUpDown size={16} /></button>}
          </div>
          <div className="row2">
            <span className={"pill" + (phone.connected ? "" : " off")}><span className="dot" />{phone.connected ? "Local Network" : "Offline"}</span>
            {battery && <span className="batt"><BatteryMedium size={17} />{battery.battery_percent}%</span>}
          </div>
        </div>
        <div className="section-title" style={{ marginTop: 2 }}>Phone</div>
        {NAV.map(([id, Icon, label, cls]) => (
          <div key={id} className={"nav" + (section === id ? " sel" : "")} onClick={() => { state.section = id; notify(); }}>
            <Icon size={20} className={cls} /><span>{label}</span>
            {id === "messages" && unread > 0 && <span className="badge">{unread}</span>}
            {id === "notifications" && notifCount > 0 && <span className="badge">{notifCount}</span>}
            {id === "scheduled" && pendingSched > 0 && <span className="badge">{pendingSched}</span>}
          </div>
        ))}
        {sims.length > 0 && <div className="section-title">SIM Cards</div>}
        {sims.map((s) => (
          <div key={s.subscription_id} className="sim">
            <span className="chip" style={{ background: s.slot_index > 0 ? "linear-gradient(#ff7a50,#f0502a)" : "linear-gradient(#5b8bff,#3b6ff5)" }}>{s.slot_index + 1}</span>
            <div><div className="n">{s.carrier_name}</div><div className="d">{s.display_name}</div></div>
          </div>
        ))}
        <div className="grow" />
        <div className={"nav" + (section === "settings" ? " sel" : "")} onClick={() => { state.section = "settings"; notify(); }}><Cog size={19} /><span>Settings</span></div>
        <div className="nav" onClick={() => { state.addingPhone = true; notify(); api.nearbyPhones(); }}><Plus size={19} /><span>Add phone</span></div>
        <button className="newmsg" onClick={() => setCompose(true)}><SquarePen size={16} /> New Message</button>
      </aside>
      <main className="main">
        {!phone.connected && <div className="banner-off">{phone.name} is offline — open PhonePigeon on the phone, on the same Wi-Fi. Recent history is shown below.</div>}
        <div style={{ flex: 1, minHeight: 0 }}>
          {section === "overview" && <Overview />}
          {section === "messages" && <Messages />}
          {section === "calls" && <Calls />}
          {section === "photos" && <Photos />}
          {section === "files" && <Files />}
          {section === "notifications" && <Notifications />}
          {section === "scheduled" && <Scheduled />}
          {section === "settings" && <Settings />}
        </div>
      </main>
      {compose && <NewMessage onClose={() => setCompose(false)} />}
      <ActiveCall />
      <RedialBanner />
      <ScreenViewer />
      {toast && <div className={"toast " + toast.kind}>{toast.text}</div>}
    </div>
  );
}
