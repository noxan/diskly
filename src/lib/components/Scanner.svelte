<script>
  import { invoke } from '@tauri-apps/api/core';
  import { scanStore } from '../stores/scan.js';

  let homeDir = '';

  async function loadHomeDir() {
    try {
      homeDir = await invoke('get_home_dir');
    } catch (err) {
      console.error('Failed to get home dir:', err);
    }
  }

  loadHomeDir();

  async function scanHome() {
    if (homeDir) {
      await scanStore.startScan(homeDir);
    }
  }

  async function pickAndScan() {
    try {
      const path = await invoke('pick_directory');
      if (path) {
        await scanStore.startScan(path);
      }
    } catch (err) {
      console.error('Failed to pick directory:', err);
    }
  }
</script>

<div class="flex flex-col items-center justify-center gap-4 p-8">
  <h1 class="text-4xl font-light text-gray-800 mb-2">Diskly</h1>
  <p class="text-gray-600 mb-4">Analyze disk space usage</p>
  
  <div class="flex gap-3">
    <button
      onclick={scanHome}
      class="px-6 py-3 bg-blue-600 hover:bg-blue-700 text-white rounded-lg font-medium transition-colors"
    >
      Scan Home Folder
    </button>
    
    <button
      onclick={pickAndScan}
      class="px-6 py-3 bg-gray-100 hover:bg-gray-200 text-gray-800 rounded-lg font-medium transition-colors"
    >
      Choose Directory
    </button>
  </div>
</div>
