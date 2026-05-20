import React from "react";
import { Icon } from "../components/Icon.jsx";

const ROWS = [
  {
    k: "Where generation happens",
    v: "On your Mac",
    note: "After models install, every line renders on-device. No scripts uploaded, no audio sent away, no anonymous telemetry leaving the app.",
    tone: "var(--gold-300)",
  },
  {
    k: "Where data lives",
    v: "Local app storage",
    note: "Scripts, history, saved voices, and generated audio stay in Vocello's local storage until you export or reveal a file yourself.",
    tone: "var(--lavender-300)",
  },
  {
    k: "Pricing",
    v: "Free, open-source",
    note: "Download the Speed or Quality model once. Generate as many lines as your Mac can hold. No subscription, no per-character meter, no queue.",
    tone: "var(--terracotta-300)",
  },
  {
    k: "Speed model",
    v: "4-bit",
    note: "Smaller package, faster startup, lower memory. Vocello defaults to Speed on 8 GB / floor-spec Macs. Manage in Settings, Model downloads.",
    tone: "var(--status-ready)",
  },
  {
    k: "Quality model",
    v: "8-bit",
    note: "Larger package, slower to warm up, finer timbre and delivery. Vocello defaults to Quality on Macs with more RAM. Speed and Quality can coexist; pick the active variant on each generation screen.",
    tone: "var(--status-warn)",
  },
];

export const HowItRuns = () => (
  <section className="section runs-section" id="how-it-runs">
    <div className="container runs-layout">
      <header className="runs-head">
        <p className="section-note">How it runs</p>
        <h2 className="section-title">Vocello runs on your Mac.<br />Always. Here is how.</h2>
        <p className="section-sub">
          One scannable surface. No cards. The architecture is the pitch, and the
          rest of the app behaves like it.
        </p>
      </header>

      <dl className="runs-table" aria-label="Vocello runtime details">
        {ROWS.map((r) => (
          <div className="runs-row" key={r.k} style={{ "--row-tone": r.tone }}>
            <dt className="runs-k">{r.k}</dt>
            <dd className="runs-v">
              <span className="runs-v-label">{r.v}</span>
              {r.badge && (
                <span className={`runs-badge runs-badge--${r.badge.tone}`}>
                  <Icon name={r.badge.icon} size={11} stroke={2} />
                  {r.badge.label}
                </span>
              )}
            </dd>
            <dd className="runs-note">{r.note}</dd>
          </div>
        ))}
      </dl>
    </div>
  </section>
);
