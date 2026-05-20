// Generation screens — Custom Voice, Voice Design, Voice Cloning.
// Each is composed from Card + shared sub-controls (delivery picker, model
// segment, generate button, script composer).

(function () {
  const { GlassCard, SectionHead, Detail, Row, Stack, Label, Helper } = window;
  const { Sliders, TextLines, PlayFill, Chevron, WaveformPlus, Triangle, Plus } = window.VocIcons;

  // ---------- Shared sub-controls ----------

  function Picker({ value, onChange, options, minWidth = 160, maxWidth = 240 }) {
    return (
      <div style={{ position: "relative", display: "inline-flex", minWidth, maxWidth }}>
        <select
          value={value}
          onChange={(e) => onChange(e.target.value)}
          style={{
            appearance: "none",
            WebkitAppearance: "none",
            background: "var(--bg-field)",
            border: "0.5px solid rgba(255,255,255,0.10)",
            borderRadius: 8,
            color: "var(--fg-primary)",
            fontSize: 13,
            fontFamily: "var(--font-text)",
            padding: "7px 28px 7px 10px",
            width: "100%",
            cursor: "pointer",
            outline: "none",
          }}
        >
          {options.map((o) => (
            <option key={o.value} value={o.value}>{o.label}</option>
          ))}
        </select>
        <span style={{
          position: "absolute", right: 8, top: "50%", transform: "translateY(-50%)",
          pointerEvents: "none", color: "var(--fg-secondary)",
        }}>
          <Chevron size={11} strokeWidth={1.6} />
        </span>
      </div>
    );
  }

  function TextField({ value, onChange, placeholder, focus, minHeight = 0, multiline = false }) {
    return (
      <div
        style={{
          background: "var(--bg-field)",
          border: `0.5px solid ${focus ? "rgba(237,204,138,0.40)" : "rgba(255,255,255,0.10)"}`,
          borderRadius: 10,
          padding: multiline ? 12 : "0 12px",
          height: multiline ? "auto" : 36,
          minHeight,
          display: "flex",
          alignItems: multiline ? "flex-start" : "center",
        }}
      >
        {multiline ? (
          <textarea
            value={value}
            onChange={(e) => onChange(e.target.value)}
            placeholder={placeholder}
            style={{
              flex: 1,
              minHeight,
              width: "100%",
              border: 0,
              outline: 0,
              resize: "none",
              background: "transparent",
              color: "var(--fg-primary)",
              fontFamily: "var(--font-text)",
              fontSize: 14,
              lineHeight: 1.5,
            }}
          />
        ) : (
          <input
            value={value}
            onChange={(e) => onChange(e.target.value)}
            placeholder={placeholder}
            style={{
              flex: 1, border: 0, outline: 0, background: "transparent",
              color: "var(--fg-primary)", fontFamily: "var(--font-text)", fontSize: 13,
            }}
          />
        )}
      </div>
    );
  }

  function SpeedQuality({ value, onChange }) {
    return (
      <div style={{ display: "inline-flex", alignItems: "center", gap: 10 }}>
        <span style={{ fontSize: 11, fontWeight: 600, color: "var(--fg-secondary)", letterSpacing: "0.04em" }}>Model</span>
        <div style={{
          display: "inline-flex", padding: 3,
          background: "var(--bg-inline)",
          border: "1px solid rgba(255,255,255,0.10)",
          borderRadius: 8,
        }}>
          {["Speed", "Quality"].map((v) => (
            <button
              key={v}
              onClick={() => onChange(v)}
              style={{
                background: value === v ? "rgba(237,204,138,0.22)" : "transparent",
                color: value === v ? "#EDCC8A" : "var(--fg-primary)",
                boxShadow: value === v ? "inset 0 0 0 1px rgba(237,204,138,0.32)" : "none",
                border: 0, borderRadius: 6,
                padding: "5px 14px", fontSize: 12, fontWeight: 600,
                fontFamily: "var(--font-text)", cursor: "pointer",
              }}
            >{v}</button>
          ))}
        </div>
      </div>
    );
  }

  function CharCount({ value }) {
    return (
      <span style={{ fontSize: 11, color: "var(--fg-secondary)" }}>{value.length} characters</span>
    );
  }

  function GenerateButton({ tint, onClick, disabled, label = "Generate" }) {
    const tintFill =
      tint === "lavender" ? "linear-gradient(180deg, #D3C0EB, #B294D6)" :
      tint === "terra"    ? "linear-gradient(180deg, #ECC7AC, #D29070)" :
      "linear-gradient(180deg, #F0D69B, #DDB164)";
    const dark = tint === "lavender" ? "#231F33" : tint === "terra" ? "#33180E" : "#1B1306";
    return (
      <button
        onClick={onClick}
        disabled={disabled}
        style={{
          appearance: "none",
          padding: "9px 16px",
          borderRadius: 10,
          fontFamily: "var(--font-text)", fontSize: 14, fontWeight: 600,
          color: disabled ? "rgba(255,255,255,0.35)" : dark,
          background: disabled ? "rgba(255,255,255,0.06)" : tintFill,
          border: disabled ? "1px solid rgba(255,255,255,0.10)" : "0.5px solid rgba(255,255,255,0.35)",
          boxShadow: disabled ? "none" : "0 2px 4px rgba(0,0,0,0.30), inset 0 1px 0 rgba(255,255,255,0.40)",
          display: "inline-flex", alignItems: "center", gap: 8,
          cursor: disabled ? "not-allowed" : "pointer",
        }}
      >
        <PlayFill size={11} />
        {label}
      </button>
    );
  }

  // ---------- Custom Voice screen ----------

  function CustomVoiceScreen({ draft, setDraft, model, setModel, onGenerate, isGenerating, hasResult }) {
    const speakers = [
      { value: "aiden", label: "Aiden — English native" },
      { value: "iris",  label: "Iris — English native" },
      { value: "leo",   label: "Leo — Spanish (Castilian)" },
      { value: "naomi", label: "Naomi — Japanese" },
    ];
    const deliveries = [
      { value: "neutral",  label: "Neutral" },
      { value: "calm",     label: "Calm" },
      { value: "happy",    label: "Happy" },
      { value: "sad",      label: "Sad" },
      { value: "angry",    label: "Angry" },
      { value: "fearful",  label: "Fearful" },
      { value: "whisper",  label: "Whisper" },
      { value: "dramatic", label: "Dramatic" },
      { value: "excited",  label: "Excited" },
      { value: "custom",   label: "Custom" },
    ];
    const intensities = [
      { value: "subtle", label: "Subtle" },
      { value: "normal", label: "Normal" },
      { value: "strong", label: "Strong" },
    ];

    const trailingText = isGenerating ? "Generating" : (draft.text.trim() ? "Ready" : null);
    const readyTitle = !draft.text.trim() ? "Add a script" : isGenerating ? "Generating final audio" : "Ready to generate";
    const readyDetail = !draft.text.trim()
      ? "Speaker and delivery are set. Add a line to generate."
      : isGenerating
        ? "Rendering the complete take. The file lands in the player when ready."
        : "Ready to generate and save.";

    return (
      <ScreenScaffold title="Custom Voice" tint="gold">
        <GlassCard tint="gold" padding={14}>
          <SectionHead
            icon={<Sliders size={16} />}
            title="Configuration"
            tint="gold"
            trailingControl={<SpeedQuality value={model} onChange={setModel} />}
          />
          <Detail>Pick a built-in speaker, then shape the delivery before you generate.</Detail>

          <div style={{ display: "grid", gridTemplateColumns: "1fr", gap: 10 }}>
            <Stack gap={6}>
              <Label>Speaker</Label>
              <Picker value={draft.speaker} onChange={(v) => setDraft({ ...draft, speaker: v })} options={speakers} maxWidth={260} />
              <Helper>Choose the built-in speaker that should deliver this line.</Helper>
            </Stack>
            <Stack gap={6}>
              <Label>Delivery</Label>
              <Row gap={12}>
                <Picker value={draft.delivery} onChange={(v) => setDraft({ ...draft, delivery: v })} options={deliveries} maxWidth={200} />
                <span style={{ fontSize: 12, fontWeight: 600, color: draft.delivery === "neutral" || draft.delivery === "custom" ? "var(--fg-tertiary)" : "var(--fg-secondary)" }}>Intensity</span>
                <div style={{ opacity: draft.delivery === "neutral" || draft.delivery === "custom" ? 0.5 : 1 }}>
                  <Picker
                    value={draft.intensity}
                    onChange={(v) => setDraft({ ...draft, intensity: v })}
                    options={intensities}
                    minWidth={120}
                    maxWidth={140}
                  />
                </div>
              </Row>
              <Stack gap={6} style={{ marginTop: 4 }}>
                <div style={{ fontSize: 12, fontWeight: 600, color: draft.delivery === "custom" ? "var(--fg-secondary)" : "var(--fg-tertiary)" }}>Custom tone</div>
                <TextField
                  value={draft.customTone}
                  onChange={(v) => setDraft({ ...draft, customTone: v })}
                  placeholder="Describe the delivery in your own words"
                  focus={false}
                />
              </Stack>
            </Stack>
          </div>
        </GlassCard>

        <ScriptCard
          tint="gold"
          trailingText={trailingText}
          value={draft.text}
          onChange={(text) => setDraft({ ...draft, text })}
          placeholder="Type or paste your script"
          onGenerate={onGenerate}
          readinessTitle={readyTitle}
          readinessDetail={readyDetail}
          isGenerating={isGenerating}
        />
      </ScreenScaffold>
    );
  }

  // ---------- Voice Design screen ----------

  function VoiceDesignScreen({ draft, setDraft, model, setModel, onGenerate, isGenerating }) {
    const deliveries = [
      { value: "neutral", label: "Neutral" },
      { value: "calm",    label: "Calm" },
      { value: "happy",   label: "Happy" },
      { value: "sad",     label: "Sad" },
      { value: "excited", label: "Excited" },
      { value: "custom",  label: "Custom" },
    ];
    const intensities = [
      { value: "subtle", label: "Subtle" },
      { value: "normal", label: "Normal" },
      { value: "strong", label: "Strong" },
    ];

    const trailingText = isGenerating ? "Generating" : (draft.text.trim() && draft.brief.trim() ? "Ready" : null);
    const readyTitle = !draft.brief.trim() ? "Add a voice brief" : !draft.text.trim() ? "Add a script" : "Ready to generate";
    const readyDetail = !draft.brief.trim()
      ? "Describe the voice before writing the final line."
      : !draft.text.trim()
        ? "The brief is set. Add the line that should be spoken."
        : "Voice design is ready to render.";

    return (
      <ScreenScaffold title="Voice Design" tint="lavender">
        <GlassCard tint="lavender" padding={14}>
          <SectionHead
            icon={<Sliders size={16} />}
            title="Configuration"
            tint="lavender"
            trailingControl={<SpeedQuality value={model} onChange={setModel} />}
          />
          <Detail>Describe the voice, set the delivery, then keep the script front and center.</Detail>

          <Stack gap={10}>
            <Stack gap={6}>
              <Label>Voice brief</Label>
              <TextField
                value={draft.brief}
                onChange={(v) => setDraft({ ...draft, brief: v })}
                placeholder="A composed documentary narrator with a low, warm voice and deliberate pacing."
              />
              <Helper>Describe timbre, accent, or delivery style in one tight sentence.</Helper>
            </Stack>
            <Stack gap={6}>
              <Label>Delivery</Label>
              <Row gap={12}>
                <Picker value={draft.delivery} onChange={(v) => setDraft({ ...draft, delivery: v })} options={deliveries} maxWidth={200} />
                <span style={{ fontSize: 12, fontWeight: 600, color: "var(--fg-secondary)" }}>Intensity</span>
                <div style={{ opacity: draft.delivery === "neutral" || draft.delivery === "custom" ? 0.5 : 1 }}>
                  <Picker value={draft.intensity} onChange={(v) => setDraft({ ...draft, intensity: v })} options={intensities} minWidth={120} maxWidth={140} />
                </div>
              </Row>
            </Stack>
          </Stack>
        </GlassCard>

        <ScriptCard
          tint="lavender"
          trailingText={trailingText}
          value={draft.text}
          onChange={(text) => setDraft({ ...draft, text })}
          placeholder="Type or paste your script"
          onGenerate={onGenerate}
          readinessTitle={readyTitle}
          readinessDetail={readyDetail}
          isGenerating={isGenerating}
        />
      </ScreenScaffold>
    );
  }

  // ---------- Voice Cloning screen ----------

  function VoiceCloningScreen({ draft, setDraft, model, setModel, onGenerate, isGenerating }) {
    const savedVoices = [
      { value: "", label: "Choose a saved voice" },
      { value: "uitestref", label: "UITestRef — Voice Design clip" },
      { value: "narrator-warm", label: "Warm narrator (test)" },
    ];

    const hasReference = draft.source === "saved" ? !!draft.savedVoice : !!draft.refFile;
    const trailingText = isGenerating ? "Generating" : (hasReference && draft.text.trim() ? "Ready" : null);

    return (
      <ScreenScaffold title="Voice Cloning" tint="terra">
        <GlassCard tint="terra" padding={14}>
          <SectionHead
            icon={<Sliders size={16} />}
            title="Configuration"
            tint="terra"
            trailingControl={<SpeedQuality value={model} onChange={setModel} />}
          />
          <Detail>Choose a saved voice or import a reference clip, then add an optional transcript.</Detail>

          <Stack gap={10}>
            <Stack gap={6}>
              <Label>Source</Label>
              <Row gap={10}>
                <div style={{ flex: 1 }}>
                  <Picker
                    value={draft.savedVoice}
                    onChange={(v) => setDraft({ ...draft, savedVoice: v, source: "saved" })}
                    options={savedVoices}
                    maxWidth={320}
                  />
                </div>
                <button
                  onClick={() => setDraft({ ...draft, refFile: "narrator-15s.m4a", source: "imported" })}
                  style={{
                    appearance: "none",
                    padding: "7px 12px",
                    borderRadius: 8,
                    background: "rgba(255,255,255,0.06)",
                    border: "1px solid rgba(255,255,255,0.10)",
                    color: "var(--fg-primary)",
                    fontFamily: "var(--font-text)", fontSize: 13, fontWeight: 500,
                    display: "inline-flex", alignItems: "center", gap: 8,
                    cursor: "pointer",
                  }}
                >
                  <WaveformPlus size={14} />
                  Import reference audio…
                </button>
              </Row>
              <Helper>Only use voice clips you own or have permission to use.</Helper>
              {!hasReference && (
                <div style={{ display: "flex", alignItems: "center", gap: 6, marginTop: 4, color: "var(--fg-tertiary)", fontSize: 11 }}>
                  <WaveformPlus size={12} />
                  <span>Add a reference clip to unlock the script composer and generation.</span>
                </div>
              )}
              {hasReference && (
                <div style={{
                  marginTop: 6, display: "flex", alignItems: "center", gap: 10,
                  padding: "8px 12px",
                  background: "rgba(219,168,135,0.10)",
                  border: "1px solid rgba(219,168,135,0.24)",
                  borderRadius: 10,
                }}>
                  <WaveformPlus size={14} style={{ color: "#DBA887" }} />
                  <div style={{ flex: 1 }}>
                    <div style={{ fontSize: 12, fontWeight: 600 }}>
                      {draft.source === "saved"
                        ? savedVoices.find((s) => s.value === draft.savedVoice)?.label
                        : draft.refFile}
                    </div>
                    <div style={{ fontSize: 10, color: "var(--fg-secondary)" }}>
                      {draft.source === "saved" ? "Saved voice" : "Imported · 15 s"}
                    </div>
                  </div>
                  <button
                    onClick={() => setDraft({ ...draft, savedVoice: "", refFile: "", source: "saved" })}
                    style={{
                      background: "transparent", border: 0, color: "var(--fg-secondary)",
                      fontFamily: "var(--font-text)", fontSize: 11, cursor: "pointer",
                    }}>Clear</button>
                </div>
              )}
            </Stack>
            <Stack gap={6}>
              <Label>Transcript</Label>
              <TextField
                value={draft.transcript}
                onChange={(v) => setDraft({ ...draft, transcript: v })}
                placeholder="What does the reference audio say? (optional)"
              />
            </Stack>
          </Stack>
        </GlassCard>

        <ScriptCard
          tint="terra"
          trailingText={trailingText}
          value={draft.text}
          onChange={(text) => setDraft({ ...draft, text })}
          placeholder="Type the line for the cloned voice"
          onGenerate={onGenerate}
          readinessTitle={!hasReference ? "Add a reference" : !draft.text.trim() ? "Add a script" : "Ready to generate"}
          readinessDetail={!hasReference ? "Saved voices or imported clips both work. Pick one before writing the line." : !draft.text.trim() ? "The reference is ready. Add the line to clone." : "Cloning is ready to render."}
          isGenerating={isGenerating}
          composerDisabled={!hasReference}
        />
      </ScreenScaffold>
    );
  }

  // ---------- Page scaffold + script composer ----------

  function ScreenScaffold({ title, tint, children }) {
    const radialColor =
      tint === "lavender" ? "rgba(191,170,219,0.14)" :
      tint === "terra"    ? "rgba(219,168,135,0.14)" :
      "rgba(237,204,138,0.10)";

    return (
      <div
        style={{
          flex: 1, minWidth: 0, minHeight: 0,
          display: "flex", flexDirection: "column",
          background: `radial-gradient(60% 40% at 50% -5%, ${radialColor}, transparent 70%), linear-gradient(180deg, #0F1014, #1A1C22)`,
          padding: "14px 22px 16px",
          gap: 8,
        }}
      >
        <h1 style={{ margin: 0, padding: "6px 4px 4px", fontSize: 22, fontWeight: 600, color: "var(--fg-primary)" }}>{title}</h1>
        <div style={{ flex: 1, minHeight: 0, display: "flex", flexDirection: "column", gap: 10 }}>
          {children}
        </div>
      </div>
    );
  }

  function ScriptCard({ tint, trailingText, value, onChange, placeholder, onGenerate, readinessTitle, readinessDetail, isGenerating, composerDisabled }) {
    return (
      <GlassCard tint={tint} padding={14} fillHeight>
        <SectionHead
          icon={<TextLines size={16} />}
          title="Script"
          tint={tint}
          trailingText={trailingText}
        />
        <div style={{ flex: 1, minHeight: 0, display: "flex", flexDirection: "column", gap: 8 }}>
          <div style={{
            flex: 1, minHeight: 90,
            background: "var(--bg-field)",
            border: "0.5px solid rgba(255,255,255,0.10)",
            borderRadius: 12,
            padding: 12,
            opacity: composerDisabled ? 0.5 : 1,
            display: "flex",
          }}>
            <textarea
              value={value}
              onChange={(e) => onChange(e.target.value)}
              placeholder={placeholder}
              disabled={composerDisabled}
              style={{
                flex: 1, border: 0, outline: 0, resize: "none",
                background: "transparent",
                color: "var(--fg-primary)",
                fontFamily: "var(--font-text)", fontSize: 14, lineHeight: 1.5,
              }}
            />
          </div>
          <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
            <button
              disabled={composerDisabled}
              style={{
                appearance: "none",
                padding: "6px 12px", borderRadius: 8,
                background: "rgba(255,255,255,0.06)",
                border: "1px solid rgba(255,255,255,0.10)",
                color: "var(--fg-primary)",
                fontFamily: "var(--font-text)", fontSize: 12, fontWeight: 500,
                display: "inline-flex", alignItems: "center", gap: 6,
                opacity: composerDisabled ? 0.5 : 1,
                cursor: composerDisabled ? "not-allowed" : "pointer",
              }}
            >
              Batch
              <span style={{ borderLeft: "1px solid rgba(255,255,255,0.15)", height: 12, marginLeft: 2 }} />
              <WaveformPlus size={12} />
            </button>
            <div style={{ flex: 1 }} />
            <CharCount value={value} />
            <GenerateButton
              tint={tint}
              onClick={onGenerate}
              disabled={composerDisabled || !value.trim() || isGenerating}
              label={isGenerating ? "Generating…" : "Generate"}
            />
          </div>
          <div style={{
            display: "flex", flexDirection: "column", gap: 2,
            padding: "8px 12px",
            background: "rgba(255,255,255,0.03)",
            border: "1px solid rgba(255,255,255,0.06)",
            borderRadius: 10,
          }}>
            <div style={{ fontSize: 12, fontWeight: 600, color: "var(--fg-primary)" }}>{readinessTitle}</div>
            <div style={{ fontSize: 11, color: "var(--fg-secondary)", lineHeight: 1.4 }}>{readinessDetail}</div>
          </div>
        </div>
      </GlassCard>
    );
  }

  Object.assign(window, {
    CustomVoiceScreen, VoiceDesignScreen, VoiceCloningScreen,
  });
})();
