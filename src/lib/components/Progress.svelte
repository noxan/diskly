<script>
  import { scanStore } from '../stores/scan.js';

  let store = $derived($scanStore);
  let currentPath = $derived(store.currentPath);
  let totalScanned = $derived(store.totalScanned);
</script>

<div class="fixed top-0 left-0 right-0 bg-white border-b border-gray-200 p-4 shadow-sm">
  <div class="max-w-4xl mx-auto flex items-center justify-between">
    <div class="flex-1 min-w-0">
      <div class="text-sm text-gray-600 mb-1">
        Scanning... {totalScanned.toLocaleString()} items
      </div>
      <div class="text-xs text-gray-400 truncate">
        {currentPath}
      </div>
    </div>
    
    <button
      onclick={() => scanStore.cancelScan()}
      class="ml-4 px-4 py-2 text-sm bg-red-50 hover:bg-red-100 text-red-600 rounded-md transition-colors"
    >
      Cancel
    </button>
  </div>
  
  <div class="max-w-4xl mx-auto mt-3">
    <div class="w-full bg-gray-200 rounded-full h-1 overflow-hidden">
      <div class="h-full bg-blue-600 animate-pulse" style="width: 100%;"></div>
    </div>
  </div>
</div>
