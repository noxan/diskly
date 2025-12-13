<script lang="ts">
  import TreeNode from "./TreeNode.svelte";
  import type { DirNode } from "../stores/scan";
  import { scanStore } from "../stores/scan";
  import { invoke } from "@tauri-apps/api/core";

  interface Props {
    node: DirNode;
    maxSize: number;
  }

  let { node, maxSize }: Props = $props();

  let expanded = $state(false);
  let showActions = $state(false);

  function formatSize(bytes: number): string {
    if (bytes === 0) return "0 B";
    const k = 1024;
    const sizes = ["B", "KB", "MB", "GB", "TB"];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + " " + sizes[i];
  }

  function getPercentage(size: number, max: number): number {
    return max > 0 ? (size / max) * 100 : 0;
  }

  function sortedChildren(children: DirNode[]): DirNode[] {
    return [...children].sort((a, b) => b.size - a.size);
  }

  function toggleExpand(): void {
    if (!node.is_file) {
      expanded = !expanded;
    }
  }

  async function handlePreview(e: MouseEvent): Promise<void> {
    e.stopPropagation();
    try {
      await invoke("file_preview", { path: node.path });
    } catch (err) {
      console.error("Failed to preview:", err);
    }
  }

  async function handleOpenInFinder(e: MouseEvent): Promise<void> {
    e.stopPropagation();
    try {
      await invoke("file_open", { path: node.path });
    } catch (err) {
      console.error("Failed to open in Finder:", err);
    }
  }

  async function handleDelete(e: MouseEvent): Promise<void> {
    e.stopPropagation();
    if (confirm(`Are you sure you want to move "${node.name}" to trash?`)) {
      try {
        await invoke("file_delete", { path: node.path });
        scanStore.removeNode(node.path);
      } catch (err) {
        console.error("Failed to move to trash:", err);
        alert(`Failed to move to trash: ${err}`);
      }
    }
  }
</script>

<div class="tree-node">
  <div
    class="w-full flex items-center gap-2 px-3 py-2 hover:bg-gray-50 dark:hover:bg-gray-700/50 rounded-md transition-colors"
    onmouseenter={() => (showActions = true)}
    onmouseleave={() => (showActions = false)}
    role="button"
    tabindex="0"
    onclick={toggleExpand}
    onkeydown={(e) => e.key === "Enter" && toggleExpand()}
  >
    {#if !node.is_file}
      <span class="text-gray-400 dark:text-gray-500 w-4 flex-shrink-0">
        {expanded ? "▼" : "▶"}
      </span>
    {:else}
      <span class="w-4 flex-shrink-0"></span>
    {/if}

    <span class="text-lg mr-2">
      {node.is_file ? "📄" : "📁"}
    </span>

    <span
      class="flex-1 min-w-0 truncate text-sm text-gray-800 dark:text-gray-200"
      class:cursor-default={node.is_file}
      class:cursor-pointer={!node.is_file}
    >
      {node.name}
    </span>

    {#if showActions}
      <div class="flex gap-1 mr-2">
        <button
          onclick={handlePreview}
          class="px-2 py-1 text-xs bg-blue-100 dark:bg-blue-900 text-blue-700 dark:text-blue-200 rounded hover:bg-blue-200 dark:hover:bg-blue-800 transition-colors"
          title="Preview"
        >
          👁
        </button>
        <button
          onclick={handleOpenInFinder}
          class="px-2 py-1 text-xs bg-green-100 dark:bg-green-900 text-green-700 dark:text-green-200 rounded hover:bg-green-200 dark:hover:bg-green-800 transition-colors"
          title="Open in Finder"
        >
          📂
        </button>
        <button
          onclick={handleDelete}
          class="px-2 py-1 text-xs bg-red-100 dark:bg-red-900 text-red-700 dark:text-red-200 rounded hover:bg-red-200 dark:hover:bg-red-800 transition-colors"
          title="Move to Trash"
        >
          🗑️
        </button>
      </div>
    {/if}

    <span class="text-sm text-gray-500 dark:text-gray-400 flex-shrink-0 ml-2">
      {formatSize(node.size)}
    </span>
  </div>

  <div class="px-3 mb-1">
    <div class="h-1 bg-gray-100 dark:bg-gray-700 rounded-full overflow-hidden">
      <div
        class="h-full bg-blue-500 dark:bg-blue-600 transition-all"
        style="width: {getPercentage(node.size, maxSize)}%"
      ></div>
    </div>
  </div>

  {#if expanded && !node.is_file && node.children && node.children.length > 0}
    <div class="ml-6 border-l border-gray-200 dark:border-gray-700 pl-2">
      {#each sortedChildren(node.children) as child (child.path)}
        <TreeNode node={child} maxSize={node.size} />
      {/each}
    </div>
  {/if}
</div>
