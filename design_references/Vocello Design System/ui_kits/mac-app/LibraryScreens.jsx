// Library + Settings screens — flatter than the generation pages.
// Gold accent only; no mode tint.

(function () {
  const { GlassCard, SectionHead, Detail, Row, Stack, Label, Helper } = window;
  const { Clock, Person2, Gear, CheckCircle, WaveformPlus, PersonWave2, Bubble, PlayFill } = window.VocIcons;

  // ---------- History ----------

  function HistoryScreen({ items }) {
    return (
      <ScreenScaffold title="History" tint="gold">
        <GlassCard tint="gold" padding={0}>
          <div style={{
            display: "flex", alignItems: "center", gap: 8,
            padding: "12px 16px",
            borderBottom: "1px solid var(--stroke-card)",
          }}>
            <Clock size={16} style={{ color: "#EDCC8A" }} />
            <span style={{ fontSize: 17, fontWeight: 600 }}>Generation history</span>
            <span style={{ flex: 1 }} />
            <span style={{ fontSize: 12, color: "var(--fg-secondary)" }}>{items.length} entries</span>
          </div>
          <div>
            {items.map((it, i) => <HistoryRow key={i} item={it} index={i} />)}
          </div>
        </GlassCard>
      </ScreenScaffold>
    );
  }

  function modeMeta(mode) {
    if (mode === "design") return { label: "Voice Design",  color: "#BFAADB", Icon: Bubble };
    if (mode === "clone")  return { label: "Voice Cloning", color: "#DBA887", Icon: WaveformPlus };
    return                        { label: "Custom Voice",  color: "#EDCC8A", Icon: PersonWave2 };
  }

  function HistoryRow({ item, index }) {
    const m = modeMeta(item.mode);
    return (
      <div style={{
        display: "grid",
        gridTemplateColumns: "28px 130px 1fr 70px 70px 28px",
        alignItems: "center", gap: 12,
        padding: "10px 16px",
        borderTop: index === 0 ? 0 : "1px solid rgba(255,255,255,0.04)",
      }}>
        <button style={{
          width: 26, height: 26, borderRadius: 50, border: 0,
          background: "rgba(237,204,138,0.18)",
          color: "#EDCC8A",
          display: "grid", placeItems: "center",
          cursor: "pointer",
        }}>
          <PlayFill size={11} />
        </button>
        <span style={{
          display: "inline-flex", alignItems: "center", gap: 5,
          padding: "3px 8px",
          background: `${m.color}1F`,
          color: m.color,
          border: `1px solid ${m.color}3D`,
          borderRadius: 999,
          fontSize: 11, fontWeight: 600,
          width: "fit-content",
        }}>
          <m.Icon size={11} /> {m.label}
        </span>
        <div style={{ minWidth: 0 }}>
          <div style={{
            fontSize: 13, fontWeight: 500, color: "var(--fg-primary)",
            whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis",
          }}>{item.text}</div>
          <div style={{ fontSize: 11, color: "var(--fg-secondary)" }}>{item.voice} · {item.delivery}</div>
        </div>
        <span style={{ fontSize: 11, color: "var(--fg-secondary)", fontFamily: "var(--font-mono)" }}>{item.duration}</span>
        <span style={{ fontSize: 11, color: "var(--fg-secondary)" }}>{item.when}</span>
        <button style={{
          width: 22, height: 22, borderRadius: 6, border: 0, background: "transparent",
          color: "var(--fg-secondary)", cursor: "pointer", fontSize: 14, lineHeight: 1,
        }}>···</button>
      </div>
    );
  }

  // ---------- Saved Voices ----------

  function SavedVoicesScreen({ voices }) {
    return (
      <ScreenScaffold title="Saved Voices" tint="gold">
        <GlassCard tint="gold">
          <SectionHead
            icon={<Person2 size={16} />}
            title="Saved voices"
            tint="gold"
            trailingControl={
              <button style={{
                padding: "5px 10px", borderRadius: 8,
                background: "rgba(255,255,255,0.06)",
                border: "1px solid rgba(255,255,255,0.10)",
                color: "var(--fg-primary)", fontFamily: "var(--font-text)",
                fontSize: 12, fontWeight: 500, cursor: "pointer",
              }}>+ Add voice</button>
            }
          />
          <Detail>Voices you've saved from Voice Design or imported from a reference clip.</Detail>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
            {voices.map((v, i) => <VoiceCard key={i} voice={v} />)}
          </div>
        </GlassCard>
      </ScreenScaffold>
    );
  }

  function VoiceCard({ voice }) {
    return (
      <div style={{
        padding: 12,
        background: "var(--bg-inline)",
        border: "1px solid var(--stroke-inline)",
        borderRadius: 12,
        display: "flex", alignItems: "center", gap: 12,
      }}>
        <div style={{
          width: 36, height: 36, borderRadius: 50,
          background: "linear-gradient(135deg, #BFAADB, #DBA887)",
          display: "grid", placeItems: "center",
          color: "#1B1306",
          fontFamily: "var(--font-display)", fontWeight: 700, fontSize: 14,
        }}>{voice.initials}</div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: 13, fontWeight: 600, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{voice.name}</div>
          <div style={{ fontSize: 11, color: "var(--fg-secondary)" }}>{voice.kind} · {voice.duration}</div>
        </div>
        <button style={{
          width: 28, height: 28, borderRadius: 50, border: 0,
          background: "rgba(237,204,138,0.18)", color: "#EDCC8A",
          display: "grid", placeItems: "center", cursor: "pointer",
        }}>
          <PlayFill size={11} />
        </button>
      </div>
    );
  }

  // ---------- Settings (Model Downloads) ----------

  function SettingsScreen() {
    return (
      <ScreenScaffold title="Settings" tint="gold">
        <h2 style={{ margin: "4px 0 6px", fontSize: 18, fontWeight: 600 }}>Model downloads</h2>
        <div style={{
          display: "flex", alignItems: "center", gap: 10,
          padding: "12px 16px", marginBottom: 6,
          background: "var(--bg-card)",
          border: "1px solid var(--stroke-card)",
          borderRadius: 14,
        }}>
          <span style={{ color: "#9C9EA6" }}><CheckCircle size={18} strokeWidth={0} /></span>
          <span style={{ fontSize: 14, fontWeight: 600 }}>Recommended models ready</span>
        </div>

        <ModelGroup
          name="Custom Voice"
          subtitle="Built-in speakers"
          dotColor="#EDCC8A"
          variants={[
            { name: "Speed (4-bit)",   tag: "Recommended", tagColor: "#EDCC8A", status: "Ready" },
            { name: "Quality (8-bit)", tag: "Heavy",        tagColor: "#F0A55D", status: "Ready" },
          ]}
        />
        <ModelGroup
          name="Voice Design"
          subtitle="Describe a new voice"
          dotColor="#BFAADB"
          variants={[
            { name: "Speed (4-bit)",   tag: "Recommended", tagColor: "#EDCC8A", status: "Ready" },
            { name: "Quality (8-bit)", tag: "Heavy",        tagColor: "#F0A55D", status: "Ready" },
          ]}
        />
        <ModelGroup
          name="Voice Cloning"
          subtitle="Use a reference clip"
          dotColor="#DBA887"
          variants={[
            { name: "Speed (4-bit)",   tag: "Recommended", tagColor: "#EDCC8A", status: "Ready" },
            { name: "Quality (8-bit)", tag: "Heavy",        tagColor: "#F0A55D", status: "Not installed" },
          ]}
        />
      </ScreenScaffold>
    );
  }

  function ModelGroup({ name, subtitle, dotColor, variants }) {
    return (
      <div style={{
        background: "var(--bg-card)",
        border: "1px solid var(--stroke-card)",
        borderRadius: 14,
        padding: "12px 16px",
        marginTop: 8,
      }}>
        <div style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
          <span style={{ width: 8, height: 8, borderRadius: 50, background: dotColor, transform: "translateY(-1px)" }} />
          <span style={{ fontSize: 14, fontWeight: 600 }}>{name}</span>
          <span style={{ fontSize: 12, color: "var(--fg-secondary)" }}>{subtitle}</span>
        </div>
        <div style={{ marginTop: 6 }}>
          {variants.map((v, i) => (
            <div key={i} style={{
              display: "grid",
              gridTemplateColumns: "200px 1fr 80px 80px",
              alignItems: "center", gap: 12,
              padding: "8px 0",
              borderTop: i === 0 ? 0 : "1px solid rgba(255,255,255,0.06)",
            }}>
              <span style={{ fontSize: 13, fontWeight: 500 }}>{v.name}</span>
              <span style={{ fontSize: 11, fontWeight: 600, color: v.tagColor }}>{v.tag}</span>
              <span style={{ fontSize: 12, fontWeight: 500, color: v.status === "Ready" ? "#5DD49B" : "var(--fg-tertiary)", display: "inline-flex", alignItems: "center", gap: 6 }}>
                {v.status === "Ready" && <span style={{ width: 14, height: 14, borderRadius: 50, background: "#9C9EA6", color: "#0F1014", display: "grid", placeItems: "center", fontSize: 9 }}>✓</span>}
                {v.status}
              </span>
              <button style={{
                padding: "5px 12px",
                borderRadius: 8,
                background: "rgba(255,255,255,0.06)",
                border: "1px solid rgba(255,255,255,0.10)",
                color: "var(--fg-primary)",
                fontFamily: "var(--font-text)", fontSize: 12, fontWeight: 500,
                cursor: "pointer",
              }}>{v.status === "Ready" ? "Manage" : "Install"}</button>
            </div>
          ))}
        </div>
      </div>
    );
  }

  // ---------- Scaffold ----------

  function ScreenScaffold({ title, tint, children }) {
    const radialColor =
      tint === "lavender" ? "rgba(191,170,219,0.10)" :
      tint === "terra"    ? "rgba(219,168,135,0.10)" :
      "rgba(237,204,138,0.06)";

    return (
      <div
        style={{
          flex: 1, minWidth: 0,
          background: `radial-gradient(60% 40% at 50% -5%, ${radialColor}, transparent 70%), linear-gradient(180deg, #0F1014, #1A1C22)`,
          padding: "14px 22px 18px",
          overflow: "auto",
        }}
      >
        <h1 style={{ margin: 0, padding: "6px 4px 8px", fontSize: 22, fontWeight: 600, color: "var(--fg-primary)" }}>{title}</h1>
        <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
          {children}
        </div>
      </div>
    );
  }

  Object.assign(window, { HistoryScreen, SavedVoicesScreen, SettingsScreen });
})();
