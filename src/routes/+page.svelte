<script lang="ts">
  import Scanner from '$lib/components/Scanner.svelte';
  import Progress from '$lib/components/Progress.svelte';
  import TreeView from '$lib/components/TreeView.svelte';
  import ScanHistory from '$lib/components/ScanHistory.svelte';
  import { scanStore } from '$lib/stores/scan';

  let store = $derived($scanStore);
  let scanning = $derived(store.scanning);
  let data = $derived(store.data);
  let error = $derived(store.error);
  let history = $derived(store.history);

  const handleOpenHistory = (path: string) => scanStore.openHistory(path);
  const handleRescanHistory = async (path: string) => scanStore.rescan(path);
</script>

<div class="min-h-screen bg-gray-50 dark:bg-gray-900">
  <div class="mx-auto max-w-6xl p-6 lg:grid lg:grid-cols-[2fr,1fr] lg:gap-6">
    <div class="space-y-6">
      {#if scanning}
        <Progress />
        <div class="pt-16">
          <div class="text-center text-gray-400 dark:text-gray-500">
            <div
              class="inline-block h-8 w-8 animate-spin rounded-full border-4 border-gray-300 border-t-blue-600 dark:border-gray-700 dark:border-t-blue-500"
            ></div>
            <p class="mt-3 text-sm">Scanning {store.currentPath}</p>
          </div>
        </div>
      {:else if error}
        <div class="max-w-4xl">
          <div
            class="mb-4 rounded-lg border border-red-200 bg-red-50 p-4 dark:border-red-800 dark:bg-red-900/20"
          >
            <div class="font-medium text-red-800 dark:text-red-300">Error</div>
            <div class="mt-1 text-sm text-red-600 dark:text-red-400">{error}</div>
          </div>
          <button
            onclick={() => scanStore.reset()}
            class="rounded-md bg-gray-100 px-4 py-2 text-gray-700 transition-colors hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-300 dark:hover:bg-gray-700"
          >
            Back
          </button>
        </div>
      {:else if data}
        <TreeView />
      {:else}
        <div class="flex min-h-[60vh] items-center justify-center">
          <Scanner />
        </div>
      {/if}
    </div>

    <div class="mt-6 lg:mt-0">
      <ScanHistory {history} onOpen={handleOpenHistory} onRescan={handleRescanHistory} />
    </div>
  </div>
</div>
