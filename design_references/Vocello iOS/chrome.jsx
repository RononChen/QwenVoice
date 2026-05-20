// Shared chrome components for the Vocello iOS prototype.
// Tab dock, mode segmented, screen scaffold, status bar pad, etc.

const { useState, useRef, useEffect, useLayoutEffect } = React;

// — Mode helpers —————————————————————————
const MODE_META = {
  custom: { id: 'custom', name: 'Custom',  desc: 'Built-in speaker', color: 'var(--mode-custom)',  hue: 35,  fgOnAccent: 'rgba(13,14,18,0.95)' },
  design: { id: 'design', name: 'Design',  desc: 'Describe a voice',  color: 'var(--mode-design)',  hue: 270, fgOnAccent: 'rgba(13,14,18,0.95)' },
  clone:  { id: 'clone',  name: 'Clone',   desc: 'From a recording',  color: 'var(--mode-cloning)', hue: 18,  fgOnAccent: 'rgba(13,14,18,0.95)' },
};
const MODE_HEX = {
  custom: '#EDCC8A',
  design: '#BFAADC',
  clone:  '#DBA887',
};

function modeColor(mode) {
  return MODE_HEX[mode];
}

// — Top mode segmented (3 segments slider) —————————————————————————
function ModeSegmented({ mode, onChange, modes = ['custom', 'design', 'clone'] }) {
  const wrapRef = useRef(null);
  const [pill, setPill] = useState({ x: 0, w: 0 });

  useLayoutEffect(() => {
    const el = wrapRef.current?.querySelector(`[data-mode="${mode}"]`);
    if (!el) return;
    const parent = wrapRef.current.getBoundingClientRect();
    const rect = el.getBoundingClientRect();
    setPill({ x: rect.left - parent.left, w: rect.width });
  }, [mode, modes.length]);

  const color = modeColor(mode);
  return (
    <div className="vc-mode-bar">
      <div className="vc-mode-segmented" ref={wrapRef}>
        <div className="vc-mode-pill"
          style={{
            transform: `translateX(${pill.x - 4}px)`,
            width: pill.w,
            background: `color-mix(in oklch, ${color} 22%, transparent)`,
            borderColor: `color-mix(in oklch, ${color} 36%, transparent)`,
          }} />
        {modes.map(m => (
          <button key={m} data-mode={m} data-active={mode === m}
            className="vc-mode-segment"
            onClick={() => onChange(m)}>
            {MODE_META[m].name}
          </button>
        ))}
      </div>
    </div>
  );
}

// — Tab dock —————————————————————————
const TAB_ACCENTS = {
  studio:   null,       // dynamic — uses current generation mode color
  voices:   '#8AB0C8',  // soft cool dusty blue — refined library
  history:  '#BFA0AB',  // muted dusty rose — distinct from the gold/terracotta warm family
  settings: '#A1A8B8',  // cool slate neutral
};

function TabDock({ tab, onChange, mode }) {
  const tabs = [
    { id: 'studio',   label: 'Studio',   Icon: window.IconStudio },
    { id: 'voices',   label: 'Voices',   Icon: window.IconVoices },
    { id: 'history',  label: 'History',  Icon: window.IconHistory },
    { id: 'settings', label: 'Settings', Icon: window.IconSettings },
  ];
  const accentFor = (t) => t.id === 'studio' ? modeColor(mode) : TAB_ACCENTS[t.id];

  return (
    <div className="vc-tab-dock-wrap">
      <div className="vc-tab-dock">
        {tabs.map(t => {
          const active = tab === t.id;
          const accent = accentFor(t);
          return (
            <button key={t.id} className="vc-tab-btn" data-active={active}
              onClick={() => onChange(t.id)}
              style={active ? { color: accent } : undefined}>
              {active && (
                <div className="vc-tab-btn-pill"
                  style={{
                    borderColor: `color-mix(in oklch, ${accent} 38%, transparent)`,
                    background: `color-mix(in oklch, ${accent} 12%, rgba(255,255,255,0.02))`,
                  }} />
              )}
              <div className="vc-tab-btn-inner">
                <t.Icon w={22} h={22} />
                <span>{t.label}</span>
              </div>
            </button>
          );
        })}
      </div>
    </div>
  );
}

// — Mode backdrop wash —————————————————————————
function ModeBackdrop({ mode, intensity = 'warm', color }) {
  const c = color || window.modeColor(mode);
  return (
    <div className={`vc-mode-backdrop intensity-${intensity}`}
      style={{
        background: `radial-gradient(120% 80% at 50% 0%, color-mix(in oklch, ${c} 24%, transparent) 0%, transparent 60%)`,
      }} />
  );
}

// — Generic bottom sheet —————————————————————————
function BottomSheet({ open, onClose, title, children, height }) {
  const [render, setRender] = useState(open);
  useEffect(() => {
    if (open) setRender(true);
    else {
      const t = setTimeout(() => setRender(false), 380);
      return () => clearTimeout(t);
    }
  }, [open]);

  if (!render) return null;

  return (
    <React.Fragment>
      <div className="vc-sheet-backdrop" data-open={open} onClick={onClose} />
      <div className="vc-sheet" data-open={open} style={height ? { maxHeight: height } : null}>
        <div className="vc-sheet-grabber" />
        <div className="vc-sheet-head">
          <div className="vc-sheet-title">{title}</div>
          <button className="vc-icon-btn" onClick={onClose} aria-label="Close">
            <window.IconClose w={18} h={18} />
          </button>
        </div>
        <div className="vc-sheet-body">
          {children}
        </div>
      </div>
    </React.Fragment>
  );
}

// — Avatar with mode-color gradient —————————————————————————
function VoiceAvatar({ name, hue = 35, size = 'md', children }) {
  // Generate a gentle 2-stop gradient from the hue
  const c1 = `oklch(78% 0.13 ${hue})`;
  const c2 = `oklch(64% 0.13 ${hue + 18})`;
  const initial = (name || '').split(' ').map(s => s[0]).slice(0, 2).join('').toUpperCase();
  return (
    <div className={`vc-avatar ${size === 'lg' ? 'size-lg' : ''}`}
      style={{ background: `linear-gradient(135deg, ${c1} 0%, ${c2} 100%)` }}>
      {children || initial}
    </div>
  );
}

// — Mini waveform thumb (history rows) —————————————————————————
function MiniWaveform({ seed = 0, color = 'currentColor', bars = 18 }) {
  // Deterministic pseudo-random heights based on seed
  const heights = Array.from({ length: bars }, (_, i) => {
    const s = Math.sin((seed * 13 + i * 7.31) * 1.3) * 0.4 + 0.5;
    const v = Math.max(0.16, Math.min(0.95, Math.abs(s) + (i % 5) * 0.08));
    return v;
  });
  return (
    <div className="vc-mini-wave">
      {heights.map((h, i) => (
        <div key={i} className="vc-mini-wave-bar"
          style={{ height: `${h * 100}%`, background: color, opacity: 0.4 + h * 0.5 }} />
      ))}
    </div>
  );
}

// — Inline waveform (player) —————————————————————————
function PlayerWaveform({ progress = 0, accent = '#EDCC8A', bars = 38, seed = 1 }) {
  const heights = Array.from({ length: bars }, (_, i) => {
    const s = Math.sin((seed * 11 + i * 6.7) * 1.6) * 0.45 + 0.5;
    const v = Math.max(0.12, Math.min(0.96, Math.abs(s)));
    return v;
  });
  return (
    <div className="vc-player-waveform">
      {heights.map((h, i) => {
        const played = (i / bars) <= progress;
        return (
          <div key={i} className="vc-wave-bar"
            style={{
              height: `${h * 100}%`,
              background: played
                ? `linear-gradient(180deg, ${accent} 0%, color-mix(in oklch, ${accent} 70%, transparent) 100%)`
                : undefined,
              opacity: played ? 1 : 0.55,
            }} />
        );
      })}
    </div>
  );
}

// — Mode dot (history meta) —————————————————————————
function ModeDot({ mode }) {
  return <div className="vc-history-mode-dot" style={{ background: MODE_HEX[mode] }} />;
}

Object.assign(window, {
  MODE_META, MODE_HEX, modeColor,
  ModeSegmented, TabDock, ModeBackdrop, BottomSheet, VoiceAvatar,
  MiniWaveform, PlayerWaveform, ModeDot,
});
