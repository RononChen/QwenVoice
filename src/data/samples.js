export const SAMPLES = [
  {
    id: "narrator",
    mode: "Voice Design",
    color: "var(--lavender-300)",
    seed: 3,
    voice: "A warm, deep narrator with a subtle British accent.",
    quote: "The valley opens after the last bend, slow, and quieter than the road would suggest.",
    duration: "0:08",
    delivery: "Calm / subtle",
    src: "assets/voice-samples/voice-design-calm-subtle.wav",
  },
  {
    id: "host",
    mode: "Custom Voice",
    color: "var(--gold-300)",
    seed: 8,
    voice: "Aiden, English native",
    quote: "Hey, welcome back to Field Notes. Today we're walking through the demo build, end to end.",
    duration: "0:06",
    delivery: "Excited / confident",
    src: "assets/voice-samples/custom-voice-aiden-excited.wav",
  },
  {
    id: "documentary",
    mode: "Voice Cloning",
    color: "var(--terracotta-300)",
    seed: 14,
    voice: "Cloned from internal-narration-v3.wav",
    quote: "Every measurement was logged, every observation written down. Only then could the model be trusted.",
    duration: "0:09",
    delivery: "Mirrors source",
    src: "assets/voice-samples/voice-cloning-mirrors-source.wav",
  },
];

export const DELIVERIES = [
  { label: "Neutral", color: "var(--emotion-neutral)" },
  { label: "Calm", color: "var(--emotion-calm)" },
  { label: "Warm", color: "var(--emotion-happy)" },
  { label: "Dramatic", color: "var(--emotion-dramatic)" },
  { label: "Excited", color: "var(--emotion-excited)" },
  { label: "Whisper", color: "var(--emotion-whisper)" },
  { label: "Sad", color: "var(--emotion-sad)" },
];

export const DELIVERY_COLORS = {
  Neutral: "#8C8F9B",
  Calm: "#9EBC9E",
  Warm: "#F2C74D",
  Dramatic: "#C785A8",
  Excited: "#EB9452",
  Whisper: "#9E9EA8",
  Sad: "#8C9EC7",
};
