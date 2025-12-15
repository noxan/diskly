<script lang="ts">
  import { onMount } from 'svelte';
  import { HardDrive, RefreshCcw } from 'lucide-svelte';
  import { volumeStore } from '$lib/stores/volumes';

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
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return `${(bytes / Math.pow(k, i)).toFixed(1)} ${sizes[i]}`;
  }

  function usagePercent(used: number, total: number): number {
    if (total === 0) return 0;
    return Math.min(100, Math.max(0, (used / total) * 100));
  }
</script>

<div
  class="rounded-xl border border-gray-200 bg-white p-3 shadow-sm dark:border-gray-700 dark:bg-gray-800"
>
  <div class="flex items-center justify-between gap-2">
    <div
      class="flex items-center gap-1.5 text-xs font-medium tracking-wide text-gray-500 uppercase dark:text-gray-400"
    >
      <HardDrive class="h-3.5 w-3.5" />
      <span>Volumes</span>
    </div>
    <button
      class="flex items-center gap-1.5 text-xs text-blue-600 hover:text-blue-700 disabled:opacity-60 dark:text-blue-400 dark:hover:text-blue-300"
      onclick={loadVolumes}
      disabled={loading}
      title="Refresh volumes"
    >
      <RefreshCcw class={`h-4 w-4 ${loading ? 'animate-spin' : ''}`} />
      Refresh
    </button>
  </div>

  <div class="pt-2">
    {#if loading}
      <div class="text-sm text-gray-500 dark:text-gray-400">Loading volumes...</div>
    {:else if error}
      <div class="text-sm text-red-600 dark:text-red-400">{error}</div>
    {:else if volumes.length === 0}
      <div class="text-sm text-gray-500 dark:text-gray-400">No volumes detected.</div>
    {:else}
      <div class="grid auto-rows-fr gap-2 md:grid-cols-2 xl:grid-cols-2">
        {#each volumes as volume (volume.mountPoint)}
          <div
            class="flex flex-col gap-2 rounded-lg border border-gray-100 bg-gray-50/60 p-2.5 dark:border-gray-700 dark:bg-gray-900/40"
          >
            <div class="flex items-start justify-between gap-2">
              <div class="min-w-0 space-y-1">
                <div
                  class="truncate text-sm font-semibold text-gray-800 dark:text-gray-100"
                  title={volume.mountPoint}
                >
                  {volume.name || volume.mountPoint}
                </div>
                <div
                  class="flex items-center gap-1.5 text-[11px] leading-tight text-gray-500 dark:text-gray-400"
                  title={volume.mountPoint}
                >
                  <span class="truncate font-mono">{volume.mountPoint}</span>
                  <span>·</span>
                  <span class="tracking-wide uppercase">{volume.fileSystem}</span>
                </div>
              </div>
              {#if volume.isRemovable}
                <span
                  class="self-start rounded-full bg-amber-100 px-2 py-0.5 text-[10px] font-semibold tracking-wide text-amber-800 uppercase dark:bg-amber-900/50 dark:text-amber-200"
                >
                  Removable
                </span>
              {/if}
            </div>

            {#if volume.totalSpace > 0}
              {#key volume.mountPoint}
                <div class="space-y-1.5">
                  <div
                    class="flex items-center justify-between text-[11px] leading-tight text-gray-500 dark:text-gray-400"
                  >
                    <span class="truncate">
                      Used {formatSize(volume.totalSpace - volume.availableSpace)} ({usagePercent(
                        volume.totalSpace - volume.availableSpace,
                        volume.totalSpace
                      ).toFixed(1)}%)
                    </span>
                    <span class="shrink-0">Total {formatSize(volume.totalSpace)}</span>
                  </div>
                  <div
                    class="h-1.5 w-full overflow-hidden rounded-full bg-gray-200 dark:bg-gray-700"
                  >
                    <div
                      class="h-full bg-blue-600 dark:bg-blue-500"
                      style={`width: ${usagePercent(volume.totalSpace - volume.availableSpace, volume.totalSpace).toFixed(1)}%`}
                    ></div>
                  </div>
                  <div class="text-[11px] leading-tight text-gray-500 dark:text-gray-400">
                    Free {formatSize(volume.availableSpace)}
                  </div>
                </div>
              {/key}
            {/if}
          </div>
        {/each}
      </div>
    {/if}
  </div>
</div>
