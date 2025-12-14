<script lang="ts">
  import TreeNode from "./TreeNode.svelte";
  import { scanStore, type DirNode } from "../stores/scan";
  import { createVirtualizer } from "@tanstack/svelte-virtual";

  let store = $derived($scanStore);
  let data = $derived(store.data);
  let scanning = $derived(store.scanning);
  let containerElement = $state<HTMLDivElement | null>(null);
  let expandedPaths = $state<Set<string>>(new Set());

  interface FlatNode {
    node: DirNode;
    depth: number;
    parentSize: number;
  }

  function formatSize(bytes: number): string {
    if (bytes === 0) return "0 B";
    const k = 1024;
    const sizes = ["B", "KB", "MB", "GB", "TB"];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + " " + sizes[i];
  }

  function countItems(node: DirNode): number {
    if (node.is_file) return 1;
    let count = 1;
    if (node.children) {
      for (const child of node.children) {
        count += countItems(child);
      }
    }
    return count;
  }

  function flattenTree(
    node: DirNode,
    depth: number = 0,
    parentSize: number = 0
  ): FlatNode[] {
    const result: FlatNode[] = [];
    if (depth === 0 && node.children) {
      // Children are already sorted by size in Rust backend
      for (const child of node.children) {
        result.push({ node: child, depth, parentSize: node.size });
        if (
          !child.is_file &&
          child.children &&
          expandedPaths.has(child.path)
        ) {
          result.push(...flattenTree(child, depth + 1, child.size));
        }
      }
    } else if (!node.is_file && node.children) {
      // Children are already sorted by size in Rust backend
      for (const child of node.children) {
        result.push({ node: child, depth, parentSize });
        if (
          !child.is_file &&
          child.children &&
          expandedPaths.has(child.path)
        ) {
          result.push(...flattenTree(child, depth + 1, child.size));
        }
      }
    }
    return result;
  }

  let flatNodes = $derived.by(() => {
    if (!data || !data.children) return [];
    return flattenTree(data);
  });

  const virtualizerStore = $derived.by(() => {
    if (!containerElement) return null;
    return createVirtualizer({
      count: flatNodes.length,
      getScrollElement: () => containerElement!,
      estimateSize: () => 60,
      overscan: 5,
    });
  });

  function toggleExpand(path: string): void {
    expandedPaths = new Set(expandedPaths);
    if (expandedPaths.has(path)) {
      expandedPaths.delete(path);
    } else {
      expandedPaths.add(path);
    }
  }

  function newScan(): void {
    scanStore.reset();
    expandedPaths = new Set();
  }
</script>

{#if data && !scanning}
  <div class="max-w-4xl mx-auto p-6">
    <div class="mb-6">
      <div class="flex items-baseline justify-between mb-2">
        <h2
          class="text-2xl font-light text-gray-800 dark:text-gray-100 truncate"
          title={data.path}
        >
          {data.name}
        </h2>
        <button
          onclick={newScan}
          class="ml-4 px-4 py-2 text-sm bg-gray-100 dark:bg-gray-800 hover:bg-gray-200 dark:hover:bg-gray-700 text-gray-700 dark:text-gray-300 rounded-md transition-colors flex-shrink-0"
        >
          New Scan
        </button>
      </div>

      <div
        class="text-sm text-gray-500 dark:text-gray-400 mb-1 truncate"
        title={data.path}
      >
        {data.path}
      </div>

      <div class="flex gap-6 text-sm text-gray-600 dark:text-gray-400">
        <span>Total Size: <strong>{formatSize(data.size)}</strong></span>
        <span>Items: <strong>{countItems(data).toLocaleString()}</strong></span>
      </div>
    </div>

    <div
      class="bg-white dark:bg-gray-800 rounded-lg border border-gray-200 dark:border-gray-700 overflow-hidden"
    >
      <div
        bind:this={containerElement}
        class="max-h-[70vh] overflow-y-auto"
      >
        {#if flatNodes.length > 0 && virtualizerStore}
          {@const v = $virtualizerStore}
          {#if v}
            <div
              style="height: {v.getTotalSize()}px; width: 100%; position: relative;"
              class="p-2"
            >
              {#each v.getVirtualItems() as virtualItem (virtualItem.key)}
                {@const flatNode = flatNodes[virtualItem.index]}
                <div
                  data-index={virtualItem.index}
                  style="position: absolute; top: 0; left: 0; width: 100%; transform: translateY({virtualItem.start}px);"
                >
                  <TreeNode
                    node={flatNode.node}
                    maxSize={flatNode.parentSize}
                    depth={flatNode.depth}
                    expanded={expandedPaths.has(flatNode.node.path)}
                    onToggleExpand={() => toggleExpand(flatNode.node.path)}
                  />
                </div>
              {/each}
            </div>
          {/if}
        {:else}
          <div class="p-8 text-center text-gray-400 dark:text-gray-500">
            Empty directory
          </div>
        {/if}
      </div>
    </div>
  </div>
{/if}
