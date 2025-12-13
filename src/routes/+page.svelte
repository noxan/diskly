<script lang="ts">
  import { onMount } from "svelte";
  import Scanner from "$lib/components/Scanner.svelte";
  import Progress from "$lib/components/Progress.svelte";
  import TreeView from "$lib/components/TreeView.svelte";
  import { breadcrumb, initScanEvents, loadHomeDir, rootNode, scanStore } from "$lib/stores/scan";

  const formatBytes = (n: number) => {
    if (!Number.isFinite(n) || n <= 0) return "0 B";
    const units = ["B", "KB", "MB", "GB", "TB", "PB"];
    let i = 0;
    let v = n;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    const digits = i === 0 ? 0 : i < 3 ? 1 : 2;
    return `${v.toFixed(digits)} ${units[i]}`;
  };

  onMount(async () => {
    await initScanEvents();
    await loadHomeDir();
  });

  $: state = $scanStore;
  $: crumbs = $breadcrumb;
  $: root = $rootNode;
</script>

<main class="min-h-screen p-6">
  <div class="mx-auto flex h-[calc(100vh-3rem)] max-w-5xl flex-col gap-4">
    <div class="flex items-start justify-between gap-4">
      <div>
        <div class="text-2xl font-semibold tracking-tight text-zinc-900">Diskly</div>
        <div class="mt-1 text-sm text-zinc-600">
          Disk space analyzer with progressive scanning.
        </div>
      </div>
      <div class="text-right text-xs text-zinc-500">
        {#if root}
          <div class="tabular-nums">{formatBytes(root.size)}</div>
        {/if}
        <div class="tabular-nums">{state.totalScanned.toLocaleString()} items</div>
      </div>
    </div>

    <Scanner />

    <div class="flex flex-wrap items-center justify-between gap-3">
      <div class="flex min-w-0 items-center gap-2 text-sm text-zinc-700">
        <span class="shrink-0 rounded-md bg-white px-2 py-1 text-xs text-zinc-500 ring-1 ring-zinc-200">
          Path
        </span>
        <div class="min-w-0 truncate">
          {#if crumbs.length === 0}
            —
          {:else}
            {crumbs.join(" / ")}
          {/if}
        </div>
      </div>
      <Progress totalScanned={state.totalScanned} scanning={state.scanning} />
    </div>

    {#if state.error}
      <div class="rounded-xl border border-rose-200 bg-rose-50 px-4 py-3 text-sm text-rose-800">
        {state.error}
      </div>
    {/if}

    <div class="min-h-0 flex-1">
      <TreeView
        rootPath={state.rootPath}
        nodes={state.nodes}
        expanded={state.expanded}
        selectedPath={state.selectedPath}
      />
    </div>
  </div>
</main>
