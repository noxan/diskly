<script lang="ts">
  import { scanStore, scanDirectory, cancelScan, pickDirectory } from "../stores/scan";

  $: state = $scanStore;

  async function scanHome() {
    if (!state.homePath) return;
    await scanDirectory(state.homePath);
  }

  async function chooseAndScan() {
    const picked = await pickDirectory();
    if (!picked) return;
    await scanDirectory(picked);
  }
</script>

<div class="flex flex-wrap items-center gap-2">
  <button
    class="rounded-lg bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50"
    disabled={state.scanning || !state.homePath}
    on:click={scanHome}
  >
    Scan Home Folder
  </button>

  <button
    class="rounded-lg border border-zinc-200 bg-white px-3 py-2 text-sm font-medium text-zinc-900 hover:bg-zinc-50 disabled:opacity-50"
    disabled={state.scanning}
    on:click={chooseAndScan}
  >
    Choose Directory
  </button>

  {#if state.scanning}
    <button
      class="rounded-lg border border-zinc-200 bg-white px-3 py-2 text-sm font-medium text-zinc-900 hover:bg-zinc-50"
      on:click={cancelScan}
    >
      Cancel
    </button>
  {/if}

  {#if state.rootPath}
    <div class="ml-auto truncate text-xs text-zinc-600">
      <span class="text-zinc-400">Root:</span> {state.rootPath}
    </div>
  {/if}
</div>

