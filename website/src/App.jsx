import React from "react";
import { Nav } from "./sections/Nav.jsx";
import { Hero } from "./sections/Hero.jsx";
import { WorkflowBand } from "./sections/WorkflowBand.jsx";
import { Listen } from "./sections/Listen.jsx";
import { WhyCloud } from "./sections/WhyCloud.jsx";
import { TryIt } from "./sections/TryIt.jsx";
import { HowItRuns } from "./sections/HowItRuns.jsx";
import { Limitations } from "./sections/Limitations.jsx";
import { FinalCTA } from "./sections/FinalCTA.jsx";
import { Footer } from "./sections/Footer.jsx";
import { WORKFLOWS } from "./data/workflows.js";

const App = () => (
  <>
    <Nav />
    <Hero />
    <div id="workflows" className="workflows-anchor">
      {WORKFLOWS.map((w, i) => (
        <WorkflowBand key={w.id} workflow={w} index={i} />
      ))}
    </div>
    <Listen />
    <WhyCloud />
    <TryIt />
    <HowItRuns />
    <Limitations />
    <FinalCTA />
    <Footer />
  </>
);

export default App;
