<script>
  import Scanner from '$lib/components/Scanner.svelte';
  import Progress from '$lib/components/Progress.svelte';
  import TreeView from '$lib/components/TreeView.svelte';
  import { scanStore } from '$lib/stores/scan.js';
  
  let store = $derived($scanStore);
  let scanning = $derived(store.scanning);
  let data = $derived(store.data);
  let error = $derived(store.error);
</script>

<div class="min-h-screen bg-gray-50">
  {#if scanning}
    <Progress />
    <div class="pt-32">
      <div class="text-center text-gray-400">
        <div class="animate-spin inline-block w-8 h-8 border-4 border-gray-300 border-t-blue-600 rounded-full"></div>
      </div>
    </div>
  {:else if error}
    <div class="max-w-4xl mx-auto p-6">
      <div class="bg-red-50 border border-red-200 rounded-lg p-4 mb-4">
        <div class="text-red-800 font-medium">Error</div>
        <div class="text-red-600 text-sm mt-1">{error}</div>
      </div>
      <button
        onclick={() => scanStore.reset()}
        class="px-4 py-2 bg-gray-100 hover:bg-gray-200 text-gray-700 rounded-md transition-colors"
      >
        Back
      </button>
    </div>
  {:else if data}
    <TreeView />
  {:else}
    <div class="min-h-screen flex items-center justify-center">
      <Scanner />
    </div>
  {/if}
</div>
