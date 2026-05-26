import React from "react";
import { Icon } from "../components/Icon.jsx";
import { RELEASE_LATEST } from "../data/credits.js";

const TRUST_POINTS = [
  { icon: "shield", text: "Signed + notarized" },
  { icon: "github", text: "MIT app code" },
  { icon: "cpu", text: "Generation runs locally after model download" },
  { icon: "check", text: "No Python setup" },
  { icon: "lock", text: "Voice cloning only for voices you own or have permission to use" },
];

export const Hero = () => (
  <section className="hero">
    <div className="container hero-split">
      <div className="hero-copy">
        <div className="hero-eyebrow">
          <span className="dot" aria-hidden="true" />
          Vocello 2.0.0 · macOS 26+ · Apple Silicon
        </div>
        <h1 className="hero-title">
          A voice studio that <span className="accent-gold">never leaves</span> your Mac.
        </h1>
        <p className="hero-sub">
          Vocello is a local AI voice studio for Mac and a Qwen3-TTS Mac app:
          write a script, choose a preset or voice brief, then generate locally
          after model download. No subscription, cloud meter, or upload.
        </p>
        <div className="hero-ctas">
          <a className="btn btn-primary" href={RELEASE_LATEST} target="_blank" rel="noreferrer">
            <Icon name="apple" size={16} />
            Download for macOS&nbsp;26
            <span className="platform-mini">· 2.0.0</span>
          </a>
          <a className="btn btn-secondary" href="#listen">
            <Icon name="play" size={14} />
            Listen to samples
          </a>
        </div>
        <div className="trust-block" aria-label="Vocello trust and install details">
          {TRUST_POINTS.map((point) => (
            <span className="trust-chip" key={point.text}>
              <Icon name={point.icon} size={12} />
              {point.text}
            </span>
          ))}
        </div>
        <div className="hero-meta">
          <span><Icon name="lock" size={12} /> Scripts stay local after setup</span>
          <span><Icon name="cpu" size={12} /> Swift + MLX engine</span>
          <span><Icon name="diamond" size={12} /> Stable 2.0.0 DMG</span>
        </div>
      </div>
      <div className="hero-stage">
        <div className="hero-stage-glow" aria-hidden="true" />
        <div className="window hero-window">
          <img
            src="assets/screens/custom-voice.png"
            alt="Vocello Custom Voice screen showing speaker, delivery, model, and script controls"
          />
        </div>
      </div>
    </div>
  </section>
);
