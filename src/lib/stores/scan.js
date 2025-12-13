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
      update(state => {
        if (!state.scanning) return state; // Ignore if not scanning
        return {
          ...state,
          currentPath: event.payload.path,
          totalScanned: event.payload.total_scanned,
          // Update tree data progressively
          data: mergeNodeData(state.data, event.payload.node_data),
        };
      });
    });

    // Listen for scan complete
    unlistenComplete = await listen('scan:complete', (event) => {
      update(state => {
        if (!state.scanning) return state; // Ignore if not scanning
        return {
          ...state,
          scanning: false,
          data: event.payload.root,
          totalScanned: event.payload.total_scanned,
          currentPath: '',
        };
      });
    });

    // Listen for errors
    unlistenError = await listen('scan:error', (event) => {
      update(state => {
        if (!state.scanning) return state; // Ignore if not scanning
        return {
          ...state,
          scanning: false,
          error: event.payload.message,
          currentPath: '',
        };
      });
    });
  };

  // Merge node data into existing tree (for progressive updates)
  const mergeNodeData = (existingData, newNode) => {
    if (!existingData) {
      return newNode;
    }

    // Prefer newest update based on timestamp or sequence number
    if (newNode.updatedAt && existingData.updatedAt) {
      return newNode.updatedAt > existingData.updatedAt ? newNode : existingData;
    }
    if (newNode.seq !== undefined && existingData.seq !== undefined) {
      return newNode.seq > existingData.seq ? newNode : existingData;
    }

    // Default to newNode (treat as newer when no timing metadata exists)
    return newNode;
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
        set({
          scanning: false,
          data: null,
          totalScanned: 0,
          currentPath: '',
          error: null,
        });
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
