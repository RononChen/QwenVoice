// Hand-drawn SF-Symbol-mimic icons.
// Per design system: SF Symbols on the real app — we approximate with 1.4–1.6 px
// rounded-cap strokes. Always 24×24 viewBox.

const Icon = ({ d, w = 24, h = 24, s = 1.6, fill = 'none', stroke = 'currentColor', stroked = true, style = {}, children }) => (
  <svg width={w} height={h} viewBox="0 0 24 24" fill="none" style={{ display: 'block', flexShrink: 0, ...style }}>
    {children || (
      <path d={d}
        stroke={stroked ? stroke : 'none'}
        fill={stroked ? 'none' : (fill === 'none' ? 'currentColor' : fill)}
        strokeWidth={s} strokeLinecap="round" strokeLinejoin="round" />
    )}
  </svg>
);

// — Tabs
const IconStudio = (p) => (
  <Icon {...p}>
    {/* Audio waveform — 5 rounded vertical bars rising to a peak at center.
        The Studio tab is where you compose; the symbol is sound itself. */}
    <path d="M4 9.5v5 M8 6.5v11 M12 4v16 M16 6.5v11 M20 9.5v5"
      stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" fill="none"/>
  </Icon>
);
const IconVoices = (p) => (
  <Icon {...p}>
    {/* Two stylized speaker silhouettes */}
    <circle cx="9" cy="8.5" r="3.2" stroke="currentColor" strokeWidth="1.6" fill="none"/>
    <path d="M3.2 19.5c.5-3 3-4.8 5.8-4.8s5.3 1.8 5.8 4.8"
      stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" fill="none"/>
    <circle cx="17" cy="7" r="2.4" stroke="currentColor" strokeWidth="1.6" fill="none"/>
    <path d="M15.3 13c1.8.3 3.2 1.6 3.7 3.3"
      stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" fill="none"/>
  </Icon>
);
const IconHistory = (p) => (
  <Icon {...p}>
    {/* Clock with rewind hint */}
    <path d="M4.5 8.5a8 8 0 1 1-1.2 4"
      stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" fill="none"/>
    <path d="M3.2 4v4.5h4.5"
      stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" fill="none"/>
    <path d="M12 7.5v4.8l3 1.9"
      stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" fill="none"/>
  </Icon>
);
const IconSettings = (p) => (
  <Icon {...p}>
    {/* 6-tooth gearshape, scaled up to match Studio/Voices/History weight */}
    <path d="M10.65 6.15L9.98 3.23L14.02 3.23L13.35 6.15A6 6 0 0 1 16.39 7.91L18.58 5.86L20.61 9.37L17.74 10.25A6 6 0 0 1 17.74 13.75L20.61 14.63L18.58 18.14L16.39 16.09A6 6 0 0 1 13.35 17.85L14.02 20.77L9.98 20.77L10.65 17.85A6 6 0 0 1 7.61 16.09L5.42 18.14L3.39 14.63L6.26 13.75A6 6 0 0 1 6.26 10.25L3.39 9.37L5.42 5.86L7.61 7.91A6 6 0 0 1 10.65 6.15Z"
      stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round" fill="none"/>
    <circle cx="12" cy="12" r="2.8" stroke="currentColor" strokeWidth="1.6" fill="none"/>
  </Icon>
);

// — Generate / playback
const IconPlay = (p) => <Icon {...p}><path d="M7 5.5v13l11-6.5-11-6.5z" fill="currentColor" stroke="none"/></Icon>;
const IconPause = (p) => <Icon {...p}><rect x="7" y="5" width="3.4" height="14" rx="1" fill="currentColor"/><rect x="13.6" y="5" width="3.4" height="14" rx="1" fill="currentColor"/></Icon>;
const IconSparkles = (p) => (
  <Icon {...p}>
    <path d="M12 4.5l1.4 3.6 3.6 1.4-3.6 1.4L12 14.5l-1.4-3.6L7 9.5l3.6-1.4L12 4.5z" stroke="currentColor" strokeWidth="1.5" strokeLinejoin="round" fill="none"/>
    <path d="M18.6 14.2l.6 1.6 1.6.6-1.6.6-.6 1.6-.6-1.6-1.6-.6 1.6-.6.6-1.6z" fill="currentColor"/>
    <path d="M5.4 16.4l.4 1.1 1.1.4-1.1.4-.4 1.1-.4-1.1-1.1-.4 1.1-.4.4-1.1z" fill="currentColor"/>
  </Icon>
);
const IconStop = (p) => <Icon {...p}><rect x="6.5" y="6.5" width="11" height="11" rx="2" fill="currentColor"/></Icon>;
const IconMic = (p) => (
  <Icon {...p}>
    <rect x="9" y="3" width="6" height="11" rx="3" stroke="currentColor" strokeWidth="1.5" fill="none"/>
    <path d="M5.5 11a6.5 6.5 0 0 0 13 0" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" fill="none"/>
    <path d="M12 17.5V21M9 21h6" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" fill="none"/>
  </Icon>
);
const IconWand = (p) => (
  <Icon {...p}>
    <path d="M6 18l11-11" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" fill="none"/>
    <path d="M16 6l2 2" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" fill="none"/>
    <path d="M19 4l.5 1.5L21 6l-1.5.5L19 8l-.5-1.5L17 6l1.5-.5L19 4z" fill="currentColor"/>
    <path d="M4 4l.4 1.2L5.6 5.6l-1.2.4L4 7.2l-.4-1.2L2.4 5.6l1.2-.4L4 4z" fill="currentColor"/>
  </Icon>
);
const IconWaveform = (p) => (
  <Icon {...p}>
    <path d="M4 12v0M7 8v8M10 5v14M13 9v6M16 6v12M20 11v2" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" fill="none"/>
  </Icon>
);

// — UI
const IconSearch = (p) => (
  <Icon {...p}>
    <circle cx="10.5" cy="10.5" r="5.5" stroke="currentColor" strokeWidth="1.6" fill="none"/>
    <path d="M14.5 14.5L19 19" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" fill="none"/>
  </Icon>
);
const IconClose = (p) => <Icon {...p}><path d="M6 6l12 12M18 6L6 18" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" fill="none"/></Icon>;
const IconChevronRight = (p) => <Icon {...p}><path d="M9 5l7 7-7 7" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" fill="none"/></Icon>;
const IconChevronDown = (p) => <Icon {...p}><path d="M5 9l7 7 7-7" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" fill="none"/></Icon>;
const IconCheck = (p) => <Icon {...p}><path d="M5 12.5l4 4 10-10" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" fill="none"/></Icon>;
const IconPlus = (p) => <Icon {...p}><path d="M12 5v14M5 12h14" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" fill="none"/></Icon>;
const IconDots = (p) => <Icon {...p}><circle cx="6" cy="12" r="1.6" fill="currentColor"/><circle cx="12" cy="12" r="1.6" fill="currentColor"/><circle cx="18" cy="12" r="1.6" fill="currentColor"/></Icon>;
const IconImport = (p) => (
  <Icon {...p}>
    <path d="M12 4v11M12 15l-4-4M12 15l4-4" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" fill="none"/>
    <path d="M5 17v2a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-2" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" fill="none"/>
  </Icon>
);
const IconShare = (p) => (
  <Icon {...p}>
    <path d="M12 3v12M12 3l-3.5 3.5M12 3l3.5 3.5" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" fill="none"/>
    <path d="M5 12v7a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-7" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" fill="none"/>
  </Icon>
);
const IconBookmark = (p) => <Icon {...p}><path d="M7 4h10v17l-5-3.5L7 21V4z" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round" fill="none"/></Icon>;
const IconDownload = (p) => (
  <Icon {...p}>
    <path d="M12 4v11M12 15l-4.2-4.2M12 15l4.2-4.2" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" fill="none"/>
    <path d="M5 19.2h14" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" fill="none"/>
  </Icon>
);
const IconCircleCheck = (p) => (
  <Icon {...p}>
    <circle cx="12" cy="12" r="9" fill="currentColor"/>
    <path d="M8 12.5l3 3 5-6" stroke="#0D0E12" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" fill="none"/>
  </Icon>
);
const IconLock = (p) => (
  <Icon {...p}>
    <rect x="5" y="10.5" width="14" height="10" rx="2" stroke="currentColor" strokeWidth="1.5" fill="none"/>
    <path d="M8 10.5V8a4 4 0 0 1 8 0v2.5" stroke="currentColor" strokeWidth="1.5" fill="none"/>
  </Icon>
);
const IconTrash = (p) => (
  <Icon {...p}>
    <path d="M5 7h14" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" fill="none"/>
    <path d="M9.5 7V5.2A1.2 1.2 0 0 1 10.7 4h2.6a1.2 1.2 0 0 1 1.2 1.2V7" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" fill="none"/>
    <path d="M7 7l.9 11.1A1.5 1.5 0 0 0 9.4 19.5h5.2a1.5 1.5 0 0 0 1.5-1.4L17 7" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" fill="none"/>
    <path d="M10.5 10.5v5M13.5 10.5v5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" fill="none"/>
  </Icon>
);
const IconBolt = (p) => (
  <Icon {...p}>
    <path d="M13 3L5 13h6l-1 8 8-10h-6l1-8z" stroke="currentColor" strokeWidth="1.5" strokeLinejoin="round" fill="none"/>
  </Icon>
);

Object.assign(window, {
  IconStudio, IconVoices, IconHistory, IconSettings,
  IconPlay, IconPause, IconSparkles, IconStop, IconMic, IconWand, IconWaveform,
  IconSearch, IconClose, IconChevronRight, IconChevronDown, IconCheck, IconPlus, IconDots,
  IconImport, IconShare, IconBookmark, IconDownload, IconCircleCheck, IconLock, IconBolt, IconTrash,
});
