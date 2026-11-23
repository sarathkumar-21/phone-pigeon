import { useEffect, useMemo, useState } from "react";
import { open as pickFiles } from "@tauri-apps/plugin-dialog";
import { api, mediaUrl, uuid } from "../lib/api";
import { request, toast, useStore } from "../lib/store";
import { FileUnit } from "../lib/model";
import { ArrowUp, ChevronLeft, Download, File as FileIcon, FileUp, Folder as FolderIcon, FolderPlus, HardDrive, Pencil, Search, Trash2 } from "lucide-react";
import { Empty, Modal, Seg } from "../lib/ui";

interface Entry { path: string; name: string; is_directory: boolean; size_bytes: number; mime_type: string; modified_at_ms: number; child_count: number }
type SortKey = "name" | "size" | "modified";

const join = (a: string, b: string) => (a.endsWith("/") ? a : a + "/") + b;
const parent = (p: string) => (p.replace(/\/+$/, "").split("/").slice(0, -1).join("/") || "/");
const isMedia = (e: Entry) => e.mime_type.startsWith("image/") || e.mime_type.startsWith("video/");
const EXTERNAL = /\.(mkv|webm|avi|flv|wmv|mpg|mpeg|ogv|divx|m2ts|vob|rmvb)$/i;

export function Files() {
  const phoneId = useStore((s) => s.selected)!;
  const media = useStore((s) => s.phones.find((p) => p.id === s.selected)?.media_ready ?? false);
  const transfers = useStore((s) => s.transfers);
  const [path, setPathRaw] = useState("/");
  const [trail, setTrail] = useState<string[]>([]);
  const setPath = (p: string) => { if (p !== path) setTrail((t) => [...t, path]); setPathRaw(p); };
  const [entries, setEntries] = useState<Entry[]>([]);
  const [query, setQuery] = useState("");
  const [hits, setHits] = useState<Entry[] | null>(null);
  const [hidden, setHidden] = useState(false);
  const [view, setView] = useState<"list" | "grid">(() => (localStorage.getItem("filesView") as "list" | "grid") || "list");
  const [sort, setSort] = useState<{ key: SortKey; dir: 1 | -1 }>({ key: "name", dir: 1 });
  const [sel, setSel] = useState<Set<string>>(new Set());
  const [err, setErr] = useState<string | null>(null);
  const [dialog, setDialog] = useState<null | { kind: "mkdir" } | { kind: "rename"; e: Entry } | { kind: "delete"; list: Entry[] }>(null);
  const [preview, setPreview] = useState<Entry | null>(null);
  const global = query.trim().length >= 2;
  const bat = useStore((s) => (s.selected ? s.data[s.selected]?.battery : undefined));

  const load = async () => {
    if (!media) return;
    try { const r = await request((id) => ({ list_dir_req: { request_id: id, path, include_hidden: hidden } })); if (r.error_message) throw new Error(r.error_message); setEntries(r.entries ?? []); setErr(null); }
    catch (e) { setErr(String((e as Error).message ?? e)); setEntries([]); }
  };
  useEffect(() => { setSel(new Set()); load(); /* eslint-disable-next-line */ }, [path, hidden, media, phoneId]);
  useEffect(() => {
    if (!global) { setHits(null); return; }
    const t = setTimeout(async () => {
      try { const r = await request((id) => ({ search_req: { request_id: id, query: query.trim(), include_hidden: hidden, limit: 500 } })); setHits(r.entries ?? []); } catch (e) { setErr(String((e as Error).message ?? e)); }
    }, 300);
    return () => clearTimeout(t);
  }, [query, hidden, global]);
  useEffect(() => localStorage.setItem("filesView", view), [view]);

  const shown = useMemo(() => {
    const base = global ? hits ?? [] : query ? entries.filter((e) => e.name.toLowerCase().includes(query.toLowerCase())) : entries;
    const cmp = (a: Entry, b: Entry) => {
      const v = sort.key === "name" ? a.name.localeCompare(b.name) : sort.key === "size" ? a.size_bytes - b.size_bytes : a.modified_at_ms - b.modified_at_ms;
      return v * sort.dir;
    };
    return [...base].sort(cmp).sort((a, b) => Number(b.is_directory) - Number(a.is_directory));
  }, [entries, hits, query, global, sort]);

  const op = async (kind: "MKDIR" | "RENAME" | "DELETE", src: string, dst = "") => {
    const r = await request((id) => ({ file_op_req: { request_id: id, op: kind, source_path: src, target_path: dst } }));
    if (!r.success) throw new Error(r.error_message || "Operation failed");
  };
  const download = (list: Entry[]) => { for (const e of list.filter((x) => !x.is_directory)) api.mediaDownload({ phoneId, id: uuid(), path: e.path, name: e.name, size: e.size_bytes }).catch((x) => toast(String(x), "error")); toast("Saving to your Downloads folder", "info"); };
  const upload = async () => {
    const picked = await pickFiles({ multiple: true });
    if (!picked) return;
    for (const f of Array.isArray(picked) ? picked : [picked]) api.mediaUpload(phoneId, uuid(), f, path).catch((x) => toast(String(x), "error"));
    toast(`Uploading to ${path}`, "info");
    setTimeout(load, 2500);
  };
  const open = (e: Entry) => {
    if (e.is_directory) { setQuery(""); setPath(e.path); }
    else if (EXTERNAL.test(e.name)) download([e]);
    else if (isMedia(e) || /\.pdf$/i.test(e.name)) setPreview(e);
    else download([e]);
  };
  const toggle = (e: Entry, ev: React.MouseEvent) => {
    const n = new Set(ev.ctrlKey || ev.metaKey || ev.shiftKey ? sel : []);
    n.has(e.path) ? n.delete(e.path) : n.add(e.path);
    setSel(n);
  };
  const picked = shown.filter((e) => sel.has(e.path));
  const active = Object.values(transfers).filter((t) => t.state === "running");

  if (!media) return <Empty icon={<FolderIcon size={32} />} title="Files aren't available yet" message="The phone's local media server isn't reachable. Both devices need to be on the same Wi-Fi." />;
  const crumbs = path.split("/").filter(Boolean);
  const icon = (e: Entry) => e.is_directory ? <FolderIcon size={18} fill="currentColor" style={{ color: "#6b5bf9" }} /> : <FileIcon size={18} style={{ color: "var(--fg2)" }} />;
  const used = bat && bat.storage_total_bytes ? 1 - bat.storage_free_bytes / bat.storage_total_bytes : 0;
  return (
    <div className="pane main-pane" style={{ height: "100%" }}>
      <div className="head" style={{ flexDirection: "row", alignItems: "center", flexWrap: "wrap", paddingBottom: 12 }}>
        <button className="round" disabled={!trail.length} onClick={() => { const l = trail.at(-1); if (l !== undefined) { setTrail((t) => t.slice(0, -1)); setPathRaw(l); } }}><ChevronLeft size={17} /></button>
        <button className="round" disabled={path === "/"} onClick={() => setPath(parent(path))}><ArrowUp size={17} /></button>
        <span className="pathpill"><HardDrive size={15} /> <a style={{ cursor: "pointer" }} onClick={() => setPath("/")}>Internal storage</a>{crumbs.map((c, i) => <span key={i}> / <a style={{ cursor: "pointer" }} onClick={() => setPath("/" + crumbs.slice(0, i + 1).join("/"))}>{c}</a></span>)}</span>
        <div className="grow" />
        <label className="search" style={{ width: 260 }}><Search size={16} /><input placeholder="Search the whole phone" value={query} onChange={(e) => setQuery(e.target.value)} /></label>
        <Seg value={view} onChange={setView} options={[["list", "List"], ["grid", "Grid"]]} />
        <label className="row small muted"><input type="checkbox" checked={hidden} onChange={(e) => setHidden(e.target.checked)} /> Hidden</label>
        <button className="round" title="New folder" onClick={() => setDialog({ kind: "mkdir" })}><FolderPlus size={16} /></button>
        <button onClick={upload}><FileUp size={15} /> Upload</button>
      </div>
      {picked.length > 0 && <div className="row" style={{ padding: "0 16px 8px", gap: 8 }}><span className="muted small">{picked.length} selected</span><button onClick={() => download(picked)}><Download size={14} /> Download</button>{picked.length === 1 && <button onClick={() => setDialog({ kind: "rename", e: picked[0] })}><Pencil size={14} /> Rename</button>}<button className="danger" onClick={() => setDialog({ kind: "delete", list: picked })}><Trash2 size={14} /> Delete</button></div>}
      <div className="scroll" style={{ padding: "0 8px" }}>
        {err && <div style={{ padding: 16, color: "var(--red)" }}>{err}</div>}
        {!err && shown.length === 0 && <Empty icon={<FolderIcon size={32} />} title={global ? "No matches" : "Empty folder"} />}
        {view === "list" ? (
          <table className="files"><thead><tr>{(["name", "size", "modified"] as SortKey[]).map((k) => <th key={k} onClick={() => setSort({ key: k, dir: sort.key === k ? (-sort.dir as 1 | -1) : 1 })}>{k === "modified" ? "Date Modified" : k[0].toUpperCase() + k.slice(1)}{sort.key === k ? (sort.dir === 1 ? " ˄" : " ˅") : ""}</th>)}</tr></thead>
            <tbody>{shown.map((e) => (
              <tr key={e.path} className={sel.has(e.path) ? "sel" : ""} onClick={(ev) => toggle(e, ev)} onDoubleClick={() => open(e)}>
                <td><span className="row" style={{ gap: 9 }}>{icon(e)}{e.name}{e.is_directory && e.child_count > 0 && <span className="muted small">{e.child_count}</span>}{global && <span className="muted small"> — {parent(e.path)}</span>}</span></td>
                <td>{e.is_directory ? "—" : FileUnit(e.size_bytes)}</td><td>{e.modified_at_ms ? new Date(e.modified_at_ms).toLocaleString([], { dateStyle: "medium", timeStyle: "short" }) : ""}</td></tr>))}</tbody></table>
        ) : (
          <div className="grid" style={{ gridTemplateColumns: "repeat(auto-fill, minmax(130px, 1fr))", padding: 14, gap: 10 }}>
            {shown.map((e) => (
              <div key={e.path} className={"tile" + (sel.has(e.path) ? " sel" : "")} onClick={(ev) => toggle(e, ev)} onDoubleClick={() => open(e)} title={e.name}>
                {isMedia(e) ? <img loading="lazy" alt="" src={mediaUrl(phoneId, "/media/thumb", { path: e.path, w: 256, h: 256 })} /> : <div style={{ display: "grid", placeItems: "center", height: "100%", color: e.is_directory ? "#6b5bf9" : "var(--fg2)" }}>{e.is_directory ? <FolderIcon size={48} fill="currentColor" /> : <FileIcon size={44} />}</div>}
                <div className="small" style={{ position: "absolute", left: 0, right: 0, bottom: 0, background: "rgba(0,0,0,.55)", color: "#fff", padding: "3px 8px", overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{e.name}</div>
              </div>))}
          </div>)}
      </div>
      <div className="row small muted" style={{ padding: "8px 16px", borderTop: "1px solid var(--line)" }}><span>{shown.length} items</span><div className="grow" />
        {bat && bat.storage_total_bytes > 0 && <><span>{FileUnit(bat.storage_total_bytes - bat.storage_free_bytes)} of {FileUnit(bat.storage_total_bytes)} used</span><div className="bar" style={{ width: 180 }}><div style={{ width: `${used * 100}%` }} /></div></>}</div>
      {active.length > 0 && <div className="small muted" style={{ padding: "6px 14px", borderTop: "1px solid var(--line)" }}>{active.map((t) => <span key={t.id} style={{ marginRight: 14 }}>{t.direction === "upload" ? "↑" : "↓"} {t.name} {t.total ? Math.round((t.done / t.total) * 100) : 0}%</span>)}</div>}
      {dialog?.kind === "mkdir" && <NameDialog title="New folder" initial="" action="Create" onClose={() => setDialog(null)} onSubmit={async (n) => { await op("MKDIR", join(path, n)); load(); }} />}
      {dialog?.kind === "rename" && <NameDialog title="Rename" initial={dialog.e.name} action="Rename" onClose={() => setDialog(null)} onSubmit={async (n) => { await op("RENAME", dialog.e.path, join(parent(dialog.e.path), n)); load(); }} />}
      {dialog?.kind === "delete" && (
        <Modal title={`Delete ${dialog.list.length === 1 ? `“${dialog.list[0].name}”` : `${dialog.list.length} items`} from your phone?`} onClose={() => setDialog(null)}>
          <div className="muted">This removes the files from the phone's storage and cannot be undone.</div>
          <div className="row"><div className="grow" /><button onClick={() => setDialog(null)}>Cancel</button>
            <button className="danger" onClick={async () => { const l = dialog.list; setDialog(null); for (const e of l) { try { await op("DELETE", e.path); } catch (x) { toast(String((x as Error).message), "error"); } } load(); }}>Delete</button></div></Modal>)}
      {preview && (
        <div className="viewer" onClick={(e) => { if (e.target === e.currentTarget) setPreview(null); }}>
          <div className="top"><b className="grow">{preview.name}</b><button onClick={() => download([preview])}>Download</button><button onClick={() => setPreview(null)}>Close</button></div>
          <div className="stage" onClick={(e) => { if (e.target === e.currentTarget) setPreview(null); }}>
            {preview.mime_type.startsWith("video/") ? <video src={mediaUrl(phoneId, "/media/file", { path: preview.path })} controls autoPlay />
              : preview.mime_type.startsWith("image/") ? <img src={mediaUrl(phoneId, "/media/file", { path: preview.path })} alt="" />
              : <iframe title="preview" src={mediaUrl(phoneId, "/media/file", { path: preview.path })} style={{ width: "90vw", height: "80vh", background: "#fff", border: 0 }} />}
          </div>
        </div>)}
    </div>
  );
}

function NameDialog({ title, initial, action, onClose, onSubmit }: { title: string; initial: string; action: string; onClose: () => void; onSubmit: (name: string) => Promise<void> }) {
  const [name, setName] = useState(initial);
  const [err, setErr] = useState<string | null>(null);
  const bad = !name.trim() || /[\\/]/.test(name);
  const go = async () => { try { await onSubmit(name.trim()); onClose(); } catch (e) { setErr(String((e as Error).message ?? e)); } };
  return (
    <Modal title={title} onClose={onClose}>
      <input autoFocus value={name} onChange={(e) => setName(e.target.value)} onKeyDown={(e) => { if (e.key === "Enter" && !bad) go(); }} />
      {err && <div style={{ color: "var(--red)" }}>{err}</div>}
      <div className="row"><div className="grow" /><button onClick={onClose}>Cancel</button><button className="primary" disabled={bad} onClick={go}>{action}</button></div>
    </Modal>
  );
}
