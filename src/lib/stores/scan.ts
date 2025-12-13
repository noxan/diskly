import { writable } from "svelte/store";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";

export interface FileNode {
  path: string;
  name: string;
  size: number;
  is_dir: boolean;
  child_count: number;
  children?: FileNode[];
}

interface ScanState {
  scanning: boolean;
  rootPath: string | null;
  totalScanned: number;
  totalSize: number;
  currentPath: string;
  error: string | null;
}

type ScanProgressEvent = {
  current_path: string;
  total_scanned: number;
};

type ScanCompleteEvent = {
  root_path: string;
  total_scanned: number;
  total_size: number;
};

const initial: ScanState = {
  scanning: false,
  rootPath: null,
  totalScanned: 0,
  totalSize: 0,
  currentPath: "",
  error: null,
};

function createScanStore() {
  const { subscribe, set, update } = writable<ScanState>(initial);
  let listeners: UnlistenFn[] = [];

  const cleanup = () => Promise.all(listeners.splice(0).map((fn) => fn()));

  const updateIfScanning = (updater: (state: ScanState) => ScanState) =>
    update((s) => (s.scanning ? updater(s) : s));

  const handleProgress = (event: { payload: ScanProgressEvent }) =>
    updateIfScanning((s) => ({
      ...s,
      currentPath: event.payload.current_path,
      totalScanned: event.payload.total_scanned,
    }));

  const handleComplete = (event: { payload: ScanCompleteEvent }) =>
    updateIfScanning((s) => ({
      ...s,
      scanning: false,
      rootPath: event.payload.root_path,
      totalScanned: event.payload.total_scanned,
      totalSize: event.payload.total_size,
      currentPath: "",
    }));

  const setupListeners = async () => {
    await cleanup();
    listeners = [
      await listen("scan:progress", handleProgress),
      await listen("scan:complete", handleComplete),
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

export async function getChildren(path: string): Promise<FileNode[]> {
  return await invoke<FileNode[]>("get_children", { path });
}
