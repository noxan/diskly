<script>
  import TreeNode from "./TreeNode.svelte";
  import { scanStore } from "../stores/scan.js";

  let store = $derived($scanStore);
  let data = $derived(store.data);
  let scanning = $derived(store.scanning);

  function formatSize(bytes) {
    if (bytes === 0) return "0 B";
    const k = 1024;
    const sizes = ["B", "KB", "MB", "GB", "TB"];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + " " + sizes[i];
  }

  function countItems(node) {
    if (node.is_file) return 1;
    let count = 1;
    if (node.children) {
      for (const child of node.children) {
        count += countItems(child);
      }
    }
    return count;
  }

  function newScan() {
    scanStore.reset();
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
      <div class="max-h-[70vh] overflow-y-auto">
        {#if data.children && data.children.length > 0}
          <div class="p-2">
            {#each data.children.sort((a, b) => b.size - a.size) as child (child.path)}
              <TreeNode node={child} maxSize={data.size} />
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
