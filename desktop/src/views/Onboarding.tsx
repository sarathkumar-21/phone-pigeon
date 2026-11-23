import { useEffect } from "react";
import { ArrowLeft, Radio, Smartphone } from "lucide-react";
import { api } from "../lib/api";
import { notify, state, useStore } from "../lib/store";

/** Nearby pairing: pick the phone that is showing "Pair with your computer", then compare the six-digit code on both screens. */
export function Onboarding() {
  const nearby = useStore((s) => s.nearby);
  const list = useStore((s) => s.nearbyList);
  const hasPhones = useStore((s) => s.phones.length > 0);
  useEffect(() => { api.nearbyPhones().then((l) => { state.nearbyList = l; notify(); }); }, []);

  return (
    <div className="onboard">
      <div className="box">
        <div>
          <div className="hero-tile"><Smartphone size={44} /></div>
          <h1 style={{ marginTop: 22 }}>Add your Android phone</h1>
          <div className="muted" style={{ fontSize: 16 }}>No code to scan: your phone shows up here when it's ready.</div>
        </div>
        <div className="steps">
          <div className="st"><span className="n">1</span><div><b>Install PhonePigeon on your phone</b><div className="muted">Get it from Google Play or GitHub Releases, and allow its permissions.</div></div></div>
          <div className="st"><span className="n">2</span><div><b>Open it and tap “Pair with your computer”</b><div className="muted">Keep that screen open. Your phone and this computer need to be on the same Wi-Fi.</div></div></div>
          <div className="st"><span className="n">3</span><div><b>Pick your phone below</b><div className="muted">Both screens show the same six-digit code. Check it matches, then confirm on both.</div></div></div>
        </div>

        <div className="card" style={{ display: "flex", flexDirection: "column", gap: 12 }}>
          <div className="row" style={{ fontWeight: 800 }}><Radio size={17} /> Nearby phones</div>
          {nearby.state === "idle" && (list.length === 0
            ? <div className="muted">Looking for phones… open PhonePigeon on your phone and go to “Pair with your computer”.</div>
            : list.map((p) => (
              <div key={p.id} className="row" style={{ gap: 12 }}>
                <Smartphone size={26} style={{ color: "var(--primary)" }} />
                <div className="grow"><div style={{ fontWeight: 700 }}>{p.name}</div><div className="small muted">{p.model}</div></div>
                <button className="primary" onClick={() => api.nearbyBegin(p.id)}>Pair</button>
              </div>)))}
          {nearby.state === "connecting" && <div>Contacting {nearby.phone}…</div>}
          {nearby.state === "confirm" && (<>
            <div className="muted">Check that <b>{nearby.phone}</b> shows this same code, then tap Codes match on both.</div>
            <div className="code">{nearby.code}</div>
            <div className="row"><button onClick={() => api.nearbyCancel()}>Cancel</button><div className="grow" /><button className="primary" onClick={() => api.nearbyConfirm()}>Codes match</button></div></>)}
          {nearby.state === "finishing" && <div>Waiting for {nearby.phone} to confirm…</div>}
          {nearby.state === "failed" && (<><div style={{ color: "var(--red)" }}>{nearby.message}</div><div><button className="primary" onClick={() => api.nearbyDismiss()}>Try again</button></div></>)}
        </div>
        {hasPhones && <div><button onClick={() => { state.addingPhone = false; notify(); }}><ArrowLeft size={15} /> Back</button></div>}
      </div>
    </div>
  );
}
