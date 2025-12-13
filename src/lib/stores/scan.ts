import { writable, type Writable } from "svelte/store";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";

export interface DirNode {
  name: string;
  path: string;
  size: number;
  children: DirNode[];
  is_file: boolean;
  updatedAt?: number;
  seq?: number;
}

interface ScanState {
  scanning: boolean;
  data: DirNode | null;
  totalScanned: number;
  currentPath: string;
  error: string | null;
}

interface ScanProgress {
  path: string;
  node_data: DirNode;
  total_scanned: number;
}

interface ScanComplete {
  root: DirNode;
  total_scanned: number;
}

interface ScanError {
  message: string;
}

interface ScanStore {
  subscribe: Writable<ScanState>["subscribe"];
  startScan: (path: string) => Promise<void>;
  cancelScan: () => Promise<void>;
  reset: () => void;
}

function createScanStore(): ScanStore {
  const { subscribe, set, update } = writable<ScanState>({
    scanning: false,
    data: null,
    totalScanned: 0,
    currentPath: "",
    error: null,
  });

  let unlistenProgress: UnlistenFn | null = null;
  let unlistenComplete: UnlistenFn | null = null;
  let unlistenError: UnlistenFn | null = null;

  const setupListeners = async (): Promise<void> => {
    // Clean up existing listeners
    if (unlistenProgress) await unlistenProgress();
    if (unlistenComplete) await unlistenComplete();
    if (unlistenError) await unlistenError();

    // Listen for directory complete events
    unlistenProgress = await listen<ScanProgress>("scan:directory_complete", (event) => {
      update((state) => {
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
    unlistenComplete = await listen<ScanComplete>("scan:complete", (event) => {
      update((state) => {
        if (!state.scanning) return state; // Ignore if not scanning
        return {
          ...state,
          scanning: false,
          data: event.payload.root,
          totalScanned: event.payload.total_scanned,
          currentPath: "",
        };
      });
    });

    // Listen for errors
    unlistenError = await listen<ScanError>("scan:error", (event) => {
      update((state) => {
        if (!state.scanning) return state; // Ignore if not scanning
        return {
          ...state,
          scanning: false,
          error: event.payload.message,
          currentPath: "",
        };
      });
    });
  };

  // Merge node data into existing tree (for progressive updates)
  const mergeNodeData = (existingData: DirNode | null, newNode: DirNode): DirNode => {
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
    startScan: async (path: string): Promise<void> => {
      set({
        scanning: true,
        data: null,
        totalScanned: 0,
        currentPath: path,
        error: null,
      });

      await setupListeners();

      try {
        await invoke("scan_directory", { path });
      } catch (err) {
        update((state) => ({
          ...state,
          scanning: false,
          error: err instanceof Error ? err.message : String(err),
        }));
      }
    },
    cancelScan: async (): Promise<void> => {
      try {
        await invoke("cancel_scan");
        set({
          scanning: false,
          data: null,
          totalScanned: 0,
          currentPath: "",
          error: null,
        });
      } catch (err) {
        console.error("Failed to cancel scan:", err);
      }
    },
    reset: (): void => {
      set({
        scanning: false,
        data: null,
        totalScanned: 0,
        currentPath: "",
        error: null,
      });
    },
  };
}

export const scanStore = createScanStore();
