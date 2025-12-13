import { writable, derived } from 'svelte/store';
import { listen } from '@tauri-apps/api/event';
import { invoke } from '@tauri-apps/api/core';

function createScanStore() {
  const { subscribe, set, update } = writable({
    scanning: false,
    data: null,
    totalScanned: 0,
    currentPath: '',
    error: null,
  });

  let unlistenProgress = null;
  let unlistenComplete = null;
  let unlistenError = null;

  const setupListeners = async () => {
    // Clean up existing listeners
    if (unlistenProgress) await unlistenProgress();
    if (unlistenComplete) await unlistenComplete();
    if (unlistenError) await unlistenError();

    // Listen for directory complete events
    unlistenProgress = await listen('scan:directory_complete', (event) => {
      update(state => ({
        ...state,
        currentPath: event.payload.path,
        totalScanned: event.payload.total_scanned,
        // Update tree data progressively
        data: mergeNodeData(state.data, event.payload.node_data),
      }));
    });

    // Listen for scan complete
    unlistenComplete = await listen('scan:complete', (event) => {
      update(state => ({
        ...state,
        scanning: false,
        data: event.payload.root,
        totalScanned: event.payload.total_scanned,
        currentPath: '',
      }));
    });

    // Listen for errors
    unlistenError = await listen('scan:error', (event) => {
      update(state => ({
        ...state,
        scanning: false,
        error: event.payload.message,
        currentPath: '',
      }));
    });
  };

  // Merge node data into existing tree (for progressive updates)
  const mergeNodeData = (existingData, newNode) => {
    if (!existingData) {
      return newNode;
    }

    // Simple replacement strategy - in production, you'd do a proper merge
    // For now, just return the deepest node we have
    return existingData.size < newNode.size ? newNode : existingData;
  };

  return {
    subscribe,
    startScan: async (path) => {
      set({
        scanning: true,
        data: null,
        totalScanned: 0,
        currentPath: path,
        error: null,
      });

      await setupListeners();

      try {
        await invoke('scan_directory', { path });
      } catch (err) {
        update(state => ({
          ...state,
          scanning: false,
          error: err.toString(),
        }));
      }
    },
    cancelScan: async () => {
      try {
        await invoke('cancel_scan');
        update(state => ({
          ...state,
          scanning: false,
          currentPath: '',
        }));
      } catch (err) {
        console.error('Failed to cancel scan:', err);
      }
    },
    reset: () => {
      set({
        scanning: false,
        data: null,
        totalScanned: 0,
        currentPath: '',
        error: null,
      });
    },
  };
}

export const scanStore = createScanStore();
