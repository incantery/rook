// The VT engine behind the page: ghostty-web by default — the same
// ghostty parser the rook-mux server runs, compiled to wasm — with
// xterm.js one flag away while ghostty-web is young:
//   localStorage.setItem('rook-vt', 'xterm')  // or 'ghostty'
export type TermKind = 'ghostty' | 'xterm';

export interface TermHandle {
  kind: TermKind;
  term: {
    cols: number;
    rows: number;
    write(data: Uint8Array): void;
    reset(): void;
    focus(): void;
    dispose(): void;
    onData(cb: (d: string) => void): void;
  };
  fit(): void;
}

export function chosenKind(): TermKind {
  const forced = localStorage.getItem('rook-vt');
  return forced === 'xterm' ? 'xterm' : 'ghostty';
}

const options = {
  fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
  fontSize: 13,
  theme: { background: '#09090b' },
  scrollback: 5000,
};

export async function createTerm(el: HTMLElement, kind: TermKind): Promise<TermHandle> {
  if (kind === 'ghostty') {
    const g = await import('ghostty-web');
    await g.init();
    const term = new g.Terminal(options);
    const fit = new g.FitAddon();
    term.loadAddon(fit);
    term.open(el);
    return { kind, term: term as unknown as TermHandle['term'], fit: () => fit.fit() };
  }
  const { Terminal } = await import('@xterm/xterm');
  const { FitAddon } = await import('@xterm/addon-fit');
  const term = new Terminal({ ...options, allowProposedApi: true });
  const fit = new FitAddon();
  term.loadAddon(fit);
  term.open(el);
  return { kind, term: term as unknown as TermHandle['term'], fit: () => fit.fit() };
}
