<script lang="ts">
  import { onDestroy, onMount } from "svelte";
  import type { DirNode } from "../stores/scan";

  interface Props {
    root: DirNode;
  }

  let { root }: Props = $props();
  let canvas: HTMLCanvasElement | null = null;
  let ctx: CanvasRenderingContext2D | null = null;
  let resizeObserver: ResizeObserver | null = null;

  const isClient = typeof window !== "undefined";

  const formatSize = (bytes: number): string => {
    if (bytes === 0) return "0 B";
    const k = 1024;
    const sizes = ["B", "KB", "MB", "GB", "TB"];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + " " + sizes[i];
  };

  const buildDataset = () => {
    const items = root.children ?? [];
    const sorted = [...items].sort((a, b) => b.size - a.size);
    return sorted.slice(0, 12);
  };

  const getMaxSize = (items: DirNode[]): number => items.reduce((max, item) => Math.max(max, item.size), 0);

  const drawRoundedRect = (
    context: CanvasRenderingContext2D,
    x: number,
    y: number,
    width: number,
    height: number,
    radius: number,
  ) => {
    const r = Math.min(radius, height / 2, width / 2);
    context.beginPath();
    context.moveTo(x + r, y);
    context.lineTo(x + width - r, y);
    context.quadraticCurveTo(x + width, y, x + width, y + r);
    context.lineTo(x + width, y + height - r);
    context.quadraticCurveTo(x + width, y + height, x + width - r, y + height);
    context.lineTo(x + r, y + height);
    context.quadraticCurveTo(x, y + height, x, y + height - r);
    context.lineTo(x, y + r);
    context.quadraticCurveTo(x, y, x + r, y);
    context.closePath();
  };

  const renderChart = () => {
    const context = ctx;
    if (!isClient || !canvas || !context) return;

    const items = buildDataset();
    const dpr = window.devicePixelRatio || 1;
    const width = canvas.clientWidth * dpr;
    const minHeight = Math.max(240, items.length * 32);
    const height = minHeight * dpr;

    canvas.width = width;
    canvas.height = height;
    canvas.style.height = `${minHeight}px`;

    context.clearRect(0, 0, width, height);

    if (items.length === 0) {
      context.fillStyle = "#94a3b8";
      context.font = `${14 * dpr}px Inter, system-ui, -apple-system, sans-serif`;
      context.fillText("No items to chart", 12 * dpr, 24 * dpr);
      return;
    }

    const padding = 16 * dpr;
    const barHeight = 18 * dpr;
    const barGap = 12 * dpr;
    const nameOffset = 160 * dpr;
    const maxBarWidth = width - padding * 2 - nameOffset;
    const maxSize = getMaxSize(items) || 1;

    context.font = `${13 * dpr}px Inter, system-ui, -apple-system, sans-serif`;
    context.textBaseline = "middle";

    items.forEach((item, idx) => {
      const y = padding + idx * (barHeight + barGap);
      const percentage = item.size / maxSize;
      const barWidth = maxBarWidth * percentage;

      const rectX = padding + nameOffset;
      const rectY = y;

      context.fillStyle = idx < 3 ? "#2563eb" : "#4f46e5";
      drawRoundedRect(context, rectX, rectY, barWidth, barHeight, 6 * dpr);
      context.fill();

      context.fillStyle = "#0f172a";
      context.fillText(item.name, padding, y + barHeight / 2);

      context.fillStyle = "#475569";
      context.fillText(formatSize(item.size), padding + nameOffset + barWidth + 8 * dpr, y + barHeight / 2);
    });
  };

  onMount(() => {
    if (!canvas) return;
    const context = canvas.getContext("2d");
    if (!context) return;
    ctx = context;
    renderChart();

    resizeObserver = new ResizeObserver(renderChart);
    resizeObserver.observe(canvas);
  });

  onDestroy(() => resizeObserver?.disconnect());

  $effect(() => {
    renderChart();
  });
</script>

<div class="space-y-3">
  <div>
    <div class="text-sm text-gray-500 dark:text-gray-400">Top entries</div>
    <div class="text-lg font-semibold text-gray-800 dark:text-gray-100">Disk usage snapshot</div>
  </div>
  <div class="rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 p-3 shadow-sm">
    <canvas bind:this={canvas} class="w-full block"></canvas>
  </div>
</div>
