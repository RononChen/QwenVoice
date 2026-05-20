// Card.jsx — the glass-tinted panel and section-header primitive.
// Re-creates StudioSectionCard / NativeSurfaceStyle from AppTheme.swift.

(function () {
  const { Sliders, TextLines } = window.VocIcons;

  // Top-edge highlight gradient + 3D depth, in pure CSS.
  function GlassCard({ tint, children, padding = 16, className = "", style = {}, fillHeight = false }) {
    const tintMap = {
      gold:     { stroke: "rgba(237,204,138,0.22)", wash: "rgba(237,204,138,0.05)" },
      lavender: { stroke: "rgba(191,170,219,0.22)", wash: "rgba(191,170,219,0.05)" },
      terra:    { stroke: "rgba(219,168,135,0.22)", wash: "rgba(219,168,135,0.05)" },
      none:     { stroke: "rgba(255,255,255,0.16)", wash: "transparent" },
    };
    const t = tintMap[tint] || tintMap.none;
    return (
      <div
        className={`vc-card ${className}`}
        style={{
          position: "relative",
          background: `linear-gradient(180deg, ${t.wash}, transparent 50%), var(--bg-card)`,
          border: "0.75px solid rgba(255,255,255,0.16)",
          boxShadow: `0 2px 12px rgba(0,0,0,0.32), inset 0 0 0 1px ${t.stroke}, inset 0 1px 0 rgba(255,255,255,0.08)`,
          borderRadius: "var(--radius-card)",
          padding,
          ...(fillHeight ? { flex: 1, minHeight: 0, display: "flex", flexDirection: "column" } : {}),
          ...style,
        }}
      >
        {/* Top-edge specular highlight */}
        <div
          aria-hidden
          style={{
            position: "absolute",
            inset: 0,
            borderRadius: "inherit",
            pointerEvents: "none",
            background: "linear-gradient(180deg, rgba(255,255,255,0.05), rgba(255,255,255,0) 35%)",
          }}
        />
        <div style={{ position: "relative", zIndex: 1, ...(fillHeight ? { display: "flex", flexDirection: "column", flex: 1, minHeight: 0 } : {}) }}>
          {children}
        </div>
      </div>
    );
  }

  // Section header used by both Configuration and Script panels.
  function SectionHead({ icon, title, tint = "gold", trailingText, trailingControl }) {
    const tintColor =
      tint === "gold" ? "#EDCC8A" :
      tint === "lavender" ? "#BFAADB" :
      tint === "terra" ? "#DBA887" :
      "var(--fg-primary)";
    const trailColor =
      trailingText === "Ready" ? "#5DD49B" :
      trailingText === "Preparing" || trailingText === "Generating" ? "#EDCC8A" :
      "var(--fg-secondary)";
    return (
      <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 6 }}>
        <span style={{ color: tintColor, display: "inline-flex" }}>{icon}</span>
        <span style={{ fontSize: 17, fontWeight: 600, color: "var(--fg-primary)", letterSpacing: "-0.005em" }}>{title}</span>
        <div style={{ flex: 1 }} />
        {trailingText && (
          <span style={{ fontSize: 12, fontWeight: 500, color: trailColor }}>{trailingText}</span>
        )}
        {trailingControl}
      </div>
    );
  }

  function Detail({ children }) {
    return (
      <p style={{ margin: "0 0 10px", fontSize: 12, color: "var(--fg-secondary)", lineHeight: 1.5 }}>
        {children}
      </p>
    );
  }

  function Row({ children, gap = 12, align = "center", style = {} }) {
    return (
      <div style={{ display: "flex", alignItems: align, gap, ...style }}>{children}</div>
    );
  }

  function Stack({ children, gap = 8, style = {} }) {
    return (
      <div style={{ display: "flex", flexDirection: "column", gap, ...style }}>{children}</div>
    );
  }

  function Label({ children }) {
    return (
      <div style={{ fontSize: 13, fontWeight: 600, color: "var(--fg-primary)" }}>{children}</div>
    );
  }

  function Helper({ children }) {
    return (
      <div style={{ fontSize: 11, color: "var(--fg-secondary)", lineHeight: 1.5 }}>{children}</div>
    );
  }

  Object.assign(window, { GlassCard, SectionHead, Detail, Row, Stack, Label, Helper });
})();
