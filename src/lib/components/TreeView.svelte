<script lang="ts">
  import TreeNode from './TreeNode.svelte';
  import { scanStore, type DirNode } from '../stores/scan';

  let store = $derived($scanStore);
  let data = $derived(store.data);
  let scanning = $derived(store.scanning);

  function formatSize(bytes: number): string {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
  }

  function newScan(): void {
    scanStore.reset();
  }
</script>

{#if data && !scanning}
  <div class="mx-auto max-w-4xl p-6">
    <div class="mb-6">
      <div class="mb-2 flex items-baseline justify-between">
        <h2 class="truncate text-2xl font-light text-gray-800 dark:text-gray-100" title={data.path}>
          {data.name}
        </h2>
        <button
          onclick={newScan}
          class="ml-4 flex-shrink-0 rounded-md bg-gray-100 px-4 py-2 text-sm text-gray-700 transition-colors hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-300 dark:hover:bg-gray-700"
        >
          New Scan
        </button>
      </div>

      <div class="mb-1 truncate text-sm text-gray-500 dark:text-gray-400" title={data.path}>
        {data.path}
      </div>

      <div class="flex gap-6 text-sm text-gray-600 dark:text-gray-400">
        <span>Total Size: <strong>{formatSize(data.size)}</strong></span>
        <span>Items: <strong>{data.item_count.toLocaleString()}</strong></span>
      </div>
    </div>

    <div
      class="overflow-hidden rounded-lg border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-800"
    >
      <div class="max-h-[70vh] overflow-y-auto">
        {#if data.children && data.children.length > 0}
          <div class="p-2">
            {#each data.children.sort((a, b) => b.size - a.size) as child (child.path)}
              <TreeNode node={child} maxSize={data.size} />
            {/each}
          </div>
        {:else}
          <div class="p-8 text-center text-gray-400 dark:text-gray-500">Empty directory</div>
        {/if}
      </div>
    </div>
  </div>
{/if}
