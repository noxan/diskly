<script lang="ts">
  import Scanner from '$lib/components/Scanner.svelte';
  import Progress from '$lib/components/Progress.svelte';
  import TreeView from '$lib/components/TreeView.svelte';
  import { scanStore } from '$lib/stores/scan';

  let store = $derived($scanStore);
  let scanning = $derived(store.scanning);
  let data = $derived(store.data);
  let error = $derived(store.error);
</script>

<div class="min-h-screen bg-gray-50 dark:bg-gray-900">
  {#if scanning}
    <Progress />
    <div class="pt-32">
      <div class="text-center text-gray-400 dark:text-gray-500">
        <div
          class="inline-block h-8 w-8 animate-spin rounded-full border-4 border-gray-300 border-t-blue-600 dark:border-gray-700 dark:border-t-blue-500"
        ></div>
      </div>
    </div>
  {:else if error}
    <div class="mx-auto max-w-4xl p-6">
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
    <div class="flex min-h-screen items-center justify-center">
      <Scanner />
    </div>
  {/if}
</div>
