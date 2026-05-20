// Vocello icon set — SF Symbols mapped to inline SVG approximations.
// Stroke weight 1.6 / 1.8 mirrors SF Symbols `regular` weight.
// All icons inherit `currentColor` and accept className/size props.

(function () {
  const Svg = ({ size = 16, strokeWidth = 1.7, children, className, style }) => (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      style={style}
      aria-hidden="true"
    >
      {children}
    </svg>
  );

  // person.wave.2  — Custom Voice
  const PersonWave2 = (p) => (
    <Svg {...p}>
      <circle cx="9" cy="6" r="3" />
      <path d="M3 21v-1a6 6 0 0 1 6-6 6 6 0 0 1 6 6v1" />
      <path d="M17 7a4 4 0 0 1 0 6" />
      <path d="M20 5a7 7 0 0 1 0 10" />
    </Svg>
  );

  // bubble.left.and.text — Voice Design
  const Bubble = (p) => (
    <Svg {...p}>
      <path d="M4 5h14a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H10l-4 4v-4H4a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2z" />
      <line x1="6" y1="9" x2="16" y2="9" />
      <line x1="6" y1="13" x2="13" y2="13" />
    </Svg>
  );

  // waveform.badge.plus — Voice Cloning
  const WaveformPlus = (p) => (
    <Svg {...p}>
      <path d="M2 12h1.5" />
      <path d="M5 8v8" />
      <path d="M8 4v16" />
      <path d="M11 8v8" />
      <path d="M14 10v4" />
      <path d="M17 12h0" />
      <circle cx="19" cy="6" r="3" fill="currentColor" stroke="none" opacity="0.0" />
      <circle cx="19" cy="6" r="3" />
      <path d="M19 5v2M18 6h2" stroke="currentColor" strokeWidth="1.4" />
    </Svg>
  );

  // clock.arrow.counterclockwise — History
  const Clock = (p) => (
    <Svg {...p}>
      <circle cx="12" cy="12" r="9" />
      <polyline points="12 7 12 12 15 14" />
    </Svg>
  );

  // person.2.wave.2 — Saved Voices
  const Person2 = (p) => (
    <Svg {...p}>
      <circle cx="8" cy="7" r="3" />
      <path d="M2 20v-1a5 5 0 0 1 5-5h2a5 5 0 0 1 5 5v1" />
      <circle cx="16" cy="9" r="2.5" />
      <path d="M22 19v-.5a3.5 3.5 0 0 0-3.5-3.5h-2" />
    </Svg>
  );

  // gearshape — Settings
  const Gear = (p) => (
    <Svg {...p}>
      <circle cx="12" cy="12" r="3" />
      <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.6a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
    </Svg>
  );

  // slider.horizontal.3 — Configuration
  const Sliders = (p) => (
    <Svg {...p}>
      <line x1="4" y1="6" x2="20" y2="6" />
      <line x1="14" y1="6" x2="14" y2="3" />
      <line x1="14" y1="6" x2="14" y2="9" />
      <line x1="4" y1="12" x2="20" y2="12" />
      <line x1="8" y1="12" x2="8" y2="9" />
      <line x1="8" y1="12" x2="8" y2="15" />
      <line x1="4" y1="18" x2="20" y2="18" />
      <line x1="16" y1="18" x2="16" y2="15" />
      <line x1="16" y1="18" x2="16" y2="21" />
    </Svg>
  );

  // text.alignleft — Script
  const TextLines = (p) => (
    <Svg {...p}>
      <line x1="4" y1="6" x2="20" y2="6" />
      <line x1="4" y1="12" x2="14" y2="12" />
      <line x1="4" y1="18" x2="18" y2="18" />
    </Svg>
  );

  // sidebar.left — sidebar toggle
  const SidebarIcon = (p) => (
    <Svg {...p}>
      <rect x="3" y="4" width="18" height="16" rx="2" />
      <line x1="9" y1="4" x2="9" y2="20" />
    </Svg>
  );

  // play.fill — generate button
  const PlayFill = ({ size = 16, className, style }) => (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor" className={className} style={style} aria-hidden="true">
      <path d="M7 4.5v15a1 1 0 0 0 1.5.87l13-7.5a1 1 0 0 0 0-1.74l-13-7.5A1 1 0 0 0 7 4.5z" />
    </svg>
  );

  // checkmark.circle.fill — settings "ready"
  const CheckCircle = (p) => (
    <Svg {...p} strokeWidth={p.strokeWidth || 0}>
      <circle cx="12" cy="12" r="10" fill="currentColor" opacity="0.9" />
      <polyline points="8 12 11 15 16 9" stroke="#0F1014" strokeWidth="2" fill="none" />
    </Svg>
  );

  const Chevron = (p) => (
    <Svg {...p} strokeWidth={p.strokeWidth || 1.4}>
      <polyline points="7 9 12 4 17 9" />
      <polyline points="7 15 12 20 17 15" />
    </Svg>
  );

  const Triangle = (p) => (
    <Svg {...p}>
      <path d="M12 4 22 20 2 20z" />
      <line x1="12" y1="10" x2="12" y2="15" />
      <line x1="12" y1="18" x2="12.01" y2="18" />
    </Svg>
  );

  const Plus = (p) => (
    <Svg {...p}>
      <line x1="12" y1="5" x2="12" y2="19" />
      <line x1="5" y1="12" x2="19" y2="12" />
    </Svg>
  );

  const Pause = (p) => (
    <Svg {...p}>
      <rect x="6" y="5" width="4" height="14" rx="1" fill="currentColor" stroke="none" />
      <rect x="14" y="5" width="4" height="14" rx="1" fill="currentColor" stroke="none" />
    </Svg>
  );

  Object.assign(window, {
    VocIcons: {
      PersonWave2, Bubble, WaveformPlus, Clock, Person2, Gear,
      Sliders, TextLines, SidebarIcon, PlayFill, CheckCircle, Chevron,
      Triangle, Plus, Pause,
    },
  });
})();
