<script lang="ts">
  import { selectPath, toggleExpanded } from "../stores/scan";

  export let path: string;
  export let depth: number = 0;
  export let parentSize: number = 0;
  export let nodes: Map<string, { name: string; path: string; size: number; children: string[] }>;
  export let expanded: Set<string>;
  export let selectedPath: string | null = null;

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

  $: node = nodes.get(path);
  $: name = node?.name ?? path.split(/[/\\]+/).filter(Boolean).at(-1) ?? path;
  $: size = node?.size ?? 0;
  $: children = node?.children ?? [];
  $: isDir = children.length > 0;
  $: isOpen = expanded.has(path);
  $: pct = parentSize > 0 ? Math.min(100, (size / parentSize) * 100) : 0;
  $: isSelected = selectedPath === path;

  function onKeydown(e: KeyboardEvent) {
    if (e.key === "Enter" || e.key === " ") {
      e.preventDefault();
      selectPath(path);
      return;
    }
    if (isDir && (e.key === "ArrowRight" || e.key === "ArrowLeft")) {
      e.preventDefault();
      const wantOpen = e.key === "ArrowRight";
      if (wantOpen && !isOpen) toggleExpanded(path);
      if (!wantOpen && isOpen) toggleExpanded(path);
    }
  }
</script>

<div
  class={"group flex h-7 items-center gap-2 rounded-md px-2 hover:bg-white " + (isSelected ? "bg-white ring-1 ring-zinc-200" : "")}
  style="padding-left: {8 + depth * 14}px"
  role="treeitem"
  aria-expanded={isDir ? isOpen : undefined}
  aria-selected={isSelected}
  tabindex="0"
  on:click={() => selectPath(path)}
  on:dblclick={() => (isDir ? toggleExpanded(path) : null)}
  on:keydown={onKeydown}
>
  <button
    class="flex h-5 w-5 items-center justify-center rounded hover:bg-zinc-100 disabled:opacity-0"
    disabled={!isDir}
    on:click|stopPropagation={() => toggleExpanded(path)}
    aria-label={isOpen ? "Collapse" : "Expand"}
  >
    <svg
      class={"h-3 w-3 text-zinc-500 transition-transform " + (isOpen ? "rotate-90" : "")}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <path d="M6 4l4 4-4 4" />
    </svg>
  </button>

  {#if isDir}
    <svg class="h-4 w-4 text-amber-500" viewBox="0 0 20 20" fill="currentColor">
      <path
        d="M2.5 5.5A2.5 2.5 0 015 3h4l1.5 1.5H15A2.5 2.5 0 0117.5 7v7.5A2.5 2.5 0 0115 17H5a2.5 2.5 0 01-2.5-2.5V5.5z"
      />
    </svg>
  {:else}
    <svg class="h-4 w-4 text-zinc-400" viewBox="0 0 20 20" fill="currentColor">
      <path
        d="M6 2.5A2.5 2.5 0 018.5 0H13l5 5v12.5A2.5 2.5 0 0115.5 20h-9A2.5 2.5 0 014 17.5v-15z"
      />
    </svg>
  {/if}

  <div class="min-w-0 flex-1">
    <div class="flex items-baseline justify-between gap-3">
      <div class="truncate text-sm text-zinc-900">{name}</div>
      <div class="shrink-0 tabular-nums text-xs text-zinc-600">{formatBytes(size)}</div>
    </div>
    <div class="mt-1 h-1 w-full overflow-hidden rounded bg-zinc-100">
      <div class="h-full rounded bg-zinc-300" style="width: {pct}%"></div>
    </div>
  </div>
</div>

