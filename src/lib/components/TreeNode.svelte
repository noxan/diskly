<script lang="ts">
  import TreeNode from './TreeNode.svelte';
  import type { DirNode } from '../stores/scan';
  import { scanStore } from '../stores/scan';
  import { invoke } from '@tauri-apps/api/core';
  import {
    ChevronRight,
    ChevronDown,
    File,
    Folder,
    Eye,
    FolderOpen,
    Trash2,
    Loader2
  } from 'lucide-svelte';

  interface Props {
    node: DirNode;
    maxSize: number;
  }

  let { node, maxSize }: Props = $props();

  let expanded = $state(false);
  let showActions = $state(false);
  let loadingChildren = $state(false);
  // Local children state for lazy-loaded children
  let localChildren = $state<DirNode[] | null>(null);

  function formatSize(bytes: number): string {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
  }

  function getPercentage(size: number, max: number): number {
    return max > 0 ? (size / max) * 100 : 0;
  }

  // Use local children if loaded, otherwise use node.children
  const effectiveChildren = $derived(localChildren ?? node.children ?? []);
  const sortedChildren = $derived([...effectiveChildren].sort((a, b) => b.size - a.size));

  // Check if we need to lazy load (has_children but no children array)
  const needsLazyLoad = $derived(node.has_children && effectiveChildren.length === 0);

  async function toggleExpand(): Promise<void> {
    if (node.is_file) return;

    const wasExpanded = expanded;
    expanded = !expanded;

    // If expanding and we need to lazy load children
    if (!wasExpanded && needsLazyLoad && !loadingChildren) {
      loadingChildren = true;
      try {
        const children = await invoke<DirNode[]>('load_children', { path: node.path });
        localChildren = children;
      } catch (err) {
        console.error('Failed to load children:', err);
      } finally {
        loadingChildren = false;
      }
    }
  }

  async function handlePreview(e: MouseEvent): Promise<void> {
    e.stopPropagation();
    try {
      await invoke('file_preview', { path: node.path });
    } catch (err) {
      console.error('Failed to preview:', err);
    }
  }

  async function handleOpenInFinder(e: MouseEvent): Promise<void> {
    e.stopPropagation();
    try {
      await invoke('file_open', { path: node.path });
    } catch (err) {
      console.error('Failed to open in Finder:', err);
    }
  }

  async function handleDelete(e: MouseEvent): Promise<void> {
    e.stopPropagation();
    if (confirm(`Are you sure you want to move "${node.name}" to trash?`)) {
      try {
        await invoke('file_delete', { path: node.path });
        scanStore.removeNode(node.path);
      } catch (err) {
        console.error('Failed to move to trash:', err);
        alert(`Failed to move to trash: ${err}`);
      }
    }
  }
</script>

<div class="tree-node">
  <div
    class="flex min-h-[2.5rem] w-full items-center gap-2 rounded-md px-3 py-2 transition-colors hover:bg-gray-50 dark:hover:bg-gray-700/50"
    onmouseenter={() => (showActions = true)}
    onmouseleave={() => (showActions = false)}
    role="button"
    tabindex="0"
    onclick={toggleExpand}
    onkeydown={(e) => e.key === 'Enter' && toggleExpand()}
  >
    {#if !node.is_file}
      <span class="w-4 flex-shrink-0 text-gray-400 dark:text-gray-500">
        {#if loadingChildren}
          <Loader2 size={16} class="animate-spin" />
        {:else if expanded}
          <ChevronDown size={16} />
        {:else}
          <ChevronRight size={16} />
        {/if}
      </span>
    {:else}
      <span class="w-4 flex-shrink-0"></span>
    {/if}

    <span class="mr-2 text-gray-600 dark:text-gray-400">
      {#if node.is_file}
        <File size={16} />
      {:else}
        <Folder size={16} />
      {/if}
    </span>

    <span
      class="min-w-0 flex-1 truncate text-sm text-gray-800 dark:text-gray-200"
      class:cursor-default={node.is_file}
      class:cursor-pointer={!node.is_file}
    >
      {node.name}
    </span>

    <div class="mr-2 flex h-6 gap-1">
      {#if showActions}
        {#if node.is_file}
          <button
            onclick={handlePreview}
            class="rounded bg-blue-100 p-1 text-blue-700 transition-colors hover:bg-blue-200 dark:bg-blue-900 dark:text-blue-200 dark:hover:bg-blue-800"
            title="Preview"
          >
            <Eye size={14} />
          </button>
        {/if}
        <button
          onclick={handleOpenInFinder}
          class="rounded bg-green-100 p-1 text-green-700 transition-colors hover:bg-green-200 dark:bg-green-900 dark:text-green-200 dark:hover:bg-green-800"
          title="Open in Finder"
        >
          <FolderOpen size={14} />
        </button>
        <button
          onclick={handleDelete}
          class="rounded bg-red-100 p-1 text-red-700 transition-colors hover:bg-red-200 dark:bg-red-900 dark:text-red-200 dark:hover:bg-red-800"
          title="Move to Trash"
        >
          <Trash2 size={14} />
        </button>
      {/if}
    </div>

    <span class="ml-2 flex-shrink-0 text-sm text-gray-500 dark:text-gray-400">
      {formatSize(node.size)}
    </span>
  </div>

  <div class="mb-1 px-3">
    <div class="h-1 overflow-hidden rounded-full bg-gray-100 dark:bg-gray-700">
      <div
        class="h-full bg-blue-500 transition-all dark:bg-blue-600"
        style="width: {getPercentage(node.size, maxSize)}%"
      ></div>
    </div>
  </div>

  {#if expanded && !node.is_file}
    <div class="ml-6 border-l border-gray-200 pl-2 dark:border-gray-700">
      {#if loadingChildren}
        <div class="px-3 py-2 text-sm text-gray-400">Loading...</div>
      {:else if sortedChildren.length > 0}
        {#each sortedChildren as child (child.path)}
          <TreeNode node={child} maxSize={node.size} />
        {/each}
      {:else if node.has_children}
        <div class="px-3 py-2 text-sm text-gray-400">Loading...</div>
      {/if}
    </div>
  {/if}
</div>
