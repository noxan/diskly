import { writable } from 'svelte/store';

function createThemeStore() {
  const { subscribe, set, update } = writable('light', (set) => {
    // Initialize from localStorage or system preference
    if (typeof window !== 'undefined') {
      const stored = localStorage.getItem('theme');
      const prefersDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
      const initial = stored || (prefersDark ? 'dark' : 'light');
      set(initial);
      applyTheme(initial);
    }
  });

  return {
    subscribe,
    toggle: () => update((theme) => {
      const newTheme = theme === 'dark' ? 'light' : 'dark';
      applyTheme(newTheme);
      if (typeof window !== 'undefined') {
        localStorage.setItem('theme', newTheme);
      }
      return newTheme;
    }),
    set: (theme) => {
      applyTheme(theme);
      if (typeof window !== 'undefined') {
        localStorage.setItem('theme', theme);
      }
      set(theme);
    }
  };
}

function applyTheme(theme) {
  if (typeof document !== 'undefined') {
    document.documentElement.classList.toggle('dark', theme === 'dark');
  }
}

export const themeStore = createThemeStore();
