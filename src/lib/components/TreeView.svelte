<script lang="ts">
  import { onDestroy, onMount } from "svelte";
  import TreeNode from "./TreeNode.svelte";

  export let rootPath: string | null = null;
  export let nodes: Map<string, { name: string; path: string; size: number; children: string[] }>;
  export let expanded: Set<string>;
  export let selectedPath: string | null = null;

  const itemHeight = 28;
  const overscan = 12;

  let scroller: HTMLDivElement | null = null;
  let scrollTop = 0;
  let height = 0;
  let ro: ResizeObserver | null = null;

  type Row = { path: string; depth: number; parentSize: number };

  function flattenTree(root: string): Row[] {
    const out: Row[] = [];
    const rootNode = nodes.get(root);
    const stack: Row[] = [{ path: root, depth: 0, parentSize: rootNode?.size ?? 0 }];

    while (stack.length) {
      const cur = stack.pop()!;
      out.push(cur);

      if (!expanded.has(cur.path)) continue;
      const node = nodes.get(cur.path);
      const children = node?.children ?? [];
      const nextDepth = cur.depth + 1;
      const parentSize = node?.size ?? 0;

      for (let i = children.length - 1; i >= 0; i--) {
        stack.push({ path: children[i], depth: nextDepth, parentSize });
      }
    }

    return out;
  }

  $: rows = rootPath ? flattenTree(rootPath) : [];
  $: totalHeight = rows.length * itemHeight;
  $: start = Math.max(0, Math.floor(scrollTop / itemHeight) - overscan);
  $: end = Math.min(rows.length, start + Math.ceil(height / itemHeight) + overscan * 2);
  $: visible = rows.slice(start, end);

  onMount(() => {
    if (!scroller) return;
    ro = new ResizeObserver(() => {
      if (!scroller) return;
      height = scroller.clientHeight;
    });
    ro.observe(scroller);
    height = scroller.clientHeight;
  });

  onDestroy(() => {
    ro?.disconnect();
  });
</script>

<div
  class="h-full overflow-auto rounded-xl border border-zinc-200 bg-zinc-50/60"
  bind:this={scroller}
  on:scroll={() => (scrollTop = scroller?.scrollTop ?? 0)}
  role="tree"
>
  {#if !rootPath}
    <div class="p-6 text-sm text-zinc-600">Pick a folder to scan.</div>
  {:else if rows.length === 0}
    <div class="p-6 text-sm text-zinc-600">Scanning…</div>
  {:else}
    <div class="relative" style="height: {totalHeight}px">
      <div style="transform: translateY({start * itemHeight}px)">
        {#each visible as row (row.path)}
          <TreeNode
            path={row.path}
            depth={row.depth}
            parentSize={row.parentSize}
            {nodes}
            {expanded}
            {selectedPath}
          />
        {/each}
      </div>
    </div>
  {/if}
</div>

