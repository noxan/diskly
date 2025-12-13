<script lang="ts">
  import Scanner from "$lib/components/Scanner.svelte";
  import Progress from "$lib/components/Progress.svelte";
  import TreeView from "$lib/components/TreeView.svelte";
  import { scanStore } from "$lib/stores/scan";

  let store = $derived($scanStore);
  let scanning = $derived(store.scanning);
  let rootPath = $derived(store.rootPath);
  let error = $derived(store.error);
</script>

<div class="min-h-screen bg-gray-50 dark:bg-gray-900">
  {#if scanning}
    <Progress />
    <div class="pt-32">
      <div class="text-center text-gray-400 dark:text-gray-500">
        <div
          class="animate-spin inline-block w-8 h-8 border-4 border-gray-300 dark:border-gray-700 border-t-blue-600 dark:border-t-blue-500 rounded-full"
        ></div>
      </div>
    </div>
  {:else if error}
    <div class="max-w-4xl mx-auto p-6">
      <div
        class="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg p-4 mb-4"
      >
        <div class="text-red-800 dark:text-red-300 font-medium">Error</div>
        <div class="text-red-600 dark:text-red-400 text-sm mt-1">{error}</div>
      </div>
      <button
        onclick={() => scanStore.reset()}
        class="px-4 py-2 bg-gray-100 dark:bg-gray-800 hover:bg-gray-200 dark:hover:bg-gray-700 text-gray-700 dark:text-gray-300 rounded-md transition-colors"
      >
        Back
      </button>
    </div>
  {:else if rootPath}
    <TreeView />
  {:else}
    <div class="min-h-screen flex items-center justify-center">
      <Scanner />
    </div>
  {/if}
</div>
