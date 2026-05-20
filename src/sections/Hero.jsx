import React from "react";
import { Icon } from "../components/Icon.jsx";
import { RELEASE_LATEST } from "../data/credits.js";

export const Hero = () => (
  <section className="hero">
    <div className="container hero-split">
      <div className="hero-copy">
        <div className="hero-eyebrow">
          <span className="dot" aria-hidden="true" />
          Vocello 2.0 · macOS 26 · Apple Silicon
        </div>
        <h1 className="hero-title">
          A voice studio that <span className="accent-gold">never leaves</span> your Mac.
        </h1>
        <p className="hero-sub">
          Write a script. Choose how it should sound. Generate locally: no subscription,
          no cloud meter, no upload. Your scripts, your voices, your audio, your machine.
        </p>
        <div className="hero-ctas">
          <a className="btn btn-primary" href={RELEASE_LATEST} target="_blank" rel="noreferrer">
            <Icon name="apple" size={16} />
            Download for macOS&nbsp;26
            <span className="platform-mini">· 2.0</span>
          </a>
          <a className="btn btn-secondary" href="#listen">
            <Icon name="play" size={14} />
            Listen to samples
          </a>
        </div>
        <div className="hero-meta">
          <span><Icon name="lock" size={12} /> Local-first by design</span>
          <span><Icon name="cpu" size={12} /> Native Swift + MLX</span>
          <span><Icon name="infinity" size={12} /> No usage limits</span>
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
