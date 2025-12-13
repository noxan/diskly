<script>
  import TreeNode from './TreeNode.svelte';
  
  let { node, maxSize } = $props();
  
  let expanded = $state(false);
  
  function formatSize(bytes) {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
  }
  
  function getPercentage(size, max) {
    return max > 0 ? (size / max) * 100 : 0;
  }
  
  function sortedChildren(children) {
    return [...children].sort((a, b) => b.size - a.size);
  }
  
  function toggleExpand() {
    if (!node.is_file) {
      expanded = !expanded;
    }
  }
</script>

<div class="tree-node">
  <button
    onclick={toggleExpand}
    class="w-full flex items-center gap-2 px-3 py-2 hover:bg-gray-50 rounded-md transition-colors text-left"
    class:cursor-default={node.is_file}
    class:cursor-pointer={!node.is_file}
  >
    {#if !node.is_file}
      <span class="text-gray-400 w-4 flex-shrink-0">
        {expanded ? '▼' : '▶'}
      </span>
    {:else}
      <span class="w-4 flex-shrink-0"></span>
    {/if}
    
    <span class="text-lg mr-2">
      {node.is_file ? '📄' : '📁'}
    </span>
    
    <span class="flex-1 min-w-0 truncate text-sm text-gray-800">
      {node.name}
    </span>
    
    <span class="text-sm text-gray-500 flex-shrink-0 ml-2">
      {formatSize(node.size)}
    </span>
  </button>
  
  <div class="px-3 mb-1">
    <div class="h-1 bg-gray-100 rounded-full overflow-hidden">
      <div
        class="h-full bg-blue-500 transition-all"
        style="width: {getPercentage(node.size, maxSize)}%"
      ></div>
    </div>
  </div>
  
  {#if expanded && !node.is_file && node.children && node.children.length > 0}
    <div class="ml-6 border-l border-gray-200 pl-2">
      {#each sortedChildren(node.children) as child (child.path)}
        <TreeNode node={child} maxSize={node.size} />
      {/each}
    </div>
  {/if}
</div>
