// Full-screen audio player sheet — opens from History rows, Voices preview,
// and tapping the Studio inline player to expand.

const { useState: useStatePl, useEffect: useEffectPl, useRef: useRefPl } = React;

function PlayerSheet({ open, onClose, item }) {
  const [render, setRender] = useStatePl(open);
  const [playing, setPlaying] = useStatePl(false);
  const [progress, setProgress] = useStatePl(0);
  const [waveSeed, setWaveSeed] = useStatePl(0);
  const startedAtRef = useRefPl(null);

  // Mount/unmount with exit animation
  useEffectPl(() => {
    if (open) {
      setRender(true);
      setProgress(0);
      setPlaying(true);
    } else {
      const t = setTimeout(() => {
        setRender(false);
        setPlaying(false);
        setProgress(0);
      }, 380);
      return () => clearTimeout(t);
    }
  }, [open, item?.id]);

  // Playback timer
  useEffectPl(() => {
    if (!playing || !item) return;
    const duration = item.duration || 6;
    startedAtRef.current = Date.now() - progress * duration * 1000;
    const id = setInterval(() => {
      const p = (Date.now() - startedAtRef.current) / 1000 / duration;
      if (p >= 1) { setProgress(1); setPlaying(false); clearInterval(id); return; }
      setProgress(p);
      setWaveSeed(s => s + 1);
    }, 60);
    return () => clearInterval(id);
  }, [playing, item?.id]);

  if (!render || !item) return null;

  const mode = item.mode || 'custom';
  const tint = window.MODE_HEX[mode] || window.MODE_HEX.custom;
  const modeLabel = ({ custom: 'Custom Voice', design: 'Voice Design', clone: 'Voice Cloning' })[mode];
  const duration = item.duration || 6;

  const fmt = (s) => {
    const m = Math.floor(s / 60);
    const sec = Math.floor(s % 60);
    return `${m}:${sec.toString().padStart(2, '0')}`;
  };

  const onScrubStart = (e) => {
    const rect = e.currentTarget.getBoundingClientRect();
    const setFromX = (x) => {
      const p = Math.max(0, Math.min(1, (x - rect.left) / rect.width));
      setProgress(p);
      if (playing) startedAtRef.current = Date.now() - p * duration * 1000;
    };
    setFromX(e.clientX);
    const move = (ev) => setFromX(ev.clientX);
    const up = () => {
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', up);
    };
    window.addEventListener('pointermove', move);
    window.addEventListener('pointerup', up);
  };

  const togglePlay = () => {
    if (progress >= 1) setProgress(0);
    setPlaying(p => !p);
  };

  // Build transcript with current-word highlight
  const words = (item.text || '').split(/(\s+)/);
  const totalWords = words.filter(w => w.trim()).length;
  const currentWordIndex = Math.floor(progress * totalWords);
  let wordCounter = 0;

  return (
    <React.Fragment>
      <div className="vc-player-sheet-backdrop" data-open={open} onClick={onClose} />
      <div className="vc-player-sheet" data-open={open}>
        {/* Mode-tinted radial wash behind everything */}
        <div className="vc-player-sheet-wash"
          style={{
            background: `radial-gradient(120% 70% at 50% 0%, color-mix(in oklch, ${tint} 38%, transparent) 0%, transparent 65%)`,
          }} />

        <div className="vc-player-sheet-head">
          <div className="vc-sheet-grabber" />
          <div className="vc-player-sheet-toolbar">
            <button className="vc-icon-btn" onClick={onClose} aria-label="Close">
              <window.IconChevronDown w={18} h={18} />
            </button>
            <div className="vc-player-sheet-eyebrow">
              <div className="vc-history-mode-dot" style={{ background: tint }} />
              <span>{modeLabel}</span>
            </div>
            <div style={{ width: 40 }} />
          </div>
        </div>

        <div className="vc-player-sheet-body">
          {/* Big animated waveform — the "art" */}
          <div className="vc-player-sheet-art">
            <BigWaveform tint={tint} playing={playing} progress={progress} seed={waveSeed} bars={42} />
          </div>

          {/* Voice + timestamp */}
          <div className="vc-player-sheet-meta">
            <div className="vc-player-sheet-voice">{item.voice}</div>
            <div className="vc-player-sheet-time-label">{item.timeLabel || 'Just now'} · {fmt(duration)}</div>
          </div>

          {/* Transcript with karaoke-style highlight */}
          {item.text && (
            <div className="vc-player-sheet-transcript">
              {words.map((w, i) => {
                if (!w.trim()) return <React.Fragment key={i}>{w}</React.Fragment>;
                const isCurrent = wordCounter === currentWordIndex && playing;
                const isPast = wordCounter < currentWordIndex;
                wordCounter++;
                return (
                  <span key={i}
                    style={{
                      color: isCurrent ? tint : isPast ? 'var(--fg-1)' : 'var(--fg-3)',
                      transition: 'color 200ms var(--ease-out)',
                      textShadow: isCurrent ? `0 0 12px color-mix(in oklch, ${tint} 50%, transparent)` : 'none',
                    }}>{w}</span>
                );
              })}
            </div>
          )}
        </div>

        <div className="vc-player-sheet-foot">
          {/* Scrubber */}
          <div className="vc-player-scrub-row">
            <div className="vc-player-scrub" onPointerDown={onScrubStart}>
              <div className="vc-player-scrub-track" />
              <div className="vc-player-scrub-fill"
                style={{
                  width: `${progress * 100}%`,
                  background: `linear-gradient(90deg, color-mix(in oklch, ${tint} 80%, black) 0%, ${tint} 100%)`,
                }} />
              <div className="vc-player-scrub-thumb"
                style={{
                  left: `${progress * 100}%`,
                  borderColor: tint,
                }} />
            </div>
            <div className="vc-player-scrub-times">
              <span>{fmt(progress * duration)}</span>
              <span>{fmt(duration)}</span>
            </div>
          </div>

          {/* Controls */}
          <div className="vc-player-sheet-controls">
            <button className="vc-player-side-btn" onClick={() => alert('Saved')}>
              <window.IconBookmark w={20} h={20} />
              <span>Save</span>
            </button>
            <button className="vc-player-sheet-play"
              style={{
                background: `linear-gradient(180deg, ${tint} 0%, color-mix(in oklch, ${tint} 78%, black) 100%)`,
                boxShadow: `0 12px 28px color-mix(in oklch, ${tint} 40%, transparent), inset 0 1px 0 rgba(255,255,255,0.25)`,
              }}
              onClick={togglePlay}>
              {playing ? <window.IconPause w={28} h={28} /> : <window.IconPlay w={28} h={28} />}
            </button>
            <button className="vc-player-side-btn" onClick={() => alert('Downloaded')}>
              <window.IconDownload w={20} h={20} />
              <span>Download</span>
            </button>
          </div>
        </div>
      </div>
    </React.Fragment>
  );
}

// Big animated waveform — pulses while playing, fills as progress advances
function BigWaveform({ tint, playing, progress, seed, bars = 42 }) {
  const heights = React.useMemo(() => {
    return Array.from({ length: bars }, (_, i) => {
      const s = Math.sin(i * 6.7) * 0.45 + 0.5;
      return Math.max(0.15, Math.min(0.95, Math.abs(s)));
    });
  }, [bars]);

  return (
    <div className="vc-big-wave">
      {heights.map((h, i) => {
        const played = (i / bars) <= progress;
        // Pulse modulation while playing
        const pulse = playing
          ? 1 + Math.sin((seed * 0.5 + i * 0.7)) * 0.18 + Math.sin((seed * 0.3 + i * 1.4)) * 0.10
          : 1;
        const finalH = Math.max(0.06, Math.min(1, h * pulse));
        return (
          <div key={i} className="vc-big-wave-bar"
            style={{
              height: `${finalH * 100}%`,
              background: played
                ? `linear-gradient(180deg, ${tint} 0%, color-mix(in oklch, ${tint} 60%, transparent) 100%)`
                : 'rgba(255,255,255,0.14)',
              opacity: played ? 1 : 0.65,
              transition: 'height 80ms linear',
            }} />
        );
      })}
    </div>
  );
}

Object.assign(window, { PlayerSheet });
