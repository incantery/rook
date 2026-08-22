<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { Mux, type Block } from '$lib/mux';
  import { createTerm, chosenKind, type TermHandle } from '$lib/term';
  import '../app.css';

  let blocks = $state<Block[]>([]);
  let attached = $state<Block | null>(null);
  let status = $state<'connecting' | 'ready' | 'closed'>('connecting');
  let listOpen = $state(true);
  let takeLease = $state(true);
  let token = $state('');

  let ctrlArmed = $state(false);
  let prefixArmed = $state(false);
  let paletteOpen = $state(false);
  let paletteQuery = $state('');
  let paletteIndex = $state(0);
  let paletteInput = $state<HTMLInputElement | null>(null);

  const filtered = $derived(
    blocks.filter((b) => {
      const q = paletteQuery.toLowerCase();
      if (!q) return true;
      return `${b.id} ${b.fg} ${b.place} ${b.cwd}`.toLowerCase().includes(q);
    })
  );

  let mux: Mux | null = null;
  let th: TermHandle | null = null;
  let termEl: HTMLDivElement;
  let resizeObs: ResizeObserver | null = null;
  let vtKind = $state('');

  // th.term, guarded — the page never touches an engine directly
  const term = {
    get cols() { return th?.term.cols ?? 80; },
    get rows() { return th?.term.rows ?? 24; },
    write: (d: Uint8Array) => th?.term.write(d),
    reset: () => th?.term.reset(),
    focus: () => th?.term.focus(),
  };
  const fitNow = () => th?.fit();

  function wsUrl(): string {
    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    return `${proto}://${location.host}/ws?token=${encodeURIComponent(token)}`;
  }

  function connect() {
    status = 'connecting';
    mux = new Mux(wsUrl(), {
      onDraw: (bytes) => term.write(bytes),
      onBlocks: (b) => (blocks = b),
      onBlockCreated: (id) => {
        // our own ` c / ` v — hop onto the new block
        const known = blocks.find((x) => x.id === id);
        attach(known ?? { id, place: '', fg: 'shell', size: '', cwd: '' });
      },
      onExit: () => detach(),
      onClose: () => (status = 'closed'),
    });
    mux.ready().then(() => {
      status = 'ready';
      localStorage.setItem('rook-token', token);
      mux?.requestBlocks();
    }).catch(() => (status = 'closed'));
  }

  function attach(b: Block) {
    if (!mux || !th) return;
    term.reset();
    attached = b;
    listOpen = false;
    // let the layout settle so fit measures the visible pane
    requestAnimationFrame(() => {
      fitNow();
      mux!.attachBlock(b.id, term.cols, term.rows, takeLease);
      term.focus();
    });
  }

  function detach() {
    attached = null;
    listOpen = true;
    mux?.requestBlocks();
  }

  function refresh() {
    mux?.requestBlocks();
  }

  onMount(async () => {
    const kind = chosenKind();
    try {
      th = await createTerm(termEl, kind);
    } catch (e) {
      // ghostty-web failed to boot (wasm load, old browser): fall back
      console.error('vt engine failed, falling back to xterm.js', e);
      th = await createTerm(termEl, 'xterm');
    }
    vtKind = th.kind;
    th.term.onData((d) => {
      if (!attached) return;
      // backtick prefix, same muscle memory as the TUI: a lone ` arms;
      // then 1-9 jumps to the nth block, n/p cycle, s opens the
      // palette, `` types a literal backtick. Pastes (multi-char
      // chunks) never arm.
      if (prefixArmed) {
        prefixArmed = false;
        if (d === '`') {
          mux?.input('`');
        } else if (d >= '1' && d <= '9') {
          const b = blocks[Number(d) - 1];
          if (b) attach(b);
        } else if (d === 'n' || d === 'p') {
          cycle(d === 'n' ? 1 : -1);
        } else if (d === 's') {
          openPalette();
        } else if (d === 'c' || d === 'v' || d === '-') {
          // typed action, not keystroke emulation: the server creates
          // the window/split and replies with the block id
          mux?.blockCmd(d);
        } else if (d === 'x') {
          mux?.blockCmd('x'); // pane dies -> server sends exit -> detach
        } else if (d === 'd') {
          detach();
        }
        return;
      }
      if (d === '`') {
        prefixArmed = true;
        return;
      }
      // sticky Ctrl from the key bar: the next typed character is
      // sent as its control code
      if (ctrlArmed && d.length === 1) {
        const c = d.toUpperCase().charCodeAt(0);
        if (c >= 64 && c < 128) {
          mux?.input(String.fromCharCode(c & 0x1f));
          ctrlArmed = false;
          return;
        }
      }
      mux?.input(d);
    });
    resizeObs = new ResizeObserver(() => {
      if (!attached || !th) return;
      fitNow();
      mux?.resize(term.cols, term.rows);
    });
    resizeObs.observe(termEl);
    const fromUrl = new URLSearchParams(location.search).get('token');
    if (fromUrl) {
      token = fromUrl;
      // don't leave the secret sitting in the address bar / history
      history.replaceState(null, '', location.pathname);
    } else {
      token = localStorage.getItem('rook-token') ?? '';
    }
    connect();
  });

  function cycle(dir: 1 | -1) {
    if (!blocks.length) return;
    const i = blocks.findIndex((b) => b.id === attached?.id);
    const next = blocks[(i + dir + blocks.length) % blocks.length];
    if (next) attach(next);
  }

  function openPalette() {
    paletteQuery = '';
    paletteIndex = 0;
    paletteOpen = true;
    requestAnimationFrame(() => paletteInput?.focus());
  }

  function closePalette() {
    paletteOpen = false;
    term.focus();
  }

  function paletteKey(e: KeyboardEvent) {
    if (e.key === 'Escape') {
      e.preventDefault();
      closePalette();
    } else if (e.key === 'ArrowDown' || (e.ctrlKey && e.key === 'j')) {
      e.preventDefault();
      paletteIndex = Math.min(paletteIndex + 1, filtered.length - 1);
    } else if (e.key === 'ArrowUp' || (e.ctrlKey && e.key === 'k')) {
      e.preventDefault();
      paletteIndex = Math.max(paletteIndex - 1, 0);
    } else if (e.key === 'Enter') {
      e.preventDefault();
      const b = filtered[paletteIndex];
      if (b) {
        closePalette();
        attach(b);
      }
    }
  }

  function globalKey(e: KeyboardEvent) {
    if ((e.ctrlKey || e.metaKey) && e.key === 'k') {
      e.preventDefault();
      if (paletteOpen) closePalette();
      else openPalette();
    }
  }

  function key(seq: string) {
    if (!attached) return;
    mux?.input(seq);
    term.focus();
  }

  onDestroy(() => {
    resizeObs?.disconnect();
    mux?.close();
    th?.term.dispose();
  });
</script>

<svelte:window onkeydown={globalKey} />

<div class="flex h-dvh flex-col md:flex-row">
  <!-- block list: sidebar on desktop, sheet on mobile -->
  <aside
    class="border-zinc-800 bg-zinc-900/60 md:w-72 md:shrink-0 md:border-r
           {listOpen ? 'block' : 'hidden'} md:block"
  >
    <div class="flex items-center gap-2 border-b border-zinc-800 px-3 py-2">
      <span class="text-lg">♜</span>
      <span class="font-semibold tracking-wide">rook</span>
      {#if vtKind}
        <span class="rounded bg-zinc-800 px-1 py-0.5 font-mono text-[10px] text-zinc-500">{vtKind}</span>
      {/if}
      <span
        class="ml-auto rounded px-1.5 py-0.5 text-xs
               {status === 'ready'
                 ? 'bg-emerald-900/60 text-emerald-300'
                 : status === 'connecting'
                   ? 'bg-amber-900/60 text-amber-300'
                   : 'bg-red-900/60 text-red-300'}"
      >
        {status}
      </span>
      {#if status === 'closed'}
        <button class="rounded bg-zinc-800 px-2 py-0.5 text-xs hover:bg-zinc-700" onclick={connect}>
          reconnect
        </button>
      {:else}
        <button class="rounded bg-zinc-800 px-2 py-0.5 text-xs hover:bg-zinc-700" onclick={refresh}>
          refresh
        </button>
      {/if}
    </div>

    {#if status === 'closed'}
      <form
        class="flex items-center gap-2 border-b border-zinc-800 px-3 py-2"
        onsubmit={(e) => {
          e.preventDefault();
          connect();
        }}
      >
        <input
          type="password"
          bind:value={token}
          placeholder="token (printed by rook-web)"
          class="min-w-0 flex-1 rounded bg-zinc-800 px-2 py-1 text-xs outline-none placeholder:text-zinc-600"
        />
        <button class="rounded bg-amber-700/70 px-2 py-1 text-xs hover:bg-amber-700">connect</button>
      </form>
    {/if}
    <label class="flex items-center gap-2 px-3 py-2 text-xs text-zinc-400">
      <input type="checkbox" bind:checked={takeLease} class="accent-amber-400" />
      take resize lease (drive the block at this size)
    </label>

    <ul class="divide-y divide-zinc-800/70">
      {#each blocks as b (b.id)}
        <li>
          <button
            class="flex w-full flex-col gap-0.5 px-3 py-2 text-left hover:bg-zinc-800/60
                   {attached?.id === b.id ? 'bg-zinc-800' : ''}"
            onclick={() => attach(b)}
          >
            <span class="flex items-baseline gap-2">
              <span class="font-mono text-xs text-zinc-500">#{b.id}</span>
              <span class="font-medium">{b.fg}</span>
              <span class="ml-auto font-mono text-xs text-zinc-500">{b.size}</span>
            </span>
            <span class="truncate font-mono text-xs text-zinc-500">{b.place} · {b.cwd}</span>
          </button>
        </li>
      {:else}
        <li class="px-3 py-4 text-sm text-zinc-500">no blocks — is rook-mux running?</li>
      {/each}
    </ul>
  </aside>

  <!-- terminal -->
  <main class="relative min-h-0 flex-1 flex-col {attached ? 'flex' : 'hidden md:flex'}">
    <div class="flex h-9 shrink-0 items-center gap-2 border-b border-zinc-800 bg-zinc-900/60 px-2 md:hidden">
      <button class="rounded bg-zinc-800 px-2 py-1 text-xs" onclick={detach}>← blocks</button>
      {#if attached}
        <span class="truncate font-mono text-xs text-zinc-400">
          #{attached.id} {attached.fg}
        </span>
      {/if}
    </div>
    <div class="min-h-0 flex-1 p-1" bind:this={termEl}></div>
    <!-- phone key bar: the keys a software keyboard doesn't have -->
    {#if attached}
      <div
        class="flex shrink-0 items-center gap-1 overflow-x-auto border-t border-zinc-800 bg-zinc-900/80 px-1 py-1 md:hidden"
        style="padding-bottom: max(0.25rem, env(safe-area-inset-bottom))"
      >
        <button class="kbar" onclick={() => key('\u001b')}>esc</button>
        <button class="kbar" onclick={() => key('\t')}>tab</button>
        <button
          class="kbar {ctrlArmed ? 'bg-amber-700 text-zinc-50' : ''}"
          onclick={() => {
            ctrlArmed = !ctrlArmed;
            term.focus();
          }}
        >
          ctrl
        </button>
        <button class="kbar" onclick={() => key('\u0003')}>^c</button>
        <button
          class="kbar {prefixArmed ? 'bg-amber-700 text-zinc-50' : ''}"
          onclick={() => {
            // arms the prefix like typing ` would; tap twice for a
            // literal backtick
            if (prefixArmed) {
              prefixArmed = false;
              key('`');
            } else {
              prefixArmed = true;
              term.focus();
            }
          }}
        >
          `
        </button>
        <button class="kbar" onclick={() => key('\u001b[A')}>↑</button>
        <button class="kbar" onclick={() => key('\u001b[B')}>↓</button>
        <button class="kbar" onclick={() => key('\u001b[D')}>←</button>
        <button class="kbar" onclick={() => key('\u001b[C')}>→</button>
        <button class="kbar" onclick={() => key('/')}>/</button>
        <button class="kbar" onclick={() => key(':')}>:</button>
      </div>
    {/if}
    {#if !attached}
      <div
        class="pointer-events-none absolute inset-0 hidden items-center justify-center text-zinc-600 md:flex"
      >
        pick a block — or ⌘K / ctrl+K
      </div>
    {/if}
    {#if prefixArmed}
      <div
        class="pointer-events-none absolute top-2 right-3 rounded bg-amber-700/80 px-2 py-0.5 font-mono text-xs"
      >
        `
      </div>
    {/if}
  </main>
</div>

{#if paletteOpen}
  <!-- quick-switch palette: ⌘K / ctrl+K or prefix-s -->
  <div
    class="fixed inset-0 z-50 flex items-start justify-center bg-black/60 pt-[12dvh]"
    onclick={closePalette}
    role="presentation"
  >
    <div
      class="w-[min(90vw,32rem)] overflow-hidden rounded-lg border border-zinc-700 bg-zinc-900 shadow-2xl"
      onclick={(e) => e.stopPropagation()}
      role="presentation"
    >
      <input
        bind:this={paletteInput}
        bind:value={paletteQuery}
        oninput={() => (paletteIndex = 0)}
        onkeydown={paletteKey}
        placeholder="switch block…"
        class="w-full border-b border-zinc-700 bg-transparent px-3 py-2.5 text-sm outline-none placeholder:text-zinc-600"
      />
      <ul class="max-h-[50dvh] overflow-y-auto">
        {#each filtered as b, i (b.id)}
          <li>
            <button
              class="flex w-full items-baseline gap-2 px-3 py-2 text-left text-sm
                     {i === paletteIndex ? 'bg-zinc-700/60' : 'hover:bg-zinc-800'}"
              onclick={() => {
                closePalette();
                attach(b);
              }}
            >
              <span class="font-mono text-xs text-zinc-500">#{b.id}</span>
              <span class="font-medium">{b.fg}</span>
              <span class="truncate font-mono text-xs text-zinc-500">{b.place} · {b.cwd}</span>
              {#if attached?.id === b.id}
                <span class="ml-auto text-xs text-amber-400">current</span>
              {/if}
            </button>
          </li>
        {:else}
          <li class="px-3 py-3 text-sm text-zinc-500">no match</li>
        {/each}
      </ul>
    </div>
  </div>
{/if}
