// Fixture data for the Vocello iOS prototype.
// Lifted from Sources/iOS shapes (Voice, EmotionPreset, TTSModel, Generation).

window.VOCELLO_DATA = {
  builtInVoices: [
    { id: 'sienna',  name: 'Sienna',  desc: 'Warm narrator, lower register',     lang: 'EN',    accent: 'Neutral',  hue: 22  },
    { id: 'aiden',   name: 'Aiden',   desc: 'British male, journalistic',         lang: 'EN-UK', accent: 'British',  hue: 200 },
    { id: 'mira',    name: 'Mira',    desc: 'Bright female, energetic',           lang: 'EN',    accent: 'American', hue: 320 },
    { id: 'noor',    name: 'Noor',    desc: 'Soft female, conversational',        lang: 'EN',    accent: 'Neutral',  hue: 280 },
    { id: 'rocco',   name: 'Rocco',   desc: 'Gravelly male, late-night',          lang: 'EN',    accent: 'American', hue: 12  },
    { id: 'yuki',    name: 'Yuki',    desc: 'Calm female, careful diction',       lang: 'JA',    accent: 'Tokyo',    hue: 340 },
    { id: 'leo',     name: 'Leo',     desc: 'Young male, conversational',         lang: 'EN',    accent: 'American', hue: 50  },
    { id: 'aria',    name: 'Aria',    desc: 'Audiobook female, expressive',       lang: 'EN',    accent: 'Neutral',  hue: 300 },
  ],
  savedVoices: [
    { id: 'sv-emma',  name: 'Emma (interview)', desc: '17 s reference · 2 wks ago', lang: 'EN', accent: 'Saved', hue: 160, saved: true },
    { id: 'sv-dad',   name: 'Dad voicemail',    desc: '13 s reference · last month', lang: 'EN', accent: 'Saved', hue: 180, saved: true },
  ],
  deliveries: [
    { id: 'neutral', name: 'Neutral',    desc: 'Default, even pacing',        color: 'var(--emotion-neutral)' },
    { id: 'calm',    name: 'Calm',       desc: 'Slower, reassuring',          color: 'var(--emotion-calm)'    },
    { id: 'happy',   name: 'Happy',      desc: 'Warm, bright, smiling',       color: 'var(--emotion-happy)'   },
    { id: 'excited', name: 'Excited',    desc: 'Energetic, faster',           color: 'var(--emotion-excited)' },
    { id: 'sad',     name: 'Sad',        desc: 'Quiet, slower, somber',       color: 'var(--emotion-sad)'     },
    { id: 'angry',   name: 'Angry',      desc: 'Tense, sharp',                color: 'var(--emotion-angry)'   },
    { id: 'fearful', name: 'Fearful',    desc: 'Quiet, hesitant',             color: 'var(--emotion-fearful)' },
    { id: 'whisper', name: 'Whisper',    desc: 'Soft and quiet — say "whisper"', color: 'var(--emotion-whisper)' },
    { id: 'drama',   name: 'Dramatic',   desc: 'Theatrical, projected',       color: 'var(--emotion-dramatic)'},
  ],
  models: [
    { id: 'qwen-custom-4bit',  mode: 'custom', name: 'Custom Voice · 4-bit Speed',  size: '1.6 GB', desc: 'Built-in speaker presets with controllable emotion and delivery.',  installed: true,  active: true,  modeColor: 'var(--mode-custom)',  modeLabel: 'Custom Voice' },
    { id: 'qwen-design-4bit',  mode: 'design', name: 'Voice Design · 4-bit Speed',  size: '1.8 GB', desc: 'Describe a voice in natural language and Vocello renders it.',     installed: false, active: false, modeColor: 'var(--mode-design)',  modeLabel: 'Voice Design' },
    { id: 'qwen-cloning-4bit', mode: 'clone',  name: 'Voice Cloning · 4-bit Speed', size: '2.1 GB', desc: 'Speak your text in a saved voice or any 10–20 s reference clip.',     installed: false, active: false, modeColor: 'var(--mode-cloning)', modeLabel: 'Voice Cloning' },
  ],
  history: [
    // Today
    { id: 'h1',  bucket: 'Today',     time: '11:42',  mode: 'custom', voice: 'Sienna',  text: 'Welcome back to the workshop. Today we are building a small wooden box, end to end.', duration: 6.4 },
    { id: 'h2',  bucket: 'Today',     time: '09:18',  mode: 'design', voice: 'A clear, neutral narrator', text: 'In the spring of 1923, the river had not yet swelled past the cottonwoods.', duration: 5.1 },
    { id: 'h3',  bucket: 'Today',     time: '08:55',  mode: 'clone',  voice: 'Emma (interview)', text: 'Hey, just wanted to check the studio is set up before we record tomorrow.', duration: 4.2 },
    // Yesterday
    { id: 'h4',  bucket: 'Yesterday', time: '22:11',  mode: 'custom', voice: 'Rocco',   text: 'Chapter four. The road bent west, and the headlights caught nothing but rain.', duration: 7.8 },
    { id: 'h5',  bucket: 'Yesterday', time: '15:03',  mode: 'design', voice: 'Audiobook female, expressive', text: 'She closed the book and looked at the window for a long time.', duration: 3.6 },
    // Previous 7 days
    { id: 'h6',  bucket: 'Previous 7 days', time: '3 days ago', mode: 'clone',  voice: 'Dad voicemail', text: 'Reminder — your appointment with Dr. Patel is at four-thirty on Thursday.', duration: 4.0 },
    { id: 'h7',  bucket: 'Previous 7 days', time: '4 days ago', mode: 'custom', voice: 'Aria',    text: 'And so the harvest came in early that year, before the rains had really started.', duration: 5.5 },
    { id: 'h8',  bucket: 'Previous 7 days', time: '5 days ago', mode: 'design', voice: 'A British male, journalistic', text: 'Reports from the constituency suggest a closer race than polling had implied.', duration: 4.8 },
  ],
  recent: ['sienna', 'aria', 'rocco'],
};
