<script lang="ts">
  import { invoke } from '@tauri-apps/api/core';
  import { scanStore } from '../stores/scan';

  let homeDir: string = '';

  async function loadHomeDir(): Promise<void> {
    try {
      homeDir = (await invoke<string>('get_home_dir')) || '';
    } catch (err) {
      console.error('Failed to get home dir:', err);
    }
  }

  loadHomeDir();

  async function scanHome(): Promise<void> {
    if (homeDir) {
      await scanStore.startScan(homeDir);
    }
  }

  async function pickAndScan(): Promise<void> {
    try {
      const path = await invoke<string>('pick_directory');
      if (path) {
        await scanStore.startScan(path);
      }
    } catch (err) {
      console.error('Failed to pick directory:', err);
    }
  }
</script>

<div class="flex flex-col items-center justify-center gap-4 p-8">
  <h1 class="mb-2 text-4xl font-light text-gray-800 dark:text-gray-100">Diskly</h1>
  <p class="mb-4 text-gray-600 dark:text-gray-400">Analyze disk space usage</p>

  <div class="flex gap-3">
    <button
      onclick={scanHome}
      class="rounded-lg bg-blue-600 px-6 py-3 font-medium text-white transition-colors hover:bg-blue-700 dark:bg-blue-500 dark:hover:bg-blue-600"
    >
      Scan Home Folder
    </button>

    <button
      onclick={pickAndScan}
      class="rounded-lg bg-gray-100 px-6 py-3 font-medium text-gray-800 transition-colors hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-200 dark:hover:bg-gray-700"
    >
      Choose Directory
    </button>
  </div>
</div>
