<script>
  import { scanStore } from "../stores/scan.js";

  let store = $derived($scanStore);
  let currentPath = $derived(store.currentPath);
  let totalScanned = $derived(store.totalScanned);
</script>

<div
  class="fixed top-0 left-0 right-0 bg-white dark:bg-gray-800 border-b border-gray-200 dark:border-gray-700 p-4 shadow-sm"
>
  <div class="max-w-4xl mx-auto flex items-center justify-between">
    <div class="flex-1 min-w-0">
      <div class="text-sm text-gray-600 dark:text-gray-300 mb-1">
        Scanning... {totalScanned.toLocaleString()} items
      </div>
      <div class="text-xs text-gray-400 dark:text-gray-500 truncate">
        {currentPath}
      </div>
    </div>

    <button
      onclick={() => scanStore.cancelScan()}
      class="ml-4 px-4 py-2 text-sm bg-red-50 dark:bg-red-900/20 hover:bg-red-100 dark:hover:bg-red-900/30 text-red-600 dark:text-red-400 rounded-md transition-colors"
    >
      Cancel
    </button>
  </div>

  <div class="max-w-4xl mx-auto mt-3">
    <div
      class="w-full bg-gray-200 dark:bg-gray-700 rounded-full h-1 overflow-hidden"
    >
      <div
        class="h-full bg-blue-600 dark:bg-blue-500 animate-pulse"
        style="width: 100%;"
      ></div>
    </div>
  </div>
</div>
