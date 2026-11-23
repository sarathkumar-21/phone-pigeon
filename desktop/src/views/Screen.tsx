import { useEffect, useRef, useState } from "react";
import { api, on } from "../lib/api";
import { state, useStore } from "../lib/store";

/** Full-window viewer for the phone's mirrored screen: H.264 (Annex B) frames decoded with WebCodecs onto a canvas. */
export function ScreenViewer() {
  const phoneId = useStore((s) => Object.keys(s.screen).find((id) => s.screen[id]?.state === "SCREEN_STREAMING"));
  const info = useStore((s) => (phoneId ? s.screen[phoneId] : undefined));
  const canvas = useRef<HTMLCanvasElement>(null);
  const [typed, setTyped] = useState("");
  const [problem, setProblem] = useState<string | null>(null);

  useEffect(() => {
    if (!phoneId) return;
    const VD = (window as any).VideoDecoder as typeof VideoDecoder | undefined;
    if (!VD) { setProblem("This system's web view can't decode video (WebCodecs missing). Update WebKitGTK/WebView2, or use the Mac or Android app for mirroring."); return; }
    setProblem(null);
    let decoder: VideoDecoder | null = null;
    let configured = false;
    const ctx = canvas.current!.getContext("2d")!;
    const make = () => new VD({
      output: (frame) => {
        const c = canvas.current;
        if (c) { if (c.width !== frame.displayWidth) c.width = frame.displayWidth; if (c.height !== frame.displayHeight) c.height = frame.displayHeight; ctx.drawImage(frame, 0, 0); }
        frame.close();
      },
      error: () => { configured = false; },
    });
    decoder = make();
    const offs = on<{ phone_id: string; kind: number; pts: number; data: string }>("screen_frame", (f) => {
      if (f.phone_id !== phoneId) return;
      const bytes = Uint8Array.from(atob(f.data), (c) => c.charCodeAt(0));
      if (f.kind === 1) {
        const sps = findSps(bytes);
        if (!sps) return;
        const codec = "avc1." + [sps[1], sps[2], sps[3]].map((b) => b.toString(16).padStart(2, "0")).join("");
        try { decoder!.configure({ codec, optimizeForLatency: true }); configured = true; } catch { configured = false; }
        return;
      }
      if (!configured || (f.kind !== 2 && f.kind !== 3)) return;
      try { decoder!.decode(new EncodedVideoChunk({ type: f.kind === 2 ? "key" : "delta", timestamp: f.pts, data: bytes })); } catch { /* wait for the next key frame */ }
    });
    return () => { offs.then((u) => u()); try { decoder?.close(); } catch { /* already closed */ } };
  }, [phoneId]);

  if (!phoneId || !info) return null;
  const send = (input: Record<string, unknown>) => { if (info.control) api.send(phoneId, { remote_input: input }); };
  const norm = (e: React.MouseEvent<HTMLCanvasElement>) => {
    const r = e.currentTarget.getBoundingClientRect();
    const scale = Math.min(r.width / (info.width || 1), r.height / (info.height || 1));
    const w = (info.width || 1) * scale, h = (info.height || 1) * scale;
    const x = (e.clientX - r.left - (r.width - w) / 2) / w, y = (e.clientY - r.top - (r.height - h) / 2) / h;
    return x >= 0 && x <= 1 && y >= 0 && y <= 1 ? { x, y } : null;
  };
  let down: { x: number; y: number; t: number } | null = null;
  const stop = () => { api.send(phoneId, { screen_req: { action: "SCREEN_STOP", max_dimension: 0 } }); api.screenStop(phoneId); state.screen[phoneId] = { ...info, state: "SCREEN_IDLE" }; };
  return (
    <div className="overlay" style={{ background: "#000", placeItems: "stretch" }}>
      <div className="screen">
        <div className="bar2">
          <b className="grow">Screen mirroring {info.control ? "· click, drag and type to control" : "· view only"}</b>
          <button disabled={!info.control} onClick={() => send({ kind: "INPUT_BACK" })}>◁ Back</button>
          <button disabled={!info.control} onClick={() => send({ kind: "INPUT_HOME" })}>○ Home</button>
          <button disabled={!info.control} onClick={() => send({ kind: "INPUT_RECENTS" })}>□ Recents</button>
          <input placeholder="Type on phone" value={typed} disabled={!info.control} onChange={(e) => setTyped(e.target.value)} style={{ width: 180 }}
            onKeyDown={(e) => { if (e.key === "Enter") { if (typed) send({ kind: "INPUT_TEXT", text: typed }); send({ kind: "INPUT_ENTER" }); setTyped(""); } }} />
          <button className="danger" onClick={stop}>Stop</button>
        </div>
        {problem && <div style={{ color: "#fff", padding: 20 }}>{problem}</div>}
        <canvas ref={canvas} style={{ flex: 1, minHeight: 0, objectFit: "contain", background: "#000" }}
          onMouseDown={(e) => { const p = norm(e); down = p ? { ...p, t: Date.now() } : null; }}
          onMouseUp={(e) => {
            const p = norm(e);
            if (!down || !p || !info.control) return;
            const held = Date.now() - down.t;
            if (Math.hypot(p.x - down.x, p.y - down.y) < 0.012) send({ kind: held > 500 ? "INPUT_LONG_PRESS" : "INPUT_TAP", x: down.x, y: down.y });
            else send({ kind: "INPUT_SWIPE", x: down.x, y: down.y, x2: p.x, y2: p.y, duration_ms: Math.min(800, Math.max(120, held)) });
            down = null;
          }}
          onContextMenu={(e) => { e.preventDefault(); send({ kind: "INPUT_BACK" }); }} />
      </div>
    </div>
  );
}

/** First SPS NAL unit (type 7) in an Annex B buffer; byte 0 is the NAL header, so profile/constraints/level follow it. */
function findSps(b: Uint8Array): Uint8Array | null {
  for (let i = 0; i + 4 < b.length; i++) {
    const sc3 = b[i] === 0 && b[i + 1] === 0 && b[i + 2] === 1;
    const sc4 = b[i] === 0 && b[i + 1] === 0 && b[i + 2] === 0 && b[i + 3] === 1;
    if (!sc3 && !sc4) continue;
    const start = i + (sc3 ? 3 : 4);
    if ((b[start] & 0x1f) === 7) return b.subarray(start);
  }
  return null;
}
