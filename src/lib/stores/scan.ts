import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { derived, writable } from "svelte/store";

export type FsNode = {
  name: string;
  path: string;
  size: number;
  children: FsNode[];
};

type FlatNode = {
  name: string;
  path: string;
  size: number;
  children: string[];
};

type ScanState = {
  homePath: string | null;
  rootPath: string | null;
  selectedPath: string | null;
  nodes: Map<string, FlatNode>;
  totalScanned: number;
  scanning: boolean;
  error: string | null;
  expanded: Set<string>;
};

const initialState: ScanState = {
  homePath: null,
  rootPath: null,
  selectedPath: null,
  nodes: new Map(),
  totalScanned: 0,
  scanning: false,
  error: null,
  expanded: new Set(),
};

export const scanStore = writable<ScanState>(initialState);

let listeners: UnlistenFn[] | null = null;

function normalizeShallow(node: FsNode) {
  return {
    name: node.name,
    path: node.path,
    size: node.size,
    children: (node.children ?? []).map((c) => c.path),
  } satisfies FlatNode;
}

function ingestShallow(state: ScanState, node: FsNode) {
  state.nodes.set(node.path, normalizeShallow(node));
  for (const child of node.children ?? []) {
    state.nodes.set(child.path, normalizeShallow(child));
  }
}

function ingestDeep(state: ScanState, node: FsNode) {
  state.nodes.set(node.path, normalizeShallow(node));
  for (const child of node.children ?? []) {
    ingestDeep(state, child);
  }
}

export async function initScanEvents() {
  if (listeners) return;

  const unlistenDir = await listen<{
    path: string;
    nodeData: FsNode;
    totalScanned: number;
  }>("scan:directory_complete", (event) => {
    const { nodeData, totalScanned } = event.payload;
    scanStore.update((state) => {
      state.error = null;
      state.scanning = true;
      state.totalScanned = totalScanned ?? state.totalScanned;
      ingestShallow(state, nodeData);
      if (!state.selectedPath) state.selectedPath = state.rootPath ?? nodeData.path;
      return { ...state };
    });
  });

  const unlistenComplete = await listen<{
    root: FsNode;
    totalScanned: number;
  }>("scan:complete", (event) => {
    const { root, totalScanned } = event.payload;
    scanStore.update((state) => {
      state.totalScanned = totalScanned ?? state.totalScanned;
      // Ensure cached scans populate the full tree.
      ingestDeep(state, root);
      state.scanning = false;
      state.error = null;
      if (!state.selectedPath) state.selectedPath = state.rootPath ?? root.path;
      return { ...state };
    });
  });

  const unlistenErr = await listen<{ message: string }>("scan:error", (event) => {
    scanStore.update((state) => {
      state.error = event.payload?.message ?? "Unknown error";
      state.scanning = false;
      return { ...state };
    });
  });

  listeners = [unlistenDir, unlistenComplete, unlistenErr];
}

export async function loadHomeDir() {
  const homePath = await invoke<string>("get_home_dir");
  scanStore.update((s) => ({ ...s, homePath }));
  return homePath;
}

export async function pickDirectory() {
  return await invoke<string | null>("pick_directory");
}

export async function scanDirectory(path: string) {
  scanStore.update((state) => {
    const expanded = new Set<string>();
    expanded.add(path);
    return {
      ...state,
      rootPath: path,
      selectedPath: path,
      nodes: new Map(),
      totalScanned: 0,
      scanning: true,
      error: null,
      expanded,
    };
  });
  await invoke("scan_directory", { path });
}

export async function cancelScan() {
  await invoke("cancel_scan");
}

export function toggleExpanded(path: string) {
  scanStore.update((state) => {
    if (state.expanded.has(path)) state.expanded.delete(path);
    else state.expanded.add(path);
    return { ...state };
  });
}

export function selectPath(path: string) {
  scanStore.update((state) => ({ ...state, selectedPath: path }));
}

function splitPath(p: string) {
  const parts = p.split(/[/\\]+/).filter(Boolean);
  if (p.startsWith("/") && parts.length > 0) parts[0] = `/${parts[0]}`;
  return parts;
}

export const breadcrumb = derived(scanStore, ($s) => {
  const p = $s.selectedPath ?? $s.rootPath;
  if (!p) return [];
  return splitPath(p);
});

export const rootNode = derived(scanStore, ($s) => {
  if (!$s.rootPath) return null;
  return $s.nodes.get($s.rootPath) ?? null;
});

