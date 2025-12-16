<script lang="ts">
  import Scanner from '$lib/components/Scanner.svelte';
  import Progress from '$lib/components/Progress.svelte';
  import TreeView from '$lib/components/TreeView.svelte';
  import ScanHistory from '$lib/components/ScanHistory.svelte';
  import VolumeList from '$lib/components/VolumeList.svelte';
  import { scanStore } from '$lib/stores/scan';

  let store = $derived($scanStore);
  let scanning = $derived(store.scanning);
  let data = $derived(store.data);
  let error = $derived(store.error);
  let history = $derived(store.history);
  let hasHistory = $derived(history.length > 0);
  let showHistoryPanel = $derived(!scanning && hasHistory && !data);

  const handleOpenHistory = (path: string) => scanStore.openHistory(path);
  const handleRescanHistory = async (path: string) => scanStore.rescan(path);
</script>

<div class="min-h-screen bg-gray-50 dark:bg-gray-900">
  <div class="mx-auto p-6">
    <div class="space-y-6">
      {#if scanning}
        <Progress />
      {:else if error}
        <div class="max-w-4xl">
          <div
            class="mb-4 rounded-lg border border-red-200 bg-red-50 p-4 dark:border-red-800 dark:bg-red-900/20"
          >
            <div class="font-medium text-red-800 dark:text-red-300">Error</div>
            <div class="mt-1 text-sm text-red-600 dark:text-red-400">
              {error}
            </div>
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
        <div class="flex min-h-[60vh] flex-col items-center justify-center gap-4">
          <Scanner />
          <div class="w-full max-w-3xl space-y-3">
            <VolumeList />
            {#if showHistoryPanel}
              <ScanHistory {history} onOpen={handleOpenHistory} onRescan={handleRescanHistory} />
            {/if}
          </div>
        </div>
      {/if}
    </div>
  </div>
</div>
