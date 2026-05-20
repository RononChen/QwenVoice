// Sidebar.jsx — 200 px Vocello sidebar.
// Mirrors SidebarView.swift: brand header pinned via safeAreaInset(.top),
// grouped sections, mode-colored selection rail, footer with engine status.

(function () {
  const { PersonWave2, Bubble, WaveformPlus, Clock, Person2, Gear, PlayFill, Pause } = window.VocIcons;

  const NAV = [
    {
      section: "Generate",
      items: [
        { id: "custom",  label: "Custom Voice",  icon: PersonWave2,  tint: "#EDCC8A" },
        { id: "design",  label: "Voice Design",  icon: Bubble,        tint: "#BFAADB" },
        { id: "clone",   label: "Voice Cloning", icon: WaveformPlus,  tint: "#DBA887" },
      ],
    },
    {
      section: "Library",
      items: [
        { id: "history", label: "History",       icon: Clock,         tint: "#EDCC8A" },
        { id: "voices",  label: "Saved Voices",  icon: Person2,       tint: "#EDCC8A" },
      ],
    },
    {
      section: "Settings",
      items: [
        { id: "settings", label: "Settings",     icon: Gear,          tint: "#EDCC8A" },
      ],
    },
  ];

  function SidebarRow({ item, isSelected, isHovered, onHover, onSelect }) {
    const tintStroke = isSelected
      ? `${item.tint}55`
      : isHovered
        ? "rgba(255,255,255,0.08)"
        : "transparent";
    const tintFill =
      isSelected ? "rgba(255,255,255,0.05)" :
      isHovered  ? "rgba(255,255,255,0.03)" :
      "transparent";

    return (
      <button
        onClick={onSelect}
        onMouseEnter={() => onHover(true)}
        onMouseLeave={() => onHover(false)}
        style={{
          appearance: "none",
          width: "100%",
          height: 34,
          display: "flex",
          alignItems: "center",
          gap: 8,
          padding: "0 7px",
          background: tintFill,
          border: `1px solid ${tintStroke}`,
          borderRadius: 8,
          cursor: "default",
          textAlign: "left",
          color: "var(--fg-primary)",
          transition: "background 0.14s var(--ease-standard), border-color 0.14s var(--ease-standard)",
        }}
      >
        <span
          style={{
            width: 3, height: 16, borderRadius: 999,
            background: isSelected ? item.tint : "transparent",
            flex: "none",
          }}
        />
        <span style={{ width: 22, display: "grid", placeItems: "center", color: isSelected ? item.tint : "var(--fg-primary)", flex: "none" }}>
          <item.icon size={17} strokeWidth={isSelected ? 1.85 : 1.6} />
        </span>
        <span style={{ fontSize: 14, fontWeight: isSelected ? 600 : 400, flex: 1, lineHeight: 1.2 }}>{item.label}</span>
      </button>
    );
  }

  function Sidebar({ selected, onSelect, player }) {
    const [hoverId, setHoverId] = React.useState(null);

    return (
      <aside
        style={{
          width: "var(--sidebar-width)",
          flex: "none",
          background: "var(--bg-rail)",
          borderRight: "0.75px solid var(--stroke-rail)",
          display: "flex",
          flexDirection: "column",
          minHeight: 0,
        }}
      >
        {/* Brand header */}
        <div style={{ padding: "14px 14px 14px", display: "flex", alignItems: "baseline", gap: 8 }}>
          <img
            src="../../assets/vocello-header-mark@3x.png"
            alt=""
            style={{ height: 22, alignSelf: "center" }}
          />
          <span style={{
            fontFamily: "var(--font-display)",
            fontWeight: 600, fontSize: 18,
            color: "var(--fg-primary)",
            letterSpacing: "-0.005em",
          }}>Vocello</span>
          <span style={{ fontSize: 11, fontWeight: 500, color: "var(--fg-secondary)" }}>AI·TTS</span>
        </div>

        {/* Nav */}
        <div style={{ flex: 1, minHeight: 0, overflow: "auto", padding: "0 8px 8px" }}>
          {NAV.map((section) => (
            <div key={section.section} style={{ marginBottom: 10 }}>
              <div style={{
                padding: "8px 10px 6px",
                fontSize: 11, fontWeight: 600,
                color: "var(--fg-secondary)",
              }}>{section.section}</div>
              <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
                {section.items.map((item) => (
                  <SidebarRow
                    key={item.id}
                    item={item}
                    isSelected={selected === item.id}
                    isHovered={hoverId === item.id}
                    onHover={(h) => setHoverId(h ? item.id : null)}
                    onSelect={() => onSelect(item.id)}
                  />
                ))}
              </div>
            </div>
          ))}
        </div>

        {/* Footer — player + engine status */}
        <div style={{ borderTop: "1px solid var(--stroke-rail)" }}>
          {player && (
            <div style={{ padding: "10px 12px", borderBottom: "1px solid var(--stroke-rail)" }}>
              <SidebarPlayer track={player.track} />
            </div>
          )}
          <div style={{ padding: "10px 14px" }}>
            <div style={{ fontSize: 10, fontWeight: 600, color: "var(--fg-secondary)", letterSpacing: "0.04em", marginBottom: 4 }}>Engine</div>
            <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
              <span style={{
                width: 7, height: 7, borderRadius: 50,
                background: "#5DD49B",
                boxShadow: "0 0 0 3px rgba(93,212,155,0.16)",
              }} />
              <span style={{ fontSize: 13, color: "var(--fg-primary)", fontWeight: 500 }}>Ready</span>
            </div>
          </div>
        </div>
      </aside>
    );
  }

  function SidebarPlayer({ track }) {
    const [playing, setPlaying] = React.useState(true);
    return (
      <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <button
            onClick={() => setPlaying((p) => !p)}
            style={{
              width: 28, height: 28, borderRadius: 50, display: "grid", placeItems: "center",
              background: "linear-gradient(180deg, #F0D69B, #DDB164)",
              border: "0.5px solid rgba(255,255,255,0.35)",
              color: "#1B1306",
              cursor: "pointer",
            }}
          >
            {playing ? <Pause size={11} /> : <PlayFill size={11} />}
          </button>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 12, fontWeight: 600, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{track.title}</div>
            <div style={{ fontSize: 10, color: "var(--fg-secondary)" }}>{track.subtitle}</div>
          </div>
        </div>
        <div style={{ height: 3, background: "rgba(255,255,255,0.08)", borderRadius: 999, position: "relative", overflow: "hidden" }}>
          <div style={{ position: "absolute", inset: 0, width: "42%", background: "linear-gradient(90deg, rgba(237,204,138,0.5), #EDCC8A)", borderRadius: 999 }} />
        </div>
      </div>
    );
  }

  Object.assign(window, { Sidebar });
})();
