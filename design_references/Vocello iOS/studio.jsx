// Studio — the composer. Custom Voice, Voice Design, Voice Cloning all share
// this surface; the setup chips below the script change based on mode.

const { useState: useStateSt, useEffect: useEffectSt, useRef: useRefSt } = React;

function Studio({
  mode, onModeChange,
  script, onScriptChange,
  voiceId, onVoiceChange,
  deliveryId, onDeliveryChange,
  designBrief, onDesignBriefChange,
  cloneRef, onCloneRefChange,
  onOpenVoicePicker, onOpenDeliveryPicker, onOpenRecording, onOpenDesignBrief,
  genState, onGenerate, onCancel, onPlayerDismiss,
  onInstallModel,
  tweaks,
}) {
  const data = window.VOCELLO_DATA;
  const tint = window.modeColor(mode);
  const activeModel = data.models.find(m => m.mode === mode);
  const modelInstalled = !!activeModel?.installed;

  // Look up names
  const selectedVoice = data.builtInVoices.find(v => v.id === voiceId)
                     || data.savedVoices.find(v => v.id === voiceId);
  const selectedDelivery = data.deliveries.find(d => d.id === deliveryId);

  // ─── SCRIPT EDITOR ───────────────────────────────
  const scriptRef = useRefSt(null);
  const limit = 800;
  const counterTone = script.length > limit ? 'over' : '';
  const counterText = `${script.length} / ${limit}`;

  return (
    <React.Fragment>
      {tweaks.showModeSegmented && (
        <window.ModeSegmented mode={mode} onChange={onModeChange} />
      )}

      <div className="vc-screen-body no-scroll" style={{ display: 'flex', flexDirection: 'column' }}>
        <div className="vc-composer-pad">
          <div className="vc-composer-editor">
            <textarea ref={scriptRef}
              className={`vc-script density-${tweaks.composerDensity}`}
              value={script}
              onChange={e => onScriptChange(e.target.value.slice(0, limit + 200))}
              placeholder={
                mode === 'design'
                  ? 'Type the lines you want this designed voice to say.'
                  : mode === 'clone'
                    ? 'Type the new text. The reference voice will speak it.'
                    : 'Type or paste your script.'
              }
              spellCheck="false"
              autoCapitalize="sentences"
              autoCorrect="off"
              maxLength={limit + 200}
            />
            <div className="vc-script-meta">
              <span>
                {mode === 'custom' && 'Built-in voice'}
                {mode === 'design' && 'Designed voice'}
                {mode === 'clone' && 'Voice cloning'}
              </span>
              <span className="vc-script-meta-counter" data-over={counterTone === 'over'}>{counterText}</span>
            </div>
          </div>
        </div>

        {/* Setup chips row — varies by mode */}
        <div className="vc-setup-row">
          {mode === 'custom' && (
            <React.Fragment>
              <button className="vc-setup-chip vc-tappable" onClick={onOpenVoicePicker}>
                <window.VoiceAvatar name={selectedVoice?.name || ''} hue={selectedVoice?.hue || 35} size="md"
                  children={undefined} />
                <div className="vc-setup-chip-label">
                  <div className="vc-setup-chip-key">Voice</div>
                  <div className="vc-setup-chip-value">{selectedVoice?.name || 'Pick a voice'}</div>
                </div>
                <window.IconChevronDown w={14} h={14} style={{ color: 'var(--fg-3)', marginLeft: 4 }} />
              </button>
              <button className="vc-setup-chip vc-tappable" onClick={onOpenDeliveryPicker}>
                <div className="vc-setup-chip-icon" style={{ background: selectedDelivery?.color, color: 'rgba(13,14,18,0.85)' }}>
                  <window.IconWaveform w={18} h={18} />
                </div>
                <div className="vc-setup-chip-label">
                  <div className="vc-setup-chip-key">Delivery</div>
                  <div className="vc-setup-chip-value">{selectedDelivery?.name}</div>
                </div>
                <window.IconChevronDown w={14} h={14} style={{ color: 'var(--fg-3)', marginLeft: 4 }} />
              </button>
            </React.Fragment>
          )}

          {mode === 'design' && (
            <React.Fragment>
              <button className="vc-setup-chip vc-tappable" onClick={onOpenDesignBrief}>
                <div className="vc-setup-chip-icon" style={{ background: 'color-mix(in oklch, var(--mode-design) 22%, transparent)', color: 'var(--mode-design)' }}>
                  <window.IconWand w={18} h={18} />
                </div>
                <div className="vc-setup-chip-label">
                  <div className="vc-setup-chip-key">Voice brief</div>
                  <div className="vc-setup-chip-value">
                    {designBrief || 'Describe the voice'}
                  </div>
                </div>
                <window.IconChevronDown w={14} h={14} style={{ color: 'var(--fg-3)', marginLeft: 4 }} />
              </button>
              <button className="vc-setup-chip vc-tappable" onClick={onOpenDeliveryPicker}>
                <div className="vc-setup-chip-icon" style={{ background: selectedDelivery?.color, color: 'rgba(13,14,18,0.85)' }}>
                  <window.IconWaveform w={18} h={18} />
                </div>
                <div className="vc-setup-chip-label">
                  <div className="vc-setup-chip-key">Delivery</div>
                  <div className="vc-setup-chip-value">{selectedDelivery?.name}</div>
                </div>
              </button>
            </React.Fragment>
          )}

          {mode === 'clone' && (
            <React.Fragment>
              {cloneRef ? (
                <button className="vc-setup-chip vc-tappable" onClick={onOpenVoicePicker}>
                  <window.VoiceAvatar name={cloneRef.name} hue={cloneRef.hue || 160} size="md"
                    children={undefined} />
                  <div className="vc-setup-chip-label">
                    <div className="vc-setup-chip-key">Reference</div>
                    <div className="vc-setup-chip-value">{cloneRef.name}</div>
                  </div>
                  <window.IconChevronDown w={14} h={14} style={{ color: 'var(--fg-3)', marginLeft: 4 }} />
                </button>
              ) : (
                <button className="vc-setup-chip vc-tappable" onClick={onOpenRecording}
                  style={{ borderColor: 'color-mix(in oklch, var(--mode-cloning) 40%, transparent)', background: 'color-mix(in oklch, var(--mode-cloning) 10%, transparent)' }}>
                  <div className="vc-setup-chip-icon" style={{ background: 'var(--mode-cloning)', color: 'rgba(13,14,18,0.9)' }}>
                    <window.IconMic w={18} h={18} />
                  </div>
                  <div className="vc-setup-chip-label">
                    <div className="vc-setup-chip-key" style={{ color: 'var(--mode-cloning)' }}>Record</div>
                    <div className="vc-setup-chip-value">Add a reference clip</div>
                  </div>
                </button>
              )}
              <button className="vc-setup-chip vc-tappable" onClick={onOpenVoicePicker}
                style={{ background: 'rgba(255,255,255,0.03)' }}>
                <div className="vc-setup-chip-icon">
                  <window.IconBookmark w={16} h={16} />
                </div>
                <div className="vc-setup-chip-label">
                  <div className="vc-setup-chip-key">Saved</div>
                  <div className="vc-setup-chip-value">Pick a voice</div>
                </div>
              </button>
            </React.Fragment>
          )}
        </div>

        {/* CTA / generating / player area */}
        <div className="vc-dock-area">
          {genState === 'idle' && !modelInstalled && (
            <button className="vc-cta"
              onClick={() => onInstallModel(activeModel)}
              style={{
                background: `linear-gradient(180deg, ${tint} 0%, color-mix(in oklch, ${tint} 80%, black) 100%)`,
              }}>
              <window.IconDownload w={18} h={18} style={{ color: '#0D0E18' }} />
              Install {activeModel.modeLabel}
            </button>
          )}

          {genState === 'idle' && modelInstalled && (
            <button className="vc-cta"
              disabled={!script.trim() || (mode === 'clone' && !cloneRef) || (mode === 'design' && !designBrief)}
              onClick={onGenerate}
              style={{
                background: `linear-gradient(180deg, ${tint} 0%, color-mix(in oklch, ${tint} 80%, black) 100%)`,
              }}>
              <window.IconSparkles w={18} h={18} style={{ color: '#0D0E18' }} />
              Generate
            </button>
          )}

          {genState === 'generating' && (
            <div className="vc-generating">
              <div className="vc-generating-bars">
                {Array.from({ length: 28 }).map((_, i) => (
                  <div key={i} className="vc-generating-bar"
                    style={{
                      background: `linear-gradient(180deg, ${tint} 0%, color-mix(in oklch, ${tint} 60%, transparent) 100%)`,
                      animationDelay: `${i * 50}ms`,
                      height: '100%',
                    }} />
                ))}
              </div>
              <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'flex-end', gap: 2, marginRight: 4 }}>
                <span style={{ font: '600 13px/1 var(--font-sans)', color: 'var(--fg-1)' }}>Generating</span>
                <span style={{ font: '400 11px/1 var(--font-sans)', color: 'var(--fg-2)' }}>{mode === 'clone' ? 'Cloning voice…' : mode === 'design' ? 'Designing voice…' : 'Rendering audio…'}</span>
              </div>
              <button onClick={onCancel} className="vc-icon-btn" style={{ width: 36, height: 36 }}>
                <window.IconStop w={14} h={14} />
              </button>
            </div>
          )}

          {genState === 'complete' && (
            <InlinePlayer mode={mode} tint={tint} onDismiss={onPlayerDismiss} script={script} voice={selectedVoice?.name || cloneRef?.name || 'Voice'} />
          )}
        </div>
      </div>
    </React.Fragment>
  );
}

// — INLINE PLAYER (the "just generated" hero) ——————————————————————————
function InlinePlayer({ mode, tint, onDismiss, script, voice }) {
  const [playing, setPlaying] = useStateSt(true);
  const [progress, setProgress] = useStateSt(0);
  const duration = 6.4;

  useEffectSt(() => {
    if (!playing) return;
    const tStart = Date.now() - progress * duration * 1000;
    const id = setInterval(() => {
      const p = (Date.now() - tStart) / 1000 / duration;
      if (p >= 1) { setProgress(1); setPlaying(false); clearInterval(id); return; }
      setProgress(p);
    }, 60);
    return () => clearInterval(id);
  }, [playing]);

  const fmt = (s) => {
    const m = Math.floor(s / 60);
    const sec = Math.floor(s % 60);
    return `${m}:${sec.toString().padStart(2, '0')}`;
  };

  return (
    <div className="vc-player">
      <div className="vc-player-top">
        <div className="vc-player-time">{fmt(progress * duration)}</div>
        <window.PlayerWaveform progress={progress} accent={tint} bars={38} seed={2} />
        <div className="vc-player-time end">{fmt(duration)}</div>
      </div>

      <div className="vc-player-controls">
        <button className="vc-player-play"
          onClick={() => {
            if (progress >= 1) setProgress(0);
            setPlaying(p => !p);
          }}
          style={{ background: `linear-gradient(180deg, ${tint} 0%, color-mix(in oklch, ${tint} 80%, black) 100%)` }}>
          {playing ? <window.IconPause w={20} h={20} /> : <window.IconPlay w={20} h={20} />}
        </button>
        <div style={{ display: 'flex', flexDirection: 'column', flex: 1, marginLeft: 4 }}>
          <span style={{ font: '600 14px/18px var(--font-sans)', color: 'var(--fg-1)' }}>{voice}</span>
          <span style={{ font: '400 12px/14px var(--font-sans)', color: 'var(--fg-2)' }}>Just now · {mode.charAt(0).toUpperCase() + mode.slice(1)}</span>
        </div>
        <div className="vc-player-actions">
          <button className="vc-icon-btn" title="Save"><window.IconBookmark w={18} h={18} /></button>
          <button className="vc-icon-btn" title="Download"><window.IconDownload w={18} h={18} /></button>
          <button className="vc-icon-btn" title="Dismiss" onClick={onDismiss}>
            <window.IconClose w={18} h={18} />
          </button>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, { Studio, InlinePlayer });
