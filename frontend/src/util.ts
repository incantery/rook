// Small display helpers shared across surfaces.

export function ago(iso: string): string {
    const ms = Date.now() - new Date(iso).getTime();
    if (ms < 90_000) return "just now";
    const m = Math.floor(ms / 60_000);
    if (m < 60) return `${m}m ago`;
    const h = Math.floor(m / 60);
    if (h < 48) return `${h}h ago`;
    return `${Math.floor(h / 24)}d ago`;
}

export function tilde(p: string): string {
    return p.replace(/^\/Users\/[^/]+/, "~");
}

/** Middle-ellipsis long paths: the tail is the informative end. */
export function squeeze(p: string, max = 46): string {
    return p.length <= max ? p : p.slice(0, 14) + "…" + p.slice(-(max - 15));
}

/** Single-quote for a POSIX shell; newlines flatten to spaces because the
 *  command is typed into a live terminal, where \n would submit early. */
export function shellQuote(s: string): string {
    return "'" + s.replace(/\s*\n\s*/g, " ").replace(/'/g, "'\\''") + "'";
}
