<script lang="ts">
  import type { ScanHistoryEntry } from '../stores/scan';
  import { Clock3, RefreshCw, FolderOpen } from 'lucide-svelte';

  interface Props {
    history: ScanHistoryEntry[];
    onOpen?: (path: string) => void;
    onRescan?: (path: string) => void;
  }

  let { history = [], onOpen, onRescan }: Props = $props();

  const formatSize = (bytes: number): string => {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
  };

  const formatDate = (timestamp: number): string => new Date(timestamp).toLocaleString();

  const countItems = (node: ScanHistoryEntry['root']): number => {
    if (node.is_file) return 1;
    return 1 + (node.children?.reduce((sum, child) => sum + countItems(child), 0) ?? 0);
  };

  const orderedHistory = () => [...history].sort((a, b) => b.scannedAt - a.scannedAt);
</script>

{#if history.length > 0}
  <div
    class="h-full rounded-lg border border-gray-200 bg-white shadow-sm dark:border-gray-700 dark:bg-gray-800"
  >
    <div class="flex items-center gap-2 border-b border-gray-100 px-4 py-3 dark:border-gray-700">
      <Clock3 class="text-gray-500 dark:text-gray-400" size={18} />
      <h3 class="text-sm font-medium text-gray-800 dark:text-gray-100">Previous scans</h3>
    </div>

    <div class="max-h-[70vh] space-y-2 overflow-y-auto p-3">
      {#each orderedHistory() as entry (entry.path)}
        <div
          class="rounded-md border border-gray-200 bg-gray-50 p-3 dark:border-gray-700 dark:bg-gray-900/50"
        >
          <div class="flex items-start gap-3">
            <div class="min-w-0 flex-1">
              <div class="flex items-center justify-between gap-2">
                <div
                  class="truncate text-sm font-medium text-gray-900 dark:text-gray-100"
                  title={entry.root.name}
                >
                  {entry.root.name}
                </div>
                <span class="flex items-center gap-1 text-xs text-gray-500 dark:text-gray-400">
                  <Clock3 size={12} />
                  {formatDate(entry.scannedAt)}
                </span>
              </div>
              <div class="truncate text-xs text-gray-500 dark:text-gray-400" title={entry.path}>
                {entry.path}
              </div>
              <div class="mt-1 text-xs text-gray-600 dark:text-gray-300">
                Size <strong>{formatSize(entry.root.size)}</strong> · Items
                <strong>{countItems(entry.root).toLocaleString()}</strong>
              </div>
            </div>

            <div class="flex flex-shrink-0 items-center gap-2 self-start">
              <button
                class="flex items-center gap-1 rounded bg-blue-600 px-3 py-1.5 text-xs font-semibold text-white shadow-sm transition-colors hover:bg-blue-700"
                onclick={() => onOpen?.(entry.path)}
              >
                <FolderOpen size={12} />
                Open
              </button>
              <button
                class="flex items-center gap-1 rounded border border-gray-200 px-2.5 py-1 text-[11px] text-gray-700 transition-colors hover:bg-gray-100 dark:border-gray-700 dark:text-gray-200 dark:hover:bg-gray-800"
                onclick={() => onRescan?.(entry.path)}
                aria-label={`Rescan ${entry.root.name}`}
              >
                <RefreshCw size={12} />
                Rescan
              </button>
            </div>
          </div>
        </div>
      {/each}
    </div>
  </div>
{/if}
