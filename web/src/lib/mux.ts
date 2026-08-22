// The rook-mux wire protocol, browser edition. rook-web is a dumb
// pipe, so websocket binary frames are the same [type u8][len u32 LE]
// [payload] framing every other client speaks.

export const c2s = {
  attach: 1,
  stdin: 2,
  resize: 3,
  detach: 4,
  stats: 5,
  shutdown: 6,
  nav: 7,
  popup: 8,
  session: 9,
  blocks: 10,
  attachBlock: 11,
  blockCmd: 12,
} as const;

export const s2c = {
  draw: 1,
  exit: 2,
  statsText: 3,
  blocksText: 4,
  blockCreated: 5,
} as const;

export interface Block {
  id: number;
  place: string; // session:window
  fg: string;
  size: string;
  cwd: string;
}

export type MuxHandler = {
  onDraw: (bytes: Uint8Array) => void;
  onBlocks: (blocks: Block[]) => void;
  onBlockCreated: (id: number) => void;
  onExit: () => void;
  onClose: () => void;
};

function frame(kind: number, payload: Uint8Array): Uint8Array {
  const out = new Uint8Array(5 + payload.length);
  out[0] = kind;
  new DataView(out.buffer).setUint32(1, payload.length, true);
  out.set(payload, 5);
  return out;
}

export class Mux {
  private ws: WebSocket;
  private buf = new Uint8Array(0);
  private enc = new TextEncoder();
  private dec = new TextDecoder();

  constructor(url: string, private handler: MuxHandler) {
    this.ws = new WebSocket(url);
    this.ws.binaryType = 'arraybuffer';
    this.ws.onmessage = (ev) => this.feed(new Uint8Array(ev.data as ArrayBuffer));
    this.ws.onclose = () => handler.onClose();
    this.ws.onerror = () => handler.onClose();
  }

  ready(): Promise<void> {
    if (this.ws.readyState === WebSocket.OPEN) return Promise.resolve();
    return new Promise((resolve, reject) => {
      this.ws.addEventListener('open', () => resolve(), { once: true });
      this.ws.addEventListener('error', () => reject(new Error('connect failed')), { once: true });
    });
  }

  close() {
    this.ws.close();
  }

  private send(kind: number, payload: Uint8Array) {
    if (this.ws.readyState === WebSocket.OPEN) this.ws.send(frame(kind, payload));
  }

  requestBlocks() {
    this.send(c2s.blocks, new Uint8Array(0));
  }

  attachBlock(id: number, cols: number, rows: number, lease: boolean) {
    const p = new Uint8Array(9);
    const dv = new DataView(p.buffer);
    dv.setUint32(0, id, true);
    dv.setUint16(4, cols, true);
    dv.setUint16(6, rows, true);
    p[8] = (lease ? 1 : 0) | 2; // 2 = scrollback backfill
    this.send(c2s.attachBlock, p);
  }

  blockCmd(op: string) {
    this.send(c2s.blockCmd, this.enc.encode(op));
  }

  input(data: string) {
    this.send(c2s.stdin, this.enc.encode(data));
  }

  resize(cols: number, rows: number) {
    const p = new Uint8Array(4);
    const dv = new DataView(p.buffer);
    dv.setUint16(0, cols, true);
    dv.setUint16(2, rows, true);
    this.send(c2s.resize, p);
  }

  private feed(chunk: Uint8Array) {
    const merged = new Uint8Array(this.buf.length + chunk.length);
    merged.set(this.buf);
    merged.set(chunk, this.buf.length);
    this.buf = merged;
    for (;;) {
      if (this.buf.length < 5) return;
      const len = new DataView(this.buf.buffer, this.buf.byteOffset + 1, 4).getUint32(0, true);
      if (this.buf.length < 5 + len) return;
      const kind = this.buf[0];
      const payload = this.buf.slice(5, 5 + len);
      this.buf = this.buf.slice(5 + len);
      this.dispatch(kind, payload);
    }
  }

  private dispatch(kind: number, payload: Uint8Array) {
    switch (kind) {
      case s2c.draw:
        this.handler.onDraw(payload);
        break;
      case s2c.blocksText: {
        const blocks: Block[] = [];
        for (const line of this.dec.decode(payload).split('\n')) {
          if (!line.trim()) continue;
          const [id, place, fg, size, cwd] = line.split('\t');
          if (id === undefined || place === undefined) continue;
          blocks.push({ id: Number(id), place, fg: fg ?? '', size: size ?? '', cwd: cwd ?? '' });
        }
        this.handler.onBlocks(blocks);
        break;
      }
      case s2c.blockCreated: {
        if (payload.length >= 4) {
          const id = new DataView(payload.buffer, payload.byteOffset).getUint32(0, true);
          this.handler.onBlockCreated(id);
        }
        break;
      }
      case s2c.exit:
        this.handler.onExit();
        break;
    }
  }
}
