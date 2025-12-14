<script lang="ts">
  import type { ScanHistoryEntry } from '../stores/scan';
  import { FolderOpen, RefreshCw } from 'lucide-svelte';

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

  const formatDate = (timestamp: number): string => {
    const date = new Date(timestamp);
    const now = new Date();
    const diff = now.getTime() - date.getTime();
    const hours = Math.floor(diff / (1000 * 60 * 60));

    if (hours < 1) return 'Just now';
    if (hours < 24) return `${hours}h ago`;
    if (hours < 48) return 'Yesterday';
    return date.toLocaleDateString(undefined, {
      month: 'short',
      day: 'numeric'
    });
  };

  const countItems = (node: ScanHistoryEntry['root']): number => {
    if (node.is_file) return 1;
    return 1 + (node.children?.reduce((sum, child) => sum + countItems(child), 0) ?? 0);
  };

  const orderedHistory = () => [...history].sort((a, b) => b.scannedAt - a.scannedAt);
</script>

{#if history.length > 0}
  <div class="h-full">
    <h3 class="mb-3 text-xs font-medium tracking-wide text-gray-500 uppercase dark:text-gray-400">
      Recent
    </h3>

    <div class="max-h-[70vh] space-y-1 overflow-y-auto">
      {#each orderedHistory() as entry (entry.path)}
        <div
          class="group w-full cursor-pointer rounded-lg border border-transparent px-3 py-2.5 transition-all hover:border-gray-200 hover:bg-gray-50 dark:hover:border-gray-700 dark:hover:bg-gray-800/50"
          onclick={() => onOpen?.(entry.path)}
          role="button"
          tabindex="0"
          onkeydown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') {
              e.preventDefault();
              onOpen?.(entry.path);
            }
          }}
        >
          <div class="mb-1 flex items-start justify-between gap-2">
            <div class="min-w-0 flex-1">
              <div
                class="truncate font-medium text-gray-900 dark:text-gray-100"
                title={entry.root.name}
              >
                {entry.root.name}
              </div>
              <div
                class="mt-0.5 truncate text-xs text-gray-500 dark:text-gray-400"
                title={entry.path}
              >
                {entry.path}
              </div>
            </div>
            <div
              class="flex flex-shrink-0 items-center gap-1.5 opacity-0 transition-opacity group-hover:opacity-100"
            >
              <button
                class="rounded p-1 text-gray-600 hover:bg-gray-200 hover:text-gray-900 dark:text-gray-400 dark:hover:bg-gray-700 dark:hover:text-gray-100"
                onclick={(e) => {
                  e.stopPropagation();
                  onRescan?.(entry.path);
                }}
                aria-label="Rescan"
              >
                <RefreshCw size={14} />
              </button>
            </div>
          </div>

          <div class="flex items-center gap-3 text-xs text-gray-500 dark:text-gray-400">
            <span>{formatSize(entry.root.size)}</span>
            <span>·</span>
            <span>{countItems(entry.root).toLocaleString()} items</span>
            <span>·</span>
            <span>{formatDate(entry.scannedAt)}</span>
          </div>
        </div>
      {/each}
    </div>
  </div>
{/if}
