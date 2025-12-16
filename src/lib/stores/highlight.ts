import { writable } from 'svelte/store';

// Shared store for synchronized highlighting across tree view and treemap
export const highlightedPath = writable<string | null>(null);
