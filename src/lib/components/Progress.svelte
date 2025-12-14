<script lang="ts">
  import { scanStore } from '../stores/scan';

  let store = $derived($scanStore);
  let currentPath = $derived(store.currentPath);
  let totalScanned = $derived(store.totalScanned);
</script>

<div
  class="fixed top-0 right-0 left-0 border-b border-gray-200 bg-white p-4 shadow-sm dark:border-gray-700 dark:bg-gray-800"
>
  <div class="mx-auto flex max-w-4xl items-center justify-between">
    <div class="min-w-0 flex-1">
      <div class="mb-1 text-sm text-gray-600 dark:text-gray-300">
        Scanning... {totalScanned.toLocaleString()} items
      </div>
      <div class="truncate text-xs text-gray-400 dark:text-gray-500">
        {currentPath}
      </div>
    </div>

    <button
      onclick={() => scanStore.cancelScan()}
      class="ml-4 rounded-md bg-red-50 px-4 py-2 text-sm text-red-600 transition-colors hover:bg-red-100 dark:bg-red-900/20 dark:text-red-400 dark:hover:bg-red-900/30"
    >
      Cancel
    </button>
  </div>

  <div class="mx-auto mt-3 max-w-4xl">
    <div class="h-1 w-full overflow-hidden rounded-full bg-gray-200 dark:bg-gray-700">
      <div class="h-full animate-pulse bg-blue-600 dark:bg-blue-500" style="width: 100%;"></div>
    </div>
  </div>
</div>
