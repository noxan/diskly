<script lang="ts">
  import TreeNode from "./TreeNode.svelte";
  import { getChildren, type FileNode } from "../stores/scan";
  import { invoke } from "@tauri-apps/api/core";
  import {
    ChevronRight,
    ChevronDown,
    File,
    Folder,
    Eye,
    FolderOpen,
    Trash2,
  } from "lucide-svelte";

  interface Props {
    node: FileNode;
    maxSize: number;
  }

  let { node, maxSize }: Props = $props();

  let expanded = $state(false);
  let showActions = $state(false);
  let loading = $state(false);

  async function toggleExpand(): Promise<void> {
    if (node.is_dir) {
      if (!expanded && !node.children) {
        // Fetch children on first expand
        loading = true;
        try {
          node.children = await getChildren(node.path);
        } catch (err) {
          console.error("Failed to load children:", err);
        } finally {
          loading = false;
        }
      }
      expanded = !expanded;
    }
  }

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
        alert("File deleted. Please rescan to update the view.");
      } catch (err) {
        console.error("Failed to move to trash:", err);
        alert(`Failed to move to trash: ${err}`);
      }
    }
  }
</script>

<div class="tree-node">
  <div
    class="w-full flex items-center gap-2 px-3 py-2 hover:bg-gray-50 dark:hover:bg-gray-700/50 rounded-md transition-colors min-h-[2.5rem]"
    onmouseenter={() => (showActions = true)}
    onmouseleave={() => (showActions = false)}
    role="button"
    tabindex="0"
    onclick={toggleExpand}
    onkeydown={(e) => e.key === "Enter" && toggleExpand()}
  >
    {#if node.is_dir}
      <span class="text-gray-400 dark:text-gray-500 w-4 flex-shrink-0">
        {#if loading}
          <span class="animate-spin">⟳</span>
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
      {#if node.is_dir}
        <Folder size={16} />
      {:else}
        <File size={16} />
      {/if}
    </span>

    <span
      class="flex-1 min-w-0 truncate text-sm text-gray-800 dark:text-gray-200"
      class:cursor-default={!node.is_dir}
      class:cursor-pointer={node.is_dir}
    >
      {node.name}
      {#if node.is_dir && node.child_count > 0}
        <span class="text-gray-400 text-xs ml-1">({node.child_count})</span>
      {/if}
    </span>

    <div class="flex gap-1 mr-2 h-6">
      {#if showActions}
        {#if !node.is_dir}
          <button
            onclick={handlePreview}
            class="p-1 bg-blue-100 dark:bg-blue-900 text-blue-700 dark:text-blue-200 rounded hover:bg-blue-200 dark:hover:bg-blue-800 transition-colors"
            title="Preview"
          >
            <Eye size={14} />
          </button>
        {/if}
        <button
          onclick={handleOpenInFinder}
          class="p-1 bg-green-100 dark:bg-green-900 text-green-700 dark:text-green-200 rounded hover:bg-green-200 dark:hover:bg-green-800 transition-colors"
          title="Open in Finder"
        >
          <FolderOpen size={14} />
        </button>
        <button
          onclick={handleDelete}
          class="p-1 bg-red-100 dark:bg-red-900 text-red-700 dark:text-red-200 rounded hover:bg-red-200 dark:hover:bg-red-800 transition-colors"
          title="Move to Trash"
        >
          <Trash2 size={14} />
        </button>
      {/if}
    </div>

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

  {#if expanded && node.is_dir && node.children && node.children.length > 0}
    <div class="ml-6 border-l border-gray-200 dark:border-gray-700 pl-2">
      {#each node.children as child (child.path)}
        <TreeNode node={child} maxSize={node.size} />
      {/each}
    </div>
  {/if}
</div>
