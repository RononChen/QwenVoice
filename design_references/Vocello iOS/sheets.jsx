// Sheets — Voice picker, Delivery picker, Recording overlay, Model install.

const { useState: useStateS, useEffect: useEffectS, useRef: useRefS } = React;

// — VOICE PICKER SHEET ——————————————————————————
function VoicePickerSheet({ open, onClose, selected, onSelect, mode = 'custom' }) {
  const [query, setQuery] = useStateS('');
  const [filter, setFilter] = useStateS('all');
  const [previewing, setPreviewing] = useStateS(null);
  const data = window.VOCELLO_DATA;

  // mode determines what's available
  let voices = [];
  if (mode === 'custom') {
    voices = data.builtInVoices;
  } else if (mode === 'clone') {
    voices = data.savedVoices;
  }

  // filter
  let filtered = voices;
  if (filter !== 'all') filtered = voices.filter(v => v.lang === filter || (filter === 'saved' && v.saved));
  if (query) filtered = filtered.filter(v =>
    v.name.toLowerCase().includes(query.toLowerCase()) ||
    v.desc.toLowerCase().includes(query.toLowerCase())
  );

  const recent = mode === 'custom'
    ? data.recent.map(id => voices.find(v => v.id === id)).filter(Boolean)
    : [];

  const togglePreview = (vid) => {
    setPreviewing(previewing === vid ? null : vid);
    setTimeout(() => setPreviewing(null), 1800);
  };

  return (
    <window.BottomSheet open={open} onClose={onClose} title={mode === 'clone' ? 'Saved voices' : 'Voice'}>
      <div className="vc-search" style={{ margin: '0 0 14px' }}>
        <window.IconSearch w={16} h={16} />
        <input value={query} onChange={e => setQuery(e.target.value)} placeholder="Search voices" />
      </div>

      {mode === 'custom' && (
        <div className="vc-filter-row" style={{ padding: '0 0 14px', margin: '0 -2px' }}>
          {[
            { id: 'all', label: 'All' },
            { id: 'EN', label: 'English' },
            { id: 'EN-UK', label: 'British' },
            { id: 'JA', label: 'Japanese' },
          ].map(f => (
            <button key={f.id} className="vc-filter-chip" data-active={filter === f.id}
              onClick={() => setFilter(f.id)}>{f.label}</button>
          ))}
        </div>
      )}

      {recent.length > 0 && filter === 'all' && !query && (
        <React.Fragment>
          <div style={{ font: '600 11px/14px var(--font-sans)', letterSpacing: '0.08em', textTransform: 'uppercase', color: 'var(--fg-2)', margin: '4px 0 6px' }}>Recently used</div>
          <div style={{ display: 'flex', gap: 10, paddingBottom: 16, marginBottom: 8, overflowX: 'auto', borderBottom: '0.5px solid rgba(255,255,255,0.06)' }}>
            {recent.map(v => (
              <button key={v.id} className="vc-tappable"
                onClick={() => { onSelect(v.id); onClose(); }}
                style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8, background: 'none', border: 'none', padding: 0, cursor: 'pointer', minWidth: 64 }}>
                <window.VoiceAvatar name={v.name} hue={v.hue} size="lg" />
                <span style={{ font: '500 12px/14px var(--font-sans)', color: 'var(--fg-1)' }}>{v.name}</span>
              </button>
            ))}
          </div>
        </React.Fragment>
      )}

      {filtered.length === 0 ? (
        <div style={{ padding: '32px 0', textAlign: 'center', color: 'var(--fg-2)' }}>No voices match.</div>
      ) : filtered.map(v => (
        <div key={v.id} className="vc-voice-row vc-tappable"
          onClick={() => { onSelect(v.id); onClose(); }}>
          <window.VoiceAvatar name={v.name} hue={v.hue} />
          <div className="vc-voice-meta">
            <div className="vc-voice-name">{v.name}</div>
            <div className="vc-voice-desc">{v.desc}</div>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <span className="vc-pill">{v.lang || 'Saved'}</span>
            <button className="vc-icon-btn" onClick={e => { e.stopPropagation(); togglePreview(v.id); }}>
              {previewing === v.id ? <window.IconPause w={16} h={16} /> : <window.IconPlay w={16} h={16} />}
            </button>
            {selected === v.id && (
              <div style={{ color: 'var(--vocello-gold)' }}><window.IconCheck w={20} h={20} /></div>
            )}
          </div>
        </div>
      ))}

      {mode === 'clone' && (
        <button className="vc-voice-row vc-tappable" style={{ width: '100%', border: 'none', background: 'none', padding: '14px 0', textAlign: 'left' }}>
          <div className="vc-avatar" style={{ background: 'rgba(255,255,255,0.06)', color: 'var(--fg-1)' }}>
            <window.IconImport w={20} h={20} />
          </div>
          <div className="vc-voice-meta">
            <div className="vc-voice-name">Import a recording</div>
            <div className="vc-voice-desc">10–20 s reference clip. Use clips you own.</div>
          </div>
          <window.IconChevronRight w={18} h={18} style={{ color: 'var(--fg-3)' }} />
        </button>
      )}
    </window.BottomSheet>
  );
}

// — DELIVERY PICKER ——————————————————————————
function DeliverySheet({ open, onClose, selected, onSelect, mode = 'custom' }) {
  const data = window.VOCELLO_DATA;
  const tint = window.modeColor(mode, 'dark');
  const [custom, setCustom] = useStateS('');

  return (
    <window.BottomSheet open={open} onClose={onClose} title="Delivery">
      <p style={{ font: '400 14px/19px var(--font-sans)', color: 'var(--fg-2)', margin: '0 0 16px' }}>
        Pick a preset or write your own performance direction. Try “calm and reassuring, slightly faster”.
      </p>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 10, marginBottom: 16 }}>
        {data.deliveries.map(d => {
          const active = selected === d.id;
          return (
            <button key={d.id}
              onClick={() => { onSelect(d.id); onClose(); }}
              style={{
                display: 'flex', flexDirection: 'column', alignItems: 'flex-start', gap: 4,
                padding: '12px 14px',
                borderRadius: 16,
                border: '0.5px solid ' + (active ? `color-mix(in oklch, ${d.color} 60%, transparent)` : 'rgba(255,255,255,0.10)'),
                background: active ? `color-mix(in oklch, ${d.color} 14%, rgba(255,255,255,0.02))` : 'rgba(255,255,255,0.03)',
                color: 'var(--fg-1)',
                cursor: 'pointer',
                textAlign: 'left',
              }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, width: '100%' }}>
                <div style={{ width: 8, height: 8, borderRadius: '50%', background: d.color }} />
                <span style={{ font: '600 14px/1 var(--font-sans)', flex: 1 }}>{d.name}</span>
                {active && <window.IconCheck w={16} h={16} style={{ color: d.color }} />}
              </div>
              <span style={{ font: '400 12px/15px var(--font-sans)', color: 'var(--fg-2)', textAlign: 'left' }}>{d.desc}</span>
            </button>
          );
        })}
      </div>

      <div style={{ font: '600 11px/14px var(--font-sans)', letterSpacing: '0.08em', textTransform: 'uppercase', color: 'var(--fg-2)', margin: '4px 0 8px' }}>Custom direction</div>
      <textarea
        value={custom}
        onChange={e => setCustom(e.target.value)}
        rows={2}
        placeholder="Calm and reassuring, while keeping words clear"
        style={{
          width: '100%',
          background: 'rgba(255,255,255,0.04)',
          border: '0.5px solid rgba(255,255,255,0.10)',
          borderRadius: 12,
          padding: '12px 14px',
          color: 'var(--fg-1)',
          font: '400 15px/20px var(--font-sans)',
          resize: 'none',
          outline: 'none',
        }} />
    </window.BottomSheet>
  );
}

// — RECORDING OVERLAY —————————————————————————
function RecordingOverlay({ open, onClose, onCapture }) {
  const [seconds, setSeconds] = useStateS(0);
  const [phase, setPhase] = useStateS('idle'); // idle | recording | done
  const [waveSeed, setWaveSeed] = useStateS(0);

  useEffectS(() => {
    if (!open) { setSeconds(0); setPhase('idle'); return; }
    if (phase === 'recording') {
      const tStart = Date.now();
      const id = setInterval(() => {
        const s = (Date.now() - tStart) / 1000;
        setSeconds(s);
        setWaveSeed(x => x + 1);
        if (s >= 25) { setPhase('done'); clearInterval(id); }
      }, 100);
      return () => clearInterval(id);
    }
  }, [open, phase]);

  if (!open) return null;

  const formatTime = (s) => {
    const m = Math.floor(s / 60).toString().padStart(2, '0');
    const sec = Math.floor(s % 60).toString().padStart(2, '0');
    return `${m}:${sec}`;
  };

  const inRange = seconds >= 10 && seconds <= 20;

  return (
    <div className="vc-recording">
      <div style={{ display: 'flex', width: '100%', justifyContent: 'flex-end' }}>
        <button className="vc-icon-btn" onClick={() => { setPhase('idle'); onClose(); }}>
          <window.IconClose w={18} h={18} />
        </button>
      </div>

      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 28 }}>
        <div style={{ font: '600 13px/16px var(--font-sans)', color: 'var(--fg-2)', textTransform: 'uppercase', letterSpacing: '0.12em' }}>
          {phase === 'idle' ? 'Reference clip' : phase === 'recording' ? 'Recording' : 'Captured'}
        </div>
        <div style={{ font: '700 56px/1 var(--font-mono)', letterSpacing: '-0.02em', color: phase === 'recording' && inRange ? 'var(--mode-cloning)' : 'var(--fg-1)' }}>
          {formatTime(seconds)}
        </div>
        <div style={{ font: '500 14px/19px var(--font-sans)', color: 'var(--fg-2)', textAlign: 'center', maxWidth: 280 }}>
          Read 10–20 s of clean, natural speech. Quiet room. One voice.
        </div>

        {/* big live waveform */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 3, height: 120, width: '100%', justifyContent: 'center' }}>
          {Array.from({ length: 42 }).map((_, i) => {
            const phaseOffset = phase === 'recording' ? Math.sin((waveSeed * 0.4 + i * 0.6)) * 0.5 + 0.5 : 0;
            const baseH = phase === 'recording' ? 0.2 + phaseOffset * 0.7 : 0.06;
            return (
              <div key={i} style={{
                width: 4, height: `${baseH * 100}%`,
                borderRadius: 2,
                background: phase === 'recording'
                  ? 'linear-gradient(180deg, var(--mode-cloning) 0%, color-mix(in oklch, var(--mode-cloning) 50%, transparent) 100%)'
                  : 'rgba(255,255,255,0.18)',
                transition: 'height 80ms linear',
              }} />
            );
          })}
        </div>
      </div>

      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 16, width: '100%' }}>
        {phase === 'idle' && (
          <button onClick={() => setPhase('recording')}
            style={{
              width: 84, height: 84, borderRadius: '50%',
              background: 'linear-gradient(180deg, #FF3B30 0%, #C5251A 100%)',
              border: '4px solid rgba(255,255,255,0.12)',
              color: '#fff',
              cursor: 'pointer',
              boxShadow: '0 12px 30px rgba(255,59,48,0.45)',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
            }}>
            <window.IconMic w={32} h={32} />
          </button>
        )}
        {phase === 'recording' && (
          <button onClick={() => setPhase('done')}
            style={{
              width: 84, height: 84, borderRadius: '50%',
              background: '#fff',
              border: '4px solid rgba(255,59,48,0.6)',
              cursor: 'pointer',
              display: 'flex', alignItems: 'center', justifyContent: 'center',
            }}>
            <div style={{ width: 28, height: 28, borderRadius: 6, background: '#FF3B30' }} />
          </button>
        )}
        {phase === 'done' && (
          <div style={{ display: 'flex', gap: 12, width: '100%' }}>
            <button className="vc-icon-btn" style={{ flex: 'none', height: 50, width: 50, borderRadius: 25 }}
              onClick={() => { setSeconds(0); setPhase('idle'); }}>
              <window.IconClose w={20} h={20} />
            </button>
            <button onClick={() => { onCapture(seconds); onClose(); }}
              style={{
                flex: 1, height: 50, borderRadius: 25,
                background: 'var(--mode-cloning)',
                border: 'none',
                color: '#0D0E12',
                font: '600 16px/1 var(--font-sans)',
                cursor: 'pointer',
              }}>
              Use this recording
            </button>
          </div>
        )}
      </div>
    </div>
  );
}

// — MODEL INSTALL SHEET ——————————————————————————
function ModelInstallSheet({ open, onClose, model, onInstall }) {
  const [progress, setProgress] = useStateS(0);
  const [installing, setInstalling] = useStateS(false);
  const [done, setDone] = useStateS(false);

  useEffectS(() => {
    if (!installing) return;
    let p = 0;
    const id = setInterval(() => {
      p += Math.random() * 4 + 1;
      if (p >= 100) { p = 100; setProgress(p); setDone(true); clearInterval(id); }
      else setProgress(p);
    }, 120);
    return () => clearInterval(id);
  }, [installing]);

  useEffectS(() => {
    if (done) {
      setTimeout(() => { onInstall(); setInstalling(false); setProgress(0); setDone(false); }, 800);
    }
  }, [done]);

  if (!model) return null;

  return (
    <window.BottomSheet open={open} onClose={onClose} title={installing ? 'Installing' : 'Install model'}>
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 16, marginBottom: 18 }}>
        <div className="vc-model-icon" style={{
          background: `color-mix(in oklch, ${model.modeColor || 'var(--vocello-gold)'} 88%, black)`,
          color: '#0D0E12',
          width: 56, height: 56, borderRadius: 16,
        }}>
          <window.IconBolt w={26} h={26} />
        </div>
        <div style={{ flex: 1 }}>
          {model.modeLabel && (
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 4 }}>
              <div style={{ width: 7, height: 7, borderRadius: '50%', background: model.modeColor, flexShrink: 0 }} />
              <span style={{ font: '600 11px/14px var(--font-sans)', letterSpacing: '0.06em', textTransform: 'uppercase', color: 'var(--fg-2)' }}>{model.modeLabel}</span>
            </div>
          )}
          <div style={{ font: '700 20px/24px var(--font-display)', letterSpacing: '-0.015em' }}>{model.name}</div>
          <div style={{ font: '400 13px/17px var(--font-sans)', color: 'var(--fg-2)', marginTop: 4 }}>{model.desc}</div>
          <div style={{ display: 'flex', gap: 8, marginTop: 8, flexWrap: 'wrap' }}>
            <span className="vc-pill">{model.size}</span>
            <span className="vc-pill" style={{ color: 'var(--status-ready)', background: 'rgba(48, 209, 88, 0.10)' }}>On-device</span>
          </div>
        </div>
      </div>

      <div style={{ background: 'rgba(255,255,255,0.03)', borderRadius: 14, padding: 14, marginBottom: 18 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 8 }}>
          <window.IconLock w={16} h={16} style={{ color: 'var(--status-ready)' }} />
          <span style={{ font: '600 13px/16px var(--font-sans)' }}>Stays on your iPhone</span>
        </div>
        <div style={{ font: '400 13px/18px var(--font-sans)', color: 'var(--fg-2)' }}>
          Downloaded from Hugging Face once. Generation, audio, and history never leave the device.
        </div>
      </div>

      {installing && (
        <div style={{ marginBottom: 16 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 8, font: '500 13px/16px var(--font-sans)', color: 'var(--fg-2)' }}>
            <span>{done ? 'Verifying' : 'Downloading'}</span>
            <span style={{ fontVariantNumeric: 'tabular-nums' }}>{Math.round(progress)}%</span>
          </div>
          <div style={{ height: 6, borderRadius: 3, background: 'rgba(255,255,255,0.08)', overflow: 'hidden' }}>
            <div style={{ height: '100%', background: 'linear-gradient(90deg, var(--vocello-gold) 0%, var(--mode-cloning) 100%)', width: `${progress}%`, transition: 'width 200ms linear' }} />
          </div>
        </div>
      )}

      <button
        onClick={() => !installing && setInstalling(true)}
        disabled={installing}
        className="vc-cta"
        style={{
          background: `linear-gradient(180deg, ${model.modeColor || 'var(--vocello-gold)'} 0%, color-mix(in oklch, ${model.modeColor || 'var(--vocello-gold)'} 80%, black) 100%)`,
          color: '#0D0E12',
          marginBottom: 12,
        }}>
        {installing ? (done ? 'Done' : 'Installing…') : 'Install'}
      </button>
    </window.BottomSheet>
  );
}

Object.assign(window, { VoicePickerSheet, DeliverySheet, RecordingOverlay, ModelInstallSheet });
