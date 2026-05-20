// Main app — routing, state, tweaks wiring.

const { useState: useStateApp, useEffect: useEffectApp } = React;

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "modeIntensity": "warm",
  "composerDensity": "comfortable",
  "showModeSegmented": true,
  "startScreen": "studio"
}/*EDITMODE-END*/;

function App() {
  const [tweaks, setTweak] = window.useTweaks
    ? window.useTweaks(TWEAK_DEFAULTS)
    : [TWEAK_DEFAULTS, () => {}];

  // — App state ————————————————————————————
  const [showOnboarding, setShowOnboarding] = useStateApp(false);
  const [tab, setTab] = useStateApp(tweaks.startScreen || 'studio');
  const [mode, setMode] = useStateApp('custom');
  const [script, setScript] = useStateApp(
    "Welcome back to the workshop. Today we are building a small wooden box, end to end."
  );

  const [voiceId, setVoiceId] = useStateApp('sienna');
  const [deliveryId, setDeliveryId] = useStateApp('calm');
  const [designBrief, setDesignBrief] = useStateApp('A warm, deep narrator with a subtle British accent.');
  const [cloneRef, setCloneRef] = useStateApp(null);

  const [sheet, setSheet] = useStateApp(null);
  const [recordingOpen, setRecordingOpen] = useStateApp(false);
  const [modelInstall, setModelInstall] = useStateApp(null);
  const [modelDelete, setModelDelete] = useStateApp(null);
  const [playerItem, setPlayerItem] = useStateApp(null); // { id, mode, voice, text, duration, timeLabel? }

  const [genState, setGenState] = useStateApp('idle'); // idle | generating | complete

  // — Generation flow ————————————————————————————
  useEffectApp(() => {
    if (genState !== 'generating') return;
    const id = setTimeout(() => setGenState('complete'), 2400);
    return () => clearTimeout(id);
  }, [genState]);

  const handleGenerate = () => {
    setGenState('generating');
  };

  // Reset gen state when mode/script changes
  useEffectApp(() => {
    if (genState === 'complete') {
      // Keep player visible until dismissed; do nothing
    }
  }, [mode]);

  const handleModeChange = (newMode) => {
    setMode(newMode);
    if (genState !== 'idle') setGenState('idle');
  };

  const handleScriptChange = (txt) => {
    onScriptEdit: setScript(txt);
    setScript(txt);
  };

  // — When tab changes, dismiss any open sheet
  useEffectApp(() => { setSheet(null); }, [tab]);

  // — Render ————————————————————————————

  return (
    <div className="vc-app theme-dark" data-screen-label={`${tab}${tab === 'studio' ? ` · ${mode}` : ''}`}>
      {/* Mode-tinted radial wash on Studio; brand-gold wash on the library / settings tabs */}
      {tab === 'studio' ? (
        <window.ModeBackdrop mode={mode} intensity={tweaks.modeIntensity} />
      ) : (
        <window.ModeBackdrop
          intensity={tweaks.modeIntensity}
          color="var(--vocello-gold)" />
      )}

      {showOnboarding ? (
        <window.Onboarding onDone={() => setShowOnboarding(false)} />
      ) : (
        <div className="vc-screen">
          {tab === 'studio' && (
            <window.Studio
              mode={mode} onModeChange={handleModeChange}
              script={script} onScriptChange={setScript}
              voiceId={voiceId} onVoiceChange={setVoiceId}
              deliveryId={deliveryId} onDeliveryChange={setDeliveryId}
              designBrief={designBrief} onDesignBriefChange={setDesignBrief}
              cloneRef={cloneRef} onCloneRefChange={setCloneRef}
              onOpenVoicePicker={() => setSheet('voice')}
              onOpenDeliveryPicker={() => setSheet('delivery')}
              onOpenRecording={() => setRecordingOpen(true)}
              onOpenDesignBrief={() => setSheet('designBrief')}
              genState={genState}
              onGenerate={handleGenerate}
              onCancel={() => setGenState('idle')}
              onPlayerDismiss={() => setGenState('idle')}
              onInstallModel={(m) => setModelInstall(m)}
              tweaks={tweaks}
            />
          )}
          {tab === 'voices' && (
            <window.Voices
              onUseInClone={() => { setMode('clone'); setTab('studio'); }}
              onPreviewVoice={(v) => setPlayerItem({
                id: `voice-${v.id}`,
                mode: v.saved ? 'clone' : 'custom',
                voice: v.name,
                text: `Hi, I'm ${v.name}. ${v.desc}.`,
                duration: 4.2,
                timeLabel: 'Voice preview',
              })}
            />
          )}
          {tab === 'history' && (
            <window.History
              onPlay={(h) => setPlayerItem({
                id: h.id,
                mode: h.mode,
                voice: h.voice,
                text: h.text,
                duration: h.duration,
                timeLabel: h.time,
              })}
            />
          )}
          {tab === 'settings' && (
            <window.SettingsTab
              onInstallModel={(m) => setModelInstall(m)}
              onDeleteModel={(m) => setModelDelete(m)}
            />
          )}

          <window.TabDock tab={tab} onChange={setTab} mode={mode} />
        </div>
      )}

      {/* Bottom sheets */}
      <window.VoicePickerSheet
        open={sheet === 'voice'}
        onClose={() => setSheet(null)}
        mode={mode}
        selected={mode === 'clone' ? (cloneRef?.id) : voiceId}
        onSelect={(id) => {
          if (mode === 'clone') {
            const saved = window.VOCELLO_DATA.savedVoices.find(v => v.id === id);
            if (saved) setCloneRef({ id: saved.id, name: saved.name, hue: saved.hue });
          } else {
            setVoiceId(id);
          }
        }} />

      <window.DeliverySheet
        open={sheet === 'delivery'}
        onClose={() => setSheet(null)}
        selected={deliveryId}
        onSelect={setDeliveryId}
        mode={mode} />

      <DesignBriefSheet
        open={sheet === 'designBrief'}
        onClose={() => setSheet(null)}
        value={designBrief}
        onChange={setDesignBrief} />

      <window.RecordingOverlay
        open={recordingOpen}
        onClose={() => setRecordingOpen(false)}
        onCapture={(seconds) => setCloneRef({ id: 'imported', name: `New recording (${Math.round(seconds)}s)`, hue: 200 })} />

      <window.ModelInstallSheet
        open={!!modelInstall}
        model={modelInstall}
        onClose={() => setModelInstall(null)}
        onInstall={() => {
          // Mark model installed (mutation on data object — prototype only)
          if (modelInstall) {
            const m = window.VOCELLO_DATA.models.find(x => x.id === modelInstall.id);
            if (m) m.installed = true;
          }
          setModelInstall(null);
        }} />

      <DeleteModelSheet
        open={!!modelDelete}
        model={modelDelete}
        onClose={() => setModelDelete(null)}
        onConfirm={() => {
          if (modelDelete) {
            const m = window.VOCELLO_DATA.models.find(x => x.id === modelDelete.id);
            if (m) { m.installed = false; m.active = false; }
          }
          setModelDelete(null);
        }} />

      <window.PlayerSheet
        open={!!playerItem}
        item={playerItem}
        onClose={() => setPlayerItem(null)} />

      {/* Tweaks panel */}
      {window.TweaksPanel && (
        <window.TweaksPanel title="Tweaks">
          <window.TweakSection label="Look">
            <window.TweakRadio
              label="Mode tint"
              value={tweaks.modeIntensity}
              onChange={v => setTweak('modeIntensity', v)}
              options={[
                { value: 'whisper', label: 'Whisper' },
                { value: 'warm',    label: 'Warm' },
                { value: 'loud',    label: 'Loud' },
              ]} />
          </window.TweakSection>

          <window.TweakSection label="Composer">
            <window.TweakRadio
              label="Density"
              value={tweaks.composerDensity}
              onChange={v => setTweak('composerDensity', v)}
              options={[
                { value: 'compact',     label: 'Compact' },
                { value: 'comfortable', label: 'Comfy' },
                { value: 'roomy',       label: 'Roomy' },
              ]} />
            <window.TweakToggle
              label="Show mode segmented"
              value={tweaks.showModeSegmented}
              onChange={v => setTweak('showModeSegmented', v)} />
          </window.TweakSection>

          <window.TweakSection label="Demo flows">
            <window.TweakButton label="Replay onboarding"
              onClick={() => setShowOnboarding(true)} />
            <window.TweakButton label="Reset Voice Cloning"
              onClick={() => { setMode('clone'); setCloneRef(null); setTab('studio'); }} />
            <window.TweakButton label="Show player state"
              onClick={() => { setGenState('complete'); setTab('studio'); }} />
            <window.TweakButton label="Show generating state"
              onClick={() => { setGenState('generating'); setTab('studio'); }} />
            <window.TweakButton label="Open model install"
              onClick={() => { setModelInstall(window.VOCELLO_DATA.models.find(m => !m.installed) || window.VOCELLO_DATA.models[0]); }} />
          </window.TweakSection>
        </window.TweaksPanel>
      )}
    </div>
  );
}

// — Small inline sheet for Voice Design brief ——————————————————————————
function DesignBriefSheet({ open, onClose, value, onChange }) {
  const presets = [
    'A warm, deep narrator with a subtle British accent.',
    'A bright young female, energetic and conversational.',
    'A gravelly older male, slow, late-night radio.',
    'A calm, careful narrator, clear diction, neutral.',
  ];
  return (
    <window.BottomSheet open={open} onClose={onClose} title="Voice brief">
      <p style={{ font: '400 14px/19px var(--font-sans)', color: 'var(--fg-2)', margin: '0 0 16px' }}>
        Describe the voice. Combine character, age, accent, and texture.
      </p>
      <textarea
        value={value}
        onChange={e => onChange(e.target.value)}
        rows={4}
        placeholder="A warm, deep narrator with a subtle British accent."
        style={{
          width: '100%',
          background: 'rgba(255,255,255,0.04)',
          border: '0.5px solid color-mix(in oklch, var(--mode-design) 40%, transparent)',
          borderRadius: 14,
          padding: '14px 16px',
          color: 'var(--fg-1)',
          font: '500 16px/22px var(--font-sans)',
          resize: 'none',
          outline: 'none',
        }} />
      <div style={{ font: '600 11px/14px var(--font-sans)', letterSpacing: '0.08em', textTransform: 'uppercase', color: 'var(--fg-2)', margin: '18px 0 10px' }}>Starting points</div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
        {presets.map(p => (
          <button key={p}
            onClick={() => { onChange(p); onClose(); }}
            style={{
              padding: '12px 14px', borderRadius: 12,
              background: 'rgba(255,255,255,0.03)',
              border: '0.5px solid rgba(255,255,255,0.08)',
              color: 'var(--fg-1)',
              font: '400 14px/18px var(--font-sans)',
              cursor: 'pointer',
              textAlign: 'left',
            }}>
            {p}
          </button>
        ))}
      </div>
    </window.BottomSheet>
  );
}

// — Confirmation sheet for deleting an installed model ——————————————————————
function DeleteModelSheet({ open, onClose, onConfirm, model }) {
  if (!model) return null;
  return (
    <window.BottomSheet open={open} onClose={onClose} title="Delete model?">
      <div style={{ display: 'flex', alignItems: 'center', gap: 14, padding: '4px 0 20px' }}>
        <div style={{
          width: 44, height: 44, borderRadius: 12,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          background: 'rgba(255, 69, 58, 0.12)',
          border: '0.5px solid rgba(255, 69, 58, 0.32)',
          color: 'var(--status-error)',
          flexShrink: 0,
        }}>
          <window.IconTrash w={20} h={20} />
        </div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ font: '600 16px/20px var(--font-sans)', letterSpacing: '-0.005em', color: 'var(--fg-1)' }}>
            {model.modeLabel}
          </div>
          <div style={{ font: '400 13px/17px var(--font-sans)', color: 'var(--fg-2)', marginTop: 2 }}>
            Frees {model.size}. You can reinstall later from Settings.
          </div>
        </div>
      </div>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 10, paddingBottom: 8 }}>
        <button
          onClick={onConfirm}
          className="vc-cta"
          style={{
            background: 'linear-gradient(180deg, #FF453A 0%, #C5251A 100%)',
            color: '#fff',
          }}>
          <window.IconTrash w={17} h={17} />
          Delete model
        </button>
        <button
          onClick={onClose}
          className="vc-cta vc-cta-cancel"
          style={{ background: 'rgba(255,255,255,0.05)', boxShadow: 'none' }}>
          Cancel
        </button>
      </div>
    </window.BottomSheet>
  );
}

// — Mount ————————————————————————————
ReactDOM.createRoot(document.getElementById('vc-mount')).render(<App />);
