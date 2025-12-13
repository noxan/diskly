import { writable } from "svelte/store";
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

type ScanProgressEvent = {
  path: string;
  node_data: DirNode;
  total_scanned: number;
};

type ScanCompleteEvent = {
  root: DirNode;
  total_scanned: number;
};

type ScanErrorEvent = {
  message: string;
};

const initial: ScanState = {
  scanning: false,
  data: null,
  totalScanned: 0,
  currentPath: "",
  error: null,
};

function createScanStore() {
  const { subscribe, set, update } = writable<ScanState>(initial);
  let listeners: UnlistenFn[] = [];

  const cleanup = () => Promise.all(listeners.splice(0).map((fn) => fn()));

  const updateIfScanning = (updater: (state: ScanState) => ScanState) =>
    update((s) => (s.scanning ? updater(s) : s));

  const shouldUseNewNode = (existing: DirNode | null, incoming: DirNode): boolean => {
    if (!existing) return true;
    if ((incoming.updatedAt ?? 0) > (existing.updatedAt ?? 0)) return true;
    if ((incoming.seq ?? 0) > (existing.seq ?? 0)) return true;
    return false;
  };

  const handleProgress = (event: { payload: ScanProgressEvent }) =>
    updateIfScanning((s) => ({
      ...s,
      currentPath: event.payload.path,
      totalScanned: event.payload.total_scanned,
      data: shouldUseNewNode(s.data, event.payload.node_data) ? event.payload.node_data : s.data,
    }));

  const handleComplete = (event: { payload: ScanCompleteEvent }) =>
    updateIfScanning((s) => ({
      ...s,
      scanning: false,
      data: event.payload.root,
      totalScanned: event.payload.total_scanned,
      currentPath: "",
    }));

  const handleError = (event: { payload: ScanErrorEvent }) =>
    updateIfScanning((s) => ({
      ...s,
      scanning: false,
      error: event.payload.message,
      currentPath: "",
    }));

  const setupListeners = async () => {
    await cleanup();
    listeners = [
      await listen("scan:directory_complete", handleProgress),
      await listen("scan:complete", handleComplete),
      await listen("scan:error", handleError),
    ];
  };

  return {
    subscribe,
    async startScan(path: string) {
      set({ ...initial, scanning: true, currentPath: path });
      await setupListeners();
      try {
        await invoke("scan_directory", { path });
      } catch (err) {
        update((s) => ({ ...s, scanning: false, error: String(err) }));
      }
    },
    async cancelScan() {
      try {
        await invoke("cancel_scan");
      } catch (err) {
        console.error("Failed to cancel scan:", err);
      }
      set(initial);
    },
    reset: () => set(initial),
  };
}

export const scanStore = createScanStore();
