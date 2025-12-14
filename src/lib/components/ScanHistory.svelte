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

  const countItems = (node: ScanHistoryEntry["root"]): number => {
    if (node.is_file) return 1;
    return 1 + (node.children?.reduce((sum, child) => sum + countItems(child), 0) ?? 0);
  };

  const orderedHistory = () => [...history].sort((a, b) => b.scannedAt - a.scannedAt);
</script>

{#if history.length > 0}
  <div class="bg-white dark:bg-gray-800 rounded-lg border border-gray-200 dark:border-gray-700 shadow-sm h-full">
    <div class="flex items-center gap-2 px-4 py-3 border-b border-gray-100 dark:border-gray-700">
      <Clock3 class="text-gray-500 dark:text-gray-400" size={18} />
      <h3 class="text-sm font-medium text-gray-800 dark:text-gray-100">Previous scans</h3>
    </div>

    <div class="p-3 space-y-2 max-h-[70vh] overflow-y-auto">
      {#each orderedHistory() as entry (entry.path)}
        <div class="p-3 rounded-md border border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-900/50">
          <div class="flex items-start gap-3">
            <div class="flex-1 min-w-0">
              <div class="flex items-center justify-between gap-2">
                <div class="text-sm text-gray-900 dark:text-gray-100 font-medium truncate" title={entry.root.name}>
                  {entry.root.name}
                </div>
                <span class="text-xs text-gray-500 dark:text-gray-400 flex items-center gap-1">
                  <Clock3 size={12} />
                  {formatDate(entry.scannedAt)}
                </span>
              </div>
              <div class="text-xs text-gray-500 dark:text-gray-400 truncate" title={entry.path}>{entry.path}</div>
              <div class="text-xs text-gray-600 dark:text-gray-300 mt-1">
                Size <strong>{formatSize(entry.root.size)}</strong> · Items
                <strong>{countItems(entry.root).toLocaleString()}</strong>
              </div>
            </div>

            <div class="flex items-center gap-2 flex-shrink-0 self-start">
              <button
                class="flex items-center gap-1 px-3 py-1.5 text-xs font-semibold bg-blue-600 text-white rounded hover:bg-blue-700 transition-colors shadow-sm"
                onclick={() => onOpen?.(entry.path)}
              >
                <FolderOpen size={12} />
                Open
              </button>
              <button
                class="flex items-center gap-1 px-2.5 py-1 text-[11px] text-gray-700 dark:text-gray-200 border border-gray-200 dark:border-gray-700 rounded hover:bg-gray-100 dark:hover:bg-gray-800 transition-colors"
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
