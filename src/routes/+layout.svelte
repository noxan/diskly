<script lang="ts">
  import "../app.css";
  import { themeStore } from "$lib/stores/theme";
  import { onMount } from "svelte";

  onMount(() => {
    // Initialize theme on mount
    $themeStore;
  });
</script>

<slot />
