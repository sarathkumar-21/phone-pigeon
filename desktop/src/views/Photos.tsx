import { useCallback, useEffect, useRef, useState } from "react";
import { open as pickFiles } from "@tauri-apps/plugin-dialog";
import { api, mediaUrl, uuid } from "../lib/api";
import { request, toast, useStore } from "../lib/store";
import { formatDuration } from "../lib/model";
import { Camera, Download, Film, Image as ImageIcon, Images, MessageCircle, Play, RefreshCw, ScanLine, Upload } from "lucide-react";
import { Empty, Seg, Thumb } from "../lib/ui";

interface Item { media_store_id: number; path: string; display_name: string; bucket_name: string; mime_type: string; size_bytes: number; width: number; height: number; duration_ms: number; date_taken_ms: number }
const isVideo = (i: Item) => i.mime_type.startsWith("video/") || i.duration_ms > 0;
const EXTERNAL = /\.(mkv|webm|avi|flv|wmv|mpg|mpeg|ogv|divx|m2ts|vob|rmvb)$/i;

export function Photos() {
  const phoneId = useStore((s) => s.selected)!;
  const media = useStore((s) => s.phones.find((p) => p.id === s.selected)?.media_ready ?? false);
  const [items, setItems] = useState<Item[]>([]);
  const [buckets, setBuckets] = useState<string[]>([]);
  const [bucket, setBucket] = useState("");
  const [filter, setFilter] = useState("MEDIA_ALL");
  const [more, setMore] = useState(true);
  const [loading, setLoading] = useState(false);
  const [viewing, setViewing] = useState<Item | null>(null);
  const [sel, setSel] = useState<Set<number>>(new Set());
  const [tile, setTile] = useState(150);
  const gen = useRef(0);

  const load = useCallback(async (reset: boolean) => {
    if (!media) return;
    const g = reset ? ++gen.current : gen.current;
    setLoading(true);
    try {
      const offset = reset ? 0 : items.length;
      const r = await request((id) => ({ list_gallery_req: { request_id: id, filter, bucket_name: bucket, limit: 120, offset } }));
      if (g !== gen.current) return;
      setItems((cur) => (reset ? r.items : [...cur, ...r.items]));
      setBuckets(r.available_buckets ?? []);
      setMore(!!r.has_more);
    } catch (e) { toast(String((e as Error).message ?? e), "error"); } finally { setLoading(false); }
  }, [media, filter, bucket, items.length]);

  useEffect(() => { setItems([]); setSel(new Set()); setMore(true); load(true); /* eslint-disable-next-line */ }, [media, filter, bucket, phoneId]);

  const months: [string, Item[]][] = [];
  for (const it of items) {
    const key = new Date(it.date_taken_ms).toLocaleDateString([], { month: "long", year: "numeric" });
    const last = months.at(-1);
    if (last && last[0] === key) last[1].push(it); else months.push([key, [it]]);
  }
  const chosen = items.filter((i) => sel.has(i.media_store_id));
  const download = async (list: Item[]) => {
    for (const it of list) api.mediaDownload({ phoneId, id: uuid(), path: it.path, mediaId: it.media_store_id, name: it.display_name, size: it.size_bytes }).catch((e) => toast(String(e), "error"));
    toast(`Downloading ${list.length} item${list.length === 1 ? "" : "s"} to your Downloads folder`, "info");
  };
  const upload = async () => {
    const picked = await pickFiles({ multiple: true, filters: [{ name: "Photos and videos", extensions: ["jpg", "jpeg", "png", "gif", "heic", "webp", "mp4", "mov", "mkv"] }] });
    if (!picked) return;
    for (const f of Array.isArray(picked) ? picked : [picked]) api.mediaUpload(phoneId, uuid(), f, "/Pictures/PhonePigeon").catch((e) => toast(String(e), "error"));
    toast("Uploading to /Pictures/PhonePigeon on the phone", "info");
    setTimeout(() => load(true), 2500);
  };

  if (!media) return <Empty icon={<ImageIcon size={32} />} title="Photos aren't available yet" message="The phone's local media server isn't reachable. Both devices need to be on the same Wi-Fi." />;
  const albumIcon = (name: string) => /camera/i.test(name) ? <Camera size={19} /> : /screenshot/i.test(name) ? <ScanLine size={19} /> : /video|movie/i.test(name) ? <Film size={19} /> : <MessageCircle size={19} />;
  return (
    <div className="split" style={{ gridTemplateColumns: "270px 1fr" }}>
      <div className="pane" style={{ background: "var(--sidebar)" }}>
        <div className="list" style={{ padding: "14px 10px" }}>
          <div className="section-title" style={{ margin: "0 8px 4px" }}>Library</div>
          <div className={"nav" + (bucket === "" ? " sel" : "")} onClick={() => setBucket("")}><Images size={19} /><span>All Photos</span></div>
          {buckets.length > 0 && <div className="section-title" style={{ margin: "16px 8px 4px" }}>Albums</div>}
          {buckets.map((b) => <div key={b} className={"nav" + (bucket === b ? " sel" : "")} onClick={() => setBucket(b)}><span style={{ color: "var(--fg2)", display: "flex" }}>{albumIcon(b)}</span><span>{b}</span></div>)}
        </div>
      </div>
      <div className="pane main-pane">
        <div className="head" style={{ flexDirection: "row", alignItems: "center", flexWrap: "wrap" }}>
          <div className="grow"><h2 style={{ fontSize: 22 }}>{bucket || "All Photos"}</h2><div className="small muted">{items.length}{more ? "+" : ""} items</div></div>
          <Seg value={filter} onChange={setFilter} options={[["MEDIA_ALL", "All"], ["MEDIA_IMAGES", "Photos"], ["MEDIA_VIDEOS", "Videos"]]} />
          <input type="range" min={110} max={300} value={tile} onChange={(e) => setTile(Number(e.target.value))} title="Size" style={{ width: 110, padding: 0 }} />
          <button className="round" title="Add to phone" onClick={upload}><Upload size={16} /></button>
          <button className="round" title="Refresh" onClick={() => load(true)}><RefreshCw size={16} /></button>
          {chosen.length > 0 && <button className="primary" onClick={() => download(chosen)}><Download size={15} /> Download {chosen.length}</button>}
        </div>
        <div className="scroll" onScroll={(e) => { const t = e.currentTarget; if (more && !loading && t.scrollTop + t.clientHeight > t.scrollHeight - 600) load(false); }}>
          {items.length === 0 && !loading && <Empty icon={<ImageIcon size={32} />} title="No photos" message="Nothing matches this filter." />}
          {months.map(([title, group]) => (
            <div key={title}>
              <div className="month-h">{title}</div>
              <div className="grid" style={{ gridTemplateColumns: `repeat(auto-fill, minmax(${tile}px, 1fr))`, marginTop: 8 }}>
                {group.map((it) => (
                  <div key={it.media_store_id} className={"tile" + (sel.has(it.media_store_id) ? " sel" : "")}
                    onClick={(e) => { if (e.ctrlKey || e.metaKey || e.shiftKey || sel.size) { const n = new Set(sel); n.has(it.media_store_id) ? n.delete(it.media_store_id) : n.add(it.media_store_id); setSel(n); } else open(it); }}
                    onDoubleClick={() => open(it)}>
                    <Thumb phoneId={phoneId} id={it.media_store_id} />
                    {isVideo(it) && <span className="play"><Play size={11} fill="currentColor" /> {formatDuration(it.duration_ms / 1000)}</span>}
                  </div>
                ))}
              </div>
            </div>
          ))}
          {loading && <div className="muted" style={{ padding: 16, textAlign: "center" }}>Loading…</div>}
        </div>
      </div>
      {viewing && <Viewer item={viewing} items={items} phoneId={phoneId} onClose={() => setViewing(null)} onChange={setViewing} />}
    </div>
  );

  function open(it: Item) {
    if (isVideo(it) && EXTERNAL.test(it.display_name)) {
      api.mediaDownload({ phoneId, id: uuid(), path: it.path, mediaId: it.media_store_id, name: it.display_name, size: it.size_bytes }).then((p) => api.revealInFolder(p));
      toast("This format can't play here — saved to Downloads.", "info");
    } else setViewing(it);
  }
}

function Viewer({ item, items, phoneId, onClose, onChange }: { item: Item; items: Item[]; phoneId: string; onClose: () => void; onChange: (i: Item) => void }) {
  const idx = items.findIndex((i) => i.media_store_id === item.media_store_id);
  const go = (d: number) => { const n = items[idx + d]; if (n && !(isVideo(n) && EXTERNAL.test(n.display_name))) onChange(n); };
  useEffect(() => {
    const h = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); if (e.key === "ArrowLeft") go(-1); if (e.key === "ArrowRight") go(1); };
    window.addEventListener("keydown", h); return () => window.removeEventListener("keydown", h);
  });
  const src = mediaUrl(phoneId, "/media/file", { id: item.media_store_id });
  return (
    <div className="viewer" onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="top"><b className="grow">{item.display_name}</b><span className="muted">{item.bucket_name}</span>
        <button onClick={() => api.mediaDownload({ phoneId, id: uuid(), path: item.path, mediaId: item.media_store_id, name: item.display_name, size: item.size_bytes })}>Download</button>
        <button onClick={onClose}>Close</button></div>
      <div className="stage" onClick={(e) => { if (e.target === e.currentTarget) onClose(); }}>
        {isVideo(item) ? <video key={src} src={src} controls autoPlay /> : <img key={src} src={src} alt={item.display_name} />}
      </div>
    </div>
  );
}

