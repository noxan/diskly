<script lang="ts">
  import { treemap, hierarchy, treemapSquarify, type HierarchyRectangularNode } from 'd3-hierarchy';
  import { scaleOrdinal } from 'd3-scale';
  import type { DirNode } from '../stores/scan';
  import { highlightedPath } from '../stores/highlight';

  interface Props {
    data: DirNode;
    width?: number;
    height?: number;
    onSelect?: (node: DirNode) => void;
  }

  let { data, width = 500, height = 400, onSelect }: Props = $props();

  let currentHighlight = $derived($highlightedPath);

  // Color palette - vibrant but cohesive
  const colors = [
    '#6366f1', // indigo
    '#8b5cf6', // violet
    '#ec4899', // pink
    '#f43f5e', // rose
    '#f97316', // orange
    '#eab308', // yellow
    '#22c55e', // green
    '#14b8a6', // teal
    '#06b6d4', // cyan
    '#3b82f6' // blue
  ];

  const colorScale = scaleOrdinal<string>().range(colors);

  function formatSize(bytes: number): string {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + ' ' + sizes[i];
  }

  // Build treemap layout using pre-computed sizes (handles lazy-loaded children)
  const treemapLayout = $derived.by(() => {
    // For treemap, we need leaf nodes. Convert top-level children to leaves using their size.
    const leafData: DirNode = {
      ...data,
      children:
        data.children?.map((child) => ({
          ...child,
          children: [] // Treat as leaf, use pre-computed size
        })) ?? []
    };

    const root = hierarchy(leafData)
      .sum((d) => (d.children && d.children.length > 0 ? 0 : d.size))
      .sort((a, b) => (b.value ?? 0) - (a.value ?? 0));

    const layout = treemap<DirNode>()
      .size([width, height])
      .paddingOuter(3)
      .paddingInner(2)
      .tile(treemapSquarify.ratio(1))
      .round(true);

    return layout(root);
  });

  // Get visible nodes (depth 1 = top-level children)
  const visibleNodes = $derived.by(() => {
    const nodes: HierarchyRectangularNode<DirNode>[] = [];
    treemapLayout.each((node) => {
      if (node.depth === 1) {
        const w = node.x1 - node.x0;
        const h = node.y1 - node.y0;
        // Only include nodes large enough to see
        if (w > 3 && h > 3) {
          nodes.push(node);
        }
      }
    });
    return nodes;
  });

  function getNodeColor(node: HierarchyRectangularNode<DirNode>): string {
    return colorScale(node.data.path);
  }

  function getNodeOpacity(node: HierarchyRectangularNode<DirNode>): number {
    const isHighlighted = currentHighlight === node.data.path;
    return isHighlighted ? 1 : 0.85;
  }

  function isNodeHighlighted(node: HierarchyRectangularNode<DirNode>): boolean {
    return currentHighlight === node.data.path;
  }

  function handleMouseEnter(path: string) {
    highlightedPath.set(path);
  }

  function handleMouseLeave() {
    highlightedPath.set(null);
  }

  function handleClick(node: HierarchyRectangularNode<DirNode>) {
    onSelect?.(node.data);
  }
</script>

<div class="treemap-container relative overflow-hidden rounded-lg bg-gray-900/50 backdrop-blur">
  <svg {width} {height} class="block">
    {#each visibleNodes as node (node.data.path)}
      {@const w = node.x1 - node.x0}
      {@const h = node.y1 - node.y0}
      {@const isHighlighted = isNodeHighlighted(node)}
      {@const showLabel = w > 40 && h > 24}
      <g
        transform="translate({node.x0}, {node.y0})"
        class="cursor-pointer"
        role="button"
        tabindex="0"
        onmouseenter={() => handleMouseEnter(node.data.path)}
        onmouseleave={handleMouseLeave}
        onclick={() => handleClick(node)}
        onkeydown={(e) => e.key === 'Enter' && handleClick(node)}
      >
        <rect
          width={w}
          height={h}
          fill={getNodeColor(node)}
          opacity={getNodeOpacity(node)}
          rx="2"
          class="transition-opacity duration-150"
          stroke={isHighlighted ? 'white' : 'transparent'}
          stroke-width={isHighlighted ? 2 : 0}
        />
        {#if showLabel}
          <clipPath id="clip-{node.data.path.replace(/[^a-zA-Z0-9]/g, '_')}">
            <rect width={w - 4} height={h - 4} x="2" y="2" />
          </clipPath>
          <g clip-path="url(#clip-{node.data.path.replace(/[^a-zA-Z0-9]/g, '_')})">
            <text
              x="4"
              y="14"
              class="fill-white text-[10px] font-medium"
              style="text-shadow: 0 1px 2px rgba(0,0,0,0.5)"
            >
              {node.data.name}
            </text>
            {#if h > 32}
              <text
                x="4"
                y="26"
                class="fill-white/70 text-[9px]"
                style="text-shadow: 0 1px 2px rgba(0,0,0,0.5)"
              >
                {formatSize(node.data.size)}
              </text>
            {/if}
          </g>
        {/if}
      </g>
    {/each}
  </svg>
</div>
