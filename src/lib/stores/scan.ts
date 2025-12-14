import { writable } from 'svelte/store';
import { listen, type UnlistenFn } from '@tauri-apps/api/event';
import { invoke } from '@tauri-apps/api/core';

export interface DirNode {
  name: string;
  path: string;
  size: number;
  children: DirNode[];
  is_file: boolean;
  updatedAt?: number;
  seq?: number;
}

export interface ScanHistoryEntry {
  path: string;
  root: DirNode;
  scannedAt: number;
}

interface ScanState {
  scanning: boolean;
  data: DirNode | null;
  totalScanned: number;
  currentPath: string;
  error: string | null;
  // Keep history alongside the active scan state so updates stay atomic when scans finish or reset.
  history: ScanHistoryEntry[];
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
  currentPath: '',
  error: null,
  history: []
};

function createScanStore() {
  const { subscribe, update } = writable<ScanState>(initial);
  let listeners: UnlistenFn[] = [];

  const cleanup = () => Promise.all(listeners.splice(0).map((fn) => fn()));

  const updateIfScanning = (updater: (state: ScanState) => ScanState) =>
    update((s) => (s.scanning ? updater(s) : s));

  const addOrUpdateHistory = (
    history: ScanHistoryEntry[],
    entry: ScanHistoryEntry
  ): ScanHistoryEntry[] => {
    const filtered = history.filter((item) => item.path !== entry.path);
    return [entry, ...filtered];
  };

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
      data: shouldUseNewNode(s.data, event.payload.node_data) ? event.payload.node_data : s.data
    }));

  const handleComplete = (event: { payload: ScanCompleteEvent }) =>
    updateIfScanning((s) => ({
      ...s,
      scanning: false,
      data: event.payload.root,
      totalScanned: event.payload.total_scanned,
      currentPath: '',
      history: addOrUpdateHistory(s.history, {
        path: event.payload.root.path,
        root: event.payload.root,
        scannedAt: Date.now()
      })
    }));

  const handleError = (event: { payload: ScanErrorEvent }) =>
    updateIfScanning((s) => ({
      ...s,
      scanning: false,
      error: event.payload.message,
      currentPath: ''
    }));

  const setupListeners = async () => {
    await cleanup();
    listeners = [
      await listen('scan:directory_complete', handleProgress),
      await listen('scan:complete', handleComplete),
      await listen('scan:error', handleError)
    ];
  };

  const removeNode = (root: DirNode | null, pathToRemove: string): DirNode | null => {
    if (!root) return null;
    if (root.path === pathToRemove) return null;

    if (!root.is_file && root.children) {
      const updatedChildren = root.children
        .map((child) => removeNode(child, pathToRemove))
        .filter((child): child is DirNode => child !== null);

      const removedSize = root.children.length - updatedChildren.length;
      if (removedSize > 0) {
        const newSize = updatedChildren.reduce((sum, child) => sum + child.size, 0);
        return { ...root, children: updatedChildren, size: newSize };
      }
      return { ...root, children: updatedChildren };
    }

    return root;
  };

  const startScan = async (path: string) => {
    update((s) => ({ ...initial, history: s.history, scanning: true, currentPath: path }));
    await setupListeners();
    try {
      await invoke('scan_directory', { path });
    } catch (err) {
      update((s) => ({ ...s, scanning: false, error: String(err) }));
    }
  };

  const cancelScan = async () => {
    try {
      await invoke('cancel_scan');
    } catch (err) {
      console.error('Failed to cancel scan:', err);
    }
    update((s) => ({ ...initial, history: s.history }));
  };

  return {
    subscribe,
    startScan,
    cancelScan,
    removeNode(path: string) {
      update((s) => ({ ...s, data: removeNode(s.data, path) }));
    },
    reset: () => update((s) => ({ ...initial, history: s.history })),
    openHistory(path: string) {
      update((s) => {
        if (s.scanning) return s;
        const match = s.history.find((entry) => entry.path === path);
        if (!match) return s;

        return {
          ...s,
          data: match.root,
          error: null,
          currentPath: '',
          totalScanned: match.root.size ?? s.totalScanned
        };
      });
    },
    async rescan(path: string) {
      await startScan(path);
    }
  };
}

export const scanStore = createScanStore();
