import { writable } from "svelte/store";
import { invoke } from "@tauri-apps/api/core";

export interface VolumeInfo {
  name: string;
  mountPoint: string;
  totalSpace: number;
  availableSpace: number;
  fileSystem: string;
  isRemovable: boolean;
}

interface VolumeState {
  volumes: VolumeInfo[];
  loading: boolean;
  error: string | null;
}

const initialState: VolumeState = {
  volumes: [],
  loading: false,
  error: null,
};

function createVolumeStore() {
  const { subscribe, set, update } = writable<VolumeState>(initialState);

  return {
    subscribe,
    async refresh() {
      update((state) => ({ ...state, loading: true, error: null }));
      try {
        const volumes = await invoke<VolumeInfo[]>("list_volumes");
        set({ volumes, loading: false, error: null });
      } catch (err) {
        set({ volumes: [], loading: false, error: err instanceof Error ? err.message : String(err) });
      }
    },
  };
}

export const volumeStore = createVolumeStore();
