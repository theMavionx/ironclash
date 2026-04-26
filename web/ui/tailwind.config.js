/** @type {import('tailwindcss').Config} */
//
// Visual tokens mirror design/gdd/art-bible-ui.md. When adding a new token,
// update the doc first and keep the Tailwind name identical to the doc name
// (kebab-case → camelCase only when JS forces it).

export default {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        bg: "#0e0f10",
        surface: "#161819",
        "surface-2": "#1f2225",
        border: "#2a2d30",
        "border-strong": "#3d4146",
        text: "#e8e6e1",
        "text-muted": "#7a7e83",
        accent: "#ffaa33",
        "accent-dim": "#a36e1f",
        danger: "#e23636",
        ok: "#5cd4a8",
        // Aliases — same hex, different semantic. Re-mapping later (e.g. team
        // recolor) only touches this file.
        enemy: "#e23636",
        friendly: "#5cd4a8",
        // Translucent backing for HUD text floating over the game canvas.
        "hud-bg": "rgba(0, 0, 0, 0.55)",
      },
      fontFamily: {
        sans: [
          "Inter",
          "ui-sans-serif",
          "system-ui",
          "-apple-system",
          "sans-serif",
        ],
        mono: [
          '"JetBrains Mono"',
          "ui-monospace",
          "SFMono-Regular",
          "monospace",
        ],
      },
      fontSize: {
        // Custom type scale from the art bible. [size, { lineHeight, letterSpacing, fontWeight }].
        caption: ["10px", { lineHeight: "1", letterSpacing: "0.1em", fontWeight: "500" }],
        label: ["12px", { lineHeight: "1", letterSpacing: "0.08em", fontWeight: "500" }],
        body: ["14px", { lineHeight: "1.4", fontWeight: "400" }],
        "body-strong": ["14px", { lineHeight: "1.4", fontWeight: "600" }],
        value: ["16px", { lineHeight: "1", fontWeight: "500" }],
        metric: ["28px", { lineHeight: "1", fontWeight: "500" }],
        headline: ["40px", { lineHeight: "1.1", letterSpacing: "-0.01em", fontWeight: "600" }],
        display: ["64px", { lineHeight: "1", letterSpacing: "-0.02em", fontWeight: "700" }],
      },
      letterSpacing: {
        label: "0.08em",
      },
      borderRadius: {
        // Force radius=0 everywhere by overriding (not extending) the defaults
        // would also work, but we keep `extend` so DEFAULT (rounded class) is
        // explicitly 0 to make accidental rounding easy to grep for.
        none: "0",
        DEFAULT: "0",
      },
      transitionDuration: {
        120: "120ms",
        200: "200ms",
        400: "400ms",
      },
    },
  },
  plugins: [],
};
