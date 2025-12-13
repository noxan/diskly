import { writable, type Writable } from "svelte/store";

type Theme = "light" | "dark";

interface ThemeStore {
  subscribe: Writable<Theme>["subscribe"];
  toggle: () => void;
  set: (theme: Theme) => void;
}

function createThemeStore(): ThemeStore {
  const { subscribe, set, update } = writable<Theme>("light", (set) => {
    // Initialize from localStorage or system preference
    if (typeof window !== "undefined") {
      const stored = localStorage.getItem("theme") as Theme | null;
      const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
      const initial: Theme = stored || (prefersDark ? "dark" : "light");
      set(initial);
      applyTheme(initial);
    }
  });

  return {
    subscribe,
    toggle: () =>
      update((theme) => {
        const newTheme: Theme = theme === "dark" ? "light" : "dark";
        applyTheme(newTheme);
        if (typeof window !== "undefined") {
          localStorage.setItem("theme", newTheme);
        }
        return newTheme;
      }),
    set: (theme: Theme) => {
      applyTheme(theme);
      if (typeof window !== "undefined") {
        localStorage.setItem("theme", theme);
      }
      set(theme);
    },
  };
}

function applyTheme(theme: Theme): void {
  if (typeof document !== "undefined") {
    document.documentElement.classList.toggle("dark", theme === "dark");
  }
}

export const themeStore = createThemeStore();
