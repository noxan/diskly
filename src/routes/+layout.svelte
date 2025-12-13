<script>
  import "../app.css";
  import { themeStore } from "$lib/stores/theme.js";
  import { onMount } from "svelte";

  onMount(() => {
    // Initialize theme on mount
    $themeStore;
  });
</script>

<button
  onclick={() => themeStore.toggle()}
  class="fixed top-4 right-4 p-2 rounded-lg bg-gray-100 dark:bg-gray-800 hover:bg-gray-200 dark:hover:bg-gray-700 text-gray-700 dark:text-gray-300 transition-colors z-50"
  title="Toggle dark mode"
>
  <span class="text-xl">{$themeStore === "dark" ? "☀️" : "🌙"}</span>
</button>

<slot />
