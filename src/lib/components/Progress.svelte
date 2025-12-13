<script lang="ts">
  export let totalScanned: number = 0;
  export let scanning: boolean = false;
</script>

<div class="flex items-center gap-3 text-sm text-zinc-600">
  <div
    class="h-1.5 w-24 overflow-hidden rounded-full bg-zinc-200"
    aria-hidden="true"
  >
    <div
      class="h-full w-full origin-left animate-pulse bg-zinc-400"
      style="transform: scaleX({scanning ? 1 : 0});"
    ></div>
  </div>
  <div class="tabular-nums">{totalScanned.toLocaleString()} scanned</div>
</div>

