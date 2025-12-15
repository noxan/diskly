<script lang="ts">
  import { onMount } from "svelte";
  import { HardDrive, RefreshCcw } from "lucide-svelte";
  import { volumeStore } from "$lib/stores/volumes";

  let state = $derived($volumeStore);
  let volumes = $derived(state.volumes);
  let loading = $derived(state.loading);
  let error = $derived(state.error);

  const loadVolumes = async () => {
    await volumeStore.refresh();
  };

  onMount(() => {
    loadVolumes();
  });

  function formatSize(bytes: number): string {
    if (bytes === 0) return "0 B";
    const k = 1024;
    const sizes = ["B", "KB", "MB", "GB", "TB", "PB"];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return `${(bytes / Math.pow(k, i)).toFixed(1)} ${sizes[i]}`;
  }

  function usagePercent(used: number, total: number): number {
    if (total === 0) return 0;
    return Math.min(100, Math.max(0, (used / total) * 100));
  }
</script>

<div class="bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-xl shadow-sm">
  <div class="flex items-center justify-between px-3 py-2.5 border-b border-gray-100 dark:border-gray-700">
    <div class="flex items-center gap-2 text-gray-800 dark:text-gray-100">
      <HardDrive class="w-5 h-5" />
      <span class="text-base font-medium">Volumes</span>
    </div>
    <button
      class="flex items-center gap-2 text-xs text-blue-600 dark:text-blue-400 hover:text-blue-700 dark:hover:text-blue-300 disabled:opacity-60"
      onclick={loadVolumes}
      disabled={loading}
      title="Refresh volumes"
    >
      <RefreshCcw class={`w-4 h-4 ${loading ? "animate-spin" : ""}`} />
      Refresh
    </button>
  </div>

  <div class="p-3">
    {#if loading}
      <div class="text-sm text-gray-500 dark:text-gray-400">Loading volumes...</div>
    {:else if error}
      <div class="text-sm text-red-600 dark:text-red-400">{error}</div>
    {:else if volumes.length === 0}
      <div class="text-sm text-gray-500 dark:text-gray-400">No volumes detected.</div>
    {:else}
      <div class="grid gap-2 md:grid-cols-2 xl:grid-cols-3 auto-rows-fr">
        {#each volumes as volume (volume.mountPoint)}
          <div class="p-2.5 rounded-lg border border-gray-100 dark:border-gray-700 bg-gray-50/60 dark:bg-gray-900/40 flex flex-col gap-2">
            <div class="flex items-start justify-between gap-2">
              <div class="min-w-0 space-y-1">
                <div class="text-sm font-semibold text-gray-800 dark:text-gray-100 truncate" title={volume.mountPoint}>
                  {volume.name || volume.mountPoint}
                </div>
                <div class="text-[11px] text-gray-500 dark:text-gray-400 font-mono leading-tight truncate" title={volume.mountPoint}>
                  {volume.mountPoint}
                </div>
                <div class="text-[11px] text-gray-500 dark:text-gray-400 uppercase tracking-wide">{volume.fileSystem}</div>
              </div>
              {#if volume.isRemovable}
                <span class="px-2 py-1 text-[10px] font-semibold uppercase tracking-wide bg-amber-100 text-amber-800 dark:bg-amber-900/50 dark:text-amber-200 rounded self-start">
                  Removable
                </span>
              {/if}
            </div>

            {#if volume.totalSpace > 0}
              {#key volume.mountPoint}
                <div class="space-y-1.5">
                  <div class="flex items-center justify-between text-[11px] text-gray-500 dark:text-gray-400 leading-tight">
                    <span class="truncate">
                      Used {formatSize(volume.totalSpace - volume.availableSpace)} ({usagePercent(volume.totalSpace - volume.availableSpace, volume.totalSpace).toFixed(1)}%)
                    </span>
                    <span class="shrink-0">Total {formatSize(volume.totalSpace)}</span>
                  </div>
                  <div class="w-full h-1.5 bg-gray-200 dark:bg-gray-700 rounded-full overflow-hidden">
                    <div class="h-full bg-blue-600 dark:bg-blue-500" style={`width: ${usagePercent(volume.totalSpace - volume.availableSpace, volume.totalSpace).toFixed(1)}%`}></div>
                  </div>
                  <div class="text-[11px] text-gray-500 dark:text-gray-400 leading-tight">Free {formatSize(volume.availableSpace)}</div>
                </div>
              {/key}
            {/if}
          </div>
        {/each}
      </div>
    {/if}
  </div>
</div>
