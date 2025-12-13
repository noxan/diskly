<script lang="ts">
  import TreeNode from "./TreeNode.svelte";
  import { scanStore, getChildren, type FileNode } from "../stores/scan";

  let store = $derived($scanStore);
  let rootPath = $derived(store.rootPath);
  let scanning = $derived(store.scanning);
  let totalSize = $derived(store.totalSize);
  let totalScanned = $derived(store.totalScanned);

  let rootChildren = $state<FileNode[]>([]);
  let loading = $state(false);

  $effect(() => {
    if (rootPath && !scanning) {
      loadRootChildren();
    }
  });

  async function loadRootChildren() {
    if (!rootPath) return;
    loading = true;
    try {
      rootChildren = await getChildren(rootPath);
    } catch (err) {
      console.error("Failed to load root children:", err);
    } finally {
      loading = false;
    }
  }

  function formatSize(bytes: number): string {
    if (bytes === 0) return "0 B";
    const k = 1024;
    const sizes = ["B", "KB", "MB", "GB", "TB"];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + " " + sizes[i];
  }

  function getRootName(path: string): string {
    const parts = path.split(/[/\\]/);
    return parts[parts.length - 1] || path;
  }

  function newScan(): void {
    scanStore.reset();
    rootChildren = [];
  }
</script>

{#if rootPath && !scanning && !loading}
  <div class="max-w-4xl mx-auto p-6">
    <div class="mb-6">
      <div class="flex items-baseline justify-between mb-2">
        <h2
          class="text-2xl font-light text-gray-800 dark:text-gray-100 truncate"
          title={rootPath}
        >
          {getRootName(rootPath)}
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
        title={rootPath}
      >
        {rootPath}
      </div>

      <div class="flex gap-6 text-sm text-gray-600 dark:text-gray-400">
        <span>Total Size: <strong>{formatSize(totalSize)}</strong></span>
        <span>Items: <strong>{totalScanned.toLocaleString()}</strong></span>
      </div>
    </div>

    <div
      class="bg-white dark:bg-gray-800 rounded-lg border border-gray-200 dark:border-gray-700 overflow-hidden"
    >
      <div class="max-h-[70vh] overflow-y-auto">
        {#if rootChildren.length > 0}
          <div class="p-2">
            {#each rootChildren as child (child.path)}
              <TreeNode node={child} maxSize={totalSize} />
            {/each}
          </div>
        {:else}
          <div class="p-8 text-center text-gray-400 dark:text-gray-500">
            Empty directory
          </div>
        {/if}
      </div>
    </div>
  </div>
{/if}
