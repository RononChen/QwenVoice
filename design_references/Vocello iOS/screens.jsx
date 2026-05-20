// Voices tab — combined library of built-in speakers, saved voices, and models.

const { useState: useStateVc } = React;

function Voices({ onUseInClone, onPreviewVoice }) {
  const data = window.VOCELLO_DATA;
  const [filter, setFilter] = useStateVc('all');
  const [query, setQuery] = useStateVc('');

  const matches = (name, desc) =>
    !query
    || name.toLowerCase().includes(query.toLowerCase())
    || (desc || '').toLowerCase().includes(query.toLowerCase());

  const showBuiltIn = filter === 'all' || filter === 'builtin';
  const showSaved = filter === 'all' || filter === 'saved';

  return (
    <div className="vc-screen-body">
      <div className="vc-search" style={{ marginBottom: 10 }}>
        <window.IconSearch w={16} h={16} />
        <input value={query} onChange={e => setQuery(e.target.value)} placeholder="Search voices" />
      </div>

      <div className="vc-filter-row">
        {[
          { id: 'all',     label: 'All' },
          { id: 'builtin', label: 'Built-in' },
          { id: 'saved',   label: 'Saved' },
        ].map(f => (
          <button key={f.id} className="vc-filter-chip" data-active={filter === f.id}
            onClick={() => setFilter(f.id)}>{f.label}</button>
        ))}
      </div>

      {showSaved && (
        <React.Fragment>
          <div className="vc-voices-section-head">Your saved voices</div>
          {data.savedVoices.filter(v => matches(v.name, v.desc)).map(v => (
            <div key={v.id} className="vc-voice-card">
              <window.VoiceAvatar name={v.name} hue={v.hue} />
              <div className="vc-voice-meta">
                <div className="vc-voice-name">{v.name}</div>
                <div className="vc-voice-desc">{v.desc}</div>
              </div>
              <button className="vc-voice-card-play" onClick={() => onPreviewVoice && onPreviewVoice(v)}>
                <window.IconPlay w={16} h={16} />
              </button>
            </div>
          ))}
          {/* Empty add-card */}
          <button
            style={{
              display: 'flex', alignItems: 'center', gap: 12,
              margin: '0 16px 8px', padding: 14,
              borderRadius: 18,
              background: 'rgba(255,255,255,0.02)',
              border: '1px dashed rgba(255,255,255,0.12)',
              color: 'var(--fg-2)',
              cursor: 'pointer', width: 'calc(100% - 32px)',
            }}
            onClick={() => onUseInClone && onUseInClone(null)}
          >
            <div className="vc-avatar" style={{ background: 'rgba(255,255,255,0.06)', color: 'var(--mode-cloning)' }}>
              <window.IconPlus w={20} h={20} />
            </div>
            <div className="vc-voice-meta">
              <div className="vc-voice-name" style={{ color: 'var(--fg-1)' }}>Save a new voice</div>
              <div className="vc-voice-desc">Record a 10–20 s reference clip you own.</div>
            </div>
            <window.IconChevronRight w={18} h={18} style={{ color: 'var(--fg-3)' }} />
          </button>
        </React.Fragment>
      )}

      {showBuiltIn && (
        <React.Fragment>
          <div className="vc-voices-section-head">Built-in speakers</div>
          {data.builtInVoices.filter(v => matches(v.name, v.desc)).map(v => (
            <div key={v.id} className="vc-voice-card">
              <window.VoiceAvatar name={v.name} hue={v.hue} />
              <div className="vc-voice-meta">
                <div className="vc-voice-name">{v.name}</div>
                <div className="vc-voice-desc">{v.desc}</div>
              </div>
              <span className="vc-pill" style={{ marginRight: 8 }}>{v.lang}</span>
              <button className="vc-voice-card-play" onClick={() => onPreviewVoice && onPreviewVoice(v)}>
                <window.IconPlay w={16} h={16} />
              </button>
            </div>
          ))}
        </React.Fragment>
      )}

      {/* Empty state */}
      {filter === 'saved' && data.savedVoices.length === 0 && (
        <div style={{ padding: '60px 32px', textAlign: 'center' }}>
          <div className="vc-avatar" style={{ width: 64, height: 64, margin: '0 auto 16px', background: 'rgba(255,255,255,0.04)', color: 'var(--fg-2)' }}>
            <window.IconMic w={28} h={28} />
          </div>
          <div style={{ font: '600 17px/22px var(--font-sans)', marginBottom: 6 }}>No saved voices yet</div>
          <div style={{ font: '400 14px/19px var(--font-sans)', color: 'var(--fg-2)' }}>
            Record a clip in Studio to clone a voice for later.
          </div>
        </div>
      )}
    </div>
  );
}

// — HISTORY TAB ——————————————————————————
function History({ onPlay }) {
  const data = window.VOCELLO_DATA;
  const [filter, setFilter] = useStateVc('all');
  const [query, setQuery] = useStateVc('');

  let items = data.history;
  if (filter !== 'all') items = items.filter(h => h.mode === filter);
  if (query) items = items.filter(h => h.text.toLowerCase().includes(query.toLowerCase()) || h.voice.toLowerCase().includes(query.toLowerCase()));

  // Group by bucket
  const groups = items.reduce((acc, item) => {
    if (!acc[item.bucket]) acc[item.bucket] = [];
    acc[item.bucket].push(item);
    return acc;
  }, {});

  return (
    <div className="vc-screen-body">
      <div className="vc-search" style={{ marginBottom: 10 }}>
        <window.IconSearch w={16} h={16} />
        <input value={query} onChange={e => setQuery(e.target.value)} placeholder="Search transcript or voice" />
      </div>

      <div className="vc-filter-row">
        {[
          { id: 'all', label: 'All', dot: 'rgba(255,255,255,0.4)' },
          { id: 'custom', label: 'Custom', dot: window.MODE_HEX.custom },
          { id: 'design', label: 'Design', dot: window.MODE_HEX.design },
          { id: 'clone', label: 'Clone', dot: window.MODE_HEX.clone },
        ].map(f => (
          <button key={f.id} className="vc-filter-chip" data-active={filter === f.id}
            onClick={() => setFilter(f.id)}>
            <span className="vc-filter-chip-dot" style={{ background: f.dot }} />
            {f.label}
          </button>
        ))}
      </div>

      {items.length === 0 ? (
        <div style={{ padding: '60px 32px', textAlign: 'center' }}>
          <div className="vc-avatar" style={{ width: 64, height: 64, margin: '0 auto 16px', background: 'rgba(255,255,255,0.04)', color: 'var(--fg-2)' }}>
            <window.IconHistory w={28} h={28} />
          </div>
          <div style={{ font: '600 17px/22px var(--font-sans)', marginBottom: 6 }}>Nothing yet</div>
          <div style={{ font: '400 14px/19px var(--font-sans)', color: 'var(--fg-2)' }}>
            Audio you generate lands here, grouped by day.
          </div>
        </div>
      ) : (
        Object.entries(groups).map(([bucket, list]) => (
          <div key={bucket}>
            <div className="vc-history-section-head">{bucket}</div>
            {list.map(h => (
              <div key={h.id} className="vc-history-row" onClick={() => onPlay && onPlay(h)}>
                <div className="vc-history-thumb"
                  style={{ background: `color-mix(in oklch, ${window.MODE_HEX[h.mode]} 14%, rgba(255,255,255,0.02))` }}>
                  <window.MiniWaveform seed={parseInt(h.id.slice(1)) * 11} color={window.MODE_HEX[h.mode]} bars={14} />
                </div>
                <div className="vc-history-text">
                  <div className="vc-history-snippet">{h.text}</div>
                  <div className="vc-history-meta">
                    <window.ModeDot mode={h.mode} />
                    <span>{h.voice}</span>
                    <span>·</span>
                    <span>{h.time}</span>
                    <span>·</span>
                    <span style={{ fontVariantNumeric: 'tabular-nums' }}>{h.duration.toFixed(1)}s</span>
                  </div>
                </div>
                <button className="vc-icon-btn" style={{ width: 32, height: 32 }} onClick={(e) => { e.stopPropagation(); }}>
                  <window.IconDots w={16} h={16} />
                </button>
              </div>
            ))}
          </div>
        ))
      )}
    </div>
  );
}

// — SETTINGS TAB ——————————————————————————
function SettingsTab({ onInstallModel, onDeleteModel }) {
  const [reduceMotion, setReduceMotion] = useStateVc(false);
  const [reduceTransp, setReduceTransp] = useStateVc(false);
  const [autoPlay, setAutoPlay] = useStateVc(true);
  const data = window.VOCELLO_DATA;

  return (
    <div className="vc-screen-body">
      {/* Voice engines — one model per mode, tight list rows */}
      <div className="vc-list-head">Voice models</div>
      <div className="vc-list-group">
        {data.models.map((model, i) => {
          const status = model.active ? 'active' : model.installed ? 'installed' : 'missing';
          const ModeIcon = ({ custom: window.IconMic, design: window.IconWand, clone: window.IconWaveform })[model.mode];
          return (
            <div key={model.id} className="vc-list-row vc-tappable"
              style={{ padding: '10px 14px' }}
              onClick={() => onInstallModel(model)}>
              <div className="vc-list-icon" style={{
                width: 36, height: 36, borderRadius: 10,
                background: `color-mix(in oklch, ${model.modeColor} 16%, rgba(255,255,255,0.02))`,
                border: `0.5px solid color-mix(in oklch, ${model.modeColor} 38%, transparent)`,
                color: model.modeColor,
              }}>
                <ModeIcon w={18} h={18} />
              </div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ font: '600 15px/19px var(--font-sans)', letterSpacing: '-0.005em', color: 'var(--fg-1)' }}>
                  {model.modeLabel}
                </div>
                <div style={{
                  display: 'flex', alignItems: 'center', gap: 6, marginTop: 2,
                  font: '400 12px/15px var(--font-sans)', color: 'var(--fg-2)',
                }}>
                  <span>4-bit Speed</span>
                  <span>·</span>
                  <span style={{ fontVariantNumeric: 'tabular-nums' }}>{model.size}</span>
                  {status === 'active' && (
                    <React.Fragment>
                      <span>·</span>
                      <span style={{ color: model.modeColor, fontWeight: 600 }}>Active</span>
                    </React.Fragment>
                  )}
                </div>
              </div>
              {status === 'missing' ? (
                <button className="vc-model-action"
                  style={{
                    background: 'transparent',
                    border: `0.5px solid color-mix(in oklch, ${model.modeColor} 48%, transparent)`,
                    color: model.modeColor,
                    height: 36, padding: '0 16px',
                    fontSize: 14,
                  }}
                  onClick={(e) => { e.stopPropagation(); onInstallModel(model); }}>
                  Install
                </button>
              ) : (
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <window.IconCircleCheck w={22} h={22} style={{ color: 'var(--status-ready)' }} />
                  <button
                    onClick={(e) => { e.stopPropagation(); onDeleteModel(model); }}
                    aria-label={`Delete ${model.modeLabel} model`}
                    style={{
                      width: 36, height: 36, borderRadius: 18,
                      display: 'flex', alignItems: 'center', justifyContent: 'center',
                      background: 'rgba(255,255,255,0.04)',
                      border: '0.5px solid rgba(255,255,255,0.10)',
                      color: 'var(--fg-2)',
                      cursor: 'pointer',
                      transition: 'background 160ms, color 160ms, border-color 160ms',
                    }}
                    onMouseEnter={(e) => {
                      e.currentTarget.style.background = 'rgba(255, 69, 58, 0.10)';
                      e.currentTarget.style.borderColor = 'rgba(255, 69, 58, 0.40)';
                      e.currentTarget.style.color = 'var(--status-error)';
                    }}
                    onMouseLeave={(e) => {
                      e.currentTarget.style.background = 'rgba(255,255,255,0.04)';
                      e.currentTarget.style.borderColor = 'rgba(255,255,255,0.10)';
                      e.currentTarget.style.color = 'var(--fg-2)';
                    }}
                  >
                    <window.IconTrash w={17} h={17} />
                  </button>
                </div>
              )}
            </div>
          );
        })}
      </div>

      <div className="vc-list-head">Settings</div>
      <div className="vc-list-group">
        <div className="vc-list-row">
          <div className="vc-list-icon vc-list-icon--utility"><window.IconPlay w={18} h={18} /></div>
          <div className="vc-list-title">Autoplay after generate</div>
          <div className="vc-toggle" data-on={autoPlay} onClick={() => setAutoPlay(!autoPlay)}>
            <div className="vc-toggle-knob" />
          </div>
        </div>
        <div className="vc-list-row">
          <div className="vc-list-icon vc-list-icon--utility"><window.IconBookmark w={18} h={18} /></div>
          <div className="vc-list-title">Saved outputs</div>
          <span className="vc-list-value">On My iPhone</span>
          <window.IconChevronRight w={16} h={16} style={{ color: 'var(--fg-3)', marginLeft: 4 }} />
        </div>
        <div className="vc-list-row">
          <div className="vc-list-icon vc-list-icon--utility"><window.IconDownload w={18} h={18} /></div>
          <div className="vc-list-title">Storage</div>
          <span className="vc-list-value">4.6 GB used</span>
          <window.IconChevronRight w={16} h={16} style={{ color: 'var(--fg-3)', marginLeft: 4 }} />
        </div>
        <div className="vc-list-row">
          <div className="vc-list-icon vc-list-icon--utility"><window.IconSparkles w={18} h={18} /></div>
          <div className="vc-list-title">Reduce Motion</div>
          <div className="vc-toggle" data-on={reduceMotion} onClick={() => setReduceMotion(!reduceMotion)}>
            <div className="vc-toggle-knob" />
          </div>
        </div>
        <div className="vc-list-row">
          <div className="vc-list-icon vc-list-icon--utility"><window.IconLock w={18} h={18} /></div>
          <div className="vc-list-title">Reduce Transparency</div>
          <div className="vc-toggle" data-on={reduceTransp} onClick={() => setReduceTransp(!reduceTransp)}>
            <div className="vc-toggle-knob" />
          </div>
        </div>
      </div>

      <div style={{
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        padding: '6px 20px 2px',
        gap: 2,
        opacity: 0.78,
      }}>
        <img src="assets/vocello_launch_logo.png"
          alt="Vocello"
          style={{
            width: 180,
            height: 'auto',
            display: 'block',
            filter: 'drop-shadow(0 10px 28px rgba(237, 204, 138, 0.18))',
          }} />
        <div style={{
          font: '500 11px/14px var(--font-sans)',
          color: 'var(--fg-3)',
          letterSpacing: '0.06em',
          textTransform: 'uppercase',
        }}>
          Version 2.0
        </div>
      </div>

      <div style={{ height: 40 }} />
    </div>
  );
}

// — ONBOARDING ——————————————————————————
function Onboarding({ onDone }) {
  const [step, setStep] = useStateVc(0);
  const [progress, setProgress] = useStateVc(0);
  const [downloading, setDownloading] = useStateVc(false);

  React.useEffect(() => {
    if (!downloading) return;
    let p = 0;
    const id = setInterval(() => {
      p += Math.random() * 4 + 1.5;
      if (p >= 100) { p = 100; clearInterval(id); setProgress(100); setTimeout(() => setStep(2), 600); }
      else setProgress(p);
    }, 110);
    return () => clearInterval(id);
  }, [downloading]);

  const screens = [
    {
      title: 'Vocello',
      sub: 'Studio-quality voice generation. Runs entirely on this iPhone.',
      cta: 'Get started',
      onCta: () => setStep(1),
    },
    {
      title: 'Install Custom Voice',
      sub: 'Download the 4-bit Speed model (1.6 GB) to start generating. Voice Design and Voice Cloning each have their own model — install them later in Settings.',
      cta: downloading ? 'Downloading…' : 'Install',
      onCta: () => !downloading && setDownloading(true),
      disabled: downloading,
    },
    {
      title: "You're ready",
      sub: 'Type a script, pick a voice, generate. Your audio stays here.',
      cta: 'Open Studio',
      onCta: onDone,
    },
  ];

  const s = screens[step];

  return (
    <div className="vc-onboard">
      <div className="vc-onboard-body">
        <div style={{
          width: 96, height: 96, borderRadius: 24,
          background: step === 0
            ? 'linear-gradient(135deg, var(--vocello-gold) 0%, var(--mode-cloning) 100%)'
            : step === 1
              ? 'linear-gradient(135deg, var(--mode-design) 0%, var(--vocello-gold) 100%)'
              : 'linear-gradient(135deg, var(--mode-cloning) 0%, var(--mode-design) 100%)',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          color: '#0D0E18',
          boxShadow: '0 12px 36px rgba(237, 204, 138, 0.30)',
        }}>
          {step === 0 && <window.IconSparkles w={48} h={48} />}
          {step === 1 && <window.IconDownload w={48} h={48} />}
          {step === 2 && <window.IconCircleCheck w={48} h={48} />}
        </div>

        <div className="vc-onboard-title">{s.title}</div>
        <div className="vc-onboard-sub">{s.sub}</div>

        {step === 1 && downloading && (
          <div style={{ marginTop: 36, width: 280 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 8, font: '500 13px/16px var(--font-sans)', color: 'var(--fg-2)' }}>
              <span>Custom Voice · 4-bit Speed</span>
              <span style={{ fontVariantNumeric: 'tabular-nums' }}>{Math.round(progress)}%</span>
            </div>
            <div style={{ height: 6, borderRadius: 3, background: 'rgba(255,255,255,0.08)', overflow: 'hidden' }}>
              <div style={{ height: '100%', background: 'linear-gradient(90deg, var(--vocello-gold) 0%, var(--mode-cloning) 100%)', width: `${progress}%`, transition: 'width 200ms linear' }} />
            </div>
          </div>
        )}

        {step === 0 && (
          <div style={{ marginTop: 32, display: 'flex', flexDirection: 'column', gap: 12, width: 280, color: 'var(--fg-2)' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, font: '500 14px/18px var(--font-sans)' }}>
              <window.IconLock w={16} h={16} style={{ color: 'var(--status-ready)' }} /> Nothing leaves your device
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, font: '500 14px/18px var(--font-sans)' }}>
              <window.IconBolt w={16} h={16} style={{ color: 'var(--vocello-gold)' }} /> Generation in seconds
            </div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, font: '500 14px/18px var(--font-sans)' }}>
              <window.IconMic w={16} h={16} style={{ color: 'var(--mode-cloning)' }} /> Clone, design, or pick a voice
            </div>
          </div>
        )}
      </div>

      <div style={{ padding: '0 24px 40px', display: 'flex', flexDirection: 'column', gap: 16, alignItems: 'center' }}>
        <div className="vc-onboard-dots">
          {[0, 1, 2].map(i => <div key={i} className="vc-onboard-dot" data-active={i === step} />)}
        </div>
        <button onClick={s.onCta} disabled={s.disabled}
          className="vc-cta"
          style={{
            width: '100%',
            background: 'linear-gradient(180deg, var(--vocello-gold) 0%, color-mix(in oklch, var(--vocello-gold) 80%, black) 100%)',
            color: '#0D0E18',
          }}>
          {s.cta}
        </button>
      </div>
    </div>
  );
}

Object.assign(window, { Voices, History, SettingsTab, Onboarding });
