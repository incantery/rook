<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { Terminal } from '@xterm/xterm';
  import { FitAddon } from '@xterm/addon-fit';
  import { Mux, type Block } from '$lib/mux';
  import '../app.css';

  let blocks = $state<Block[]>([]);
  let attached = $state<Block | null>(null);
  let status = $state<'connecting' | 'ready' | 'closed'>('connecting');
  let listOpen = $state(true);
  let takeLease = $state(true);
  let token = $state('');

  let ctrlArmed = $state(false);

  let mux: Mux | null = null;
  let term: Terminal | null = null;
  let fit: FitAddon | null = null;
  let termEl: HTMLDivElement;
  let resizeObs: ResizeObserver | null = null;

  function wsUrl(): string {
    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    return `${proto}://${location.host}/ws?token=${encodeURIComponent(token)}`;
  }

  function connect() {
    status = 'connecting';
    mux = new Mux(wsUrl(), {
      onDraw: (bytes) => term?.write(bytes),
      onBlocks: (b) => (blocks = b),
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
    if (!mux || !term || !fit) return;
    term.reset();
    attached = b;
    listOpen = false;
    // let the layout settle so fit measures the visible pane
    requestAnimationFrame(() => {
      fit!.fit();
      mux!.attachBlock(b.id, term!.cols, term!.rows, takeLease);
      term!.focus();
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

  onMount(() => {
    term = new Terminal({
      fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
      fontSize: 13,
      theme: { background: '#09090b' },
      scrollback: 5000,
      allowProposedApi: true,
    });
    fit = new FitAddon();
    term.loadAddon(fit);
    term.open(termEl);
    term.onData((d) => {
      if (!attached) return;
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
      if (!attached || !term || !fit) return;
      fit.fit();
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

  function key(seq: string) {
    if (!attached) return;
    mux?.input(seq);
    term?.focus();
  }

  onDestroy(() => {
    resizeObs?.disconnect();
    mux?.close();
    term?.dispose();
  });
</script>

<div class="flex h-dvh flex-col md:flex-row">
  <!-- block list: sidebar on desktop, sheet on mobile -->
  <aside
    class="border-zinc-800 bg-zinc-900/60 md:w-72 md:shrink-0 md:border-r
           {listOpen ? 'block' : 'hidden'} md:block"
  >
    <div class="flex items-center gap-2 border-b border-zinc-800 px-3 py-2">
      <span class="text-lg">♜</span>
      <span class="font-semibold tracking-wide">rook</span>
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
            term?.focus();
          }}
        >
          ctrl
        </button>
        <button class="kbar" onclick={() => key('\u0003')}>^c</button>
        <button class="kbar" onclick={() => key('`')}>`</button>
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
        pick a block
      </div>
    {/if}
  </main>
</div>
