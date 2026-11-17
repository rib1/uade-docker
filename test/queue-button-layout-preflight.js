module.exports = async function verifyQueueButtonLayout(browser, url) {
  const context = await browser.newContext({ reducedMotion: "reduce" });
  try {
    const page = await context.newPage();
    await page.goto(url, { waitUntil: "networkidle" });
    for (const width of [320, 375, 393, 1024]) {
      for (const fontSize of [16, 32]) {
        console.log(`Checking queue feedback layout: ${width}px, ${fontSize}px root text`);
        await page.setViewportSize({ width, height: 900 });
        await page.evaluate((size) => {
          window.document.documentElement.style.fontSize = `${size}px`;
          window.loadPlaylistFromPayload({ v: 1, t: [
            { n: "Lizardking - Doskpop", u: "https://example.com/doskpop.mod" },
          ] });
          window.setPlaylistPanelOpen(true);
        }, fontSize);
        const failures = await page.evaluate((mobile) => {
          const button = window.document.querySelector(".playlist-play-btn");
          const originalLabel = button.getAttribute("aria-label");
          const failuresFound = [];
          const checkBounds = (state) => {
            for (const control of window.document.querySelectorAll(
              ".playlist-item-actions .btn, .playlist-panel-header-actions .btn",
            )) {
              const bounds = control.getBoundingClientRect();
              const range = window.document.createRange();
              range.selectNodeContents(control);
              for (const rect of range.getClientRects()) {
                if (rect.width && rect.height && (rect.left < bounds.left - 1 ||
                    rect.right > bounds.right + 1 || rect.top < bounds.top - 1 ||
                    rect.bottom > bounds.bottom + 1)) {
                  failuresFound.push(`${state}: content outside ${control.className}`);
                }
              }
              if (bounds.height < 44) {
                failuresFound.push(`${state}: button is shorter than its touch target`);
              }
            }
          };
          checkBounds("ready");
          for (const state of ["Checking...", "Converting..."]) {
            window.setButtonLoadingState(button, state);
            const text = button.querySelector(".button-state-text");
            if ((window.getComputedStyle(text).display === "none") !== mobile ||
                !button.getAttribute("aria-label").includes(`${state} Lizardking - Doskpop`) ||
                window.getComputedStyle(button.querySelector(".loading")).display === "none") {
              failuresFound.push(`${state}: feedback visibility or accessible name is incorrect`);
            }
            checkBounds(state);
          }
          // Failure restores the original action name along with its visible label.
          button.textContent = window.getButtonRestoreText(button, "Play");
          if (button.getAttribute("aria-label") !== originalLabel) {
            failuresFound.push("failure: original action name was not restored");
          }
          window.resetButtonAfterDelay(button, "Play", 0);
          if (button.getAttribute("aria-label") !== "Playing Lizardking - Doskpop" ||
              (window.getComputedStyle(button.querySelector(".button-state-text")).display === "none") !== mobile) {
            failuresFound.push("playing: feedback visibility or accessible name is incorrect");
          }
          checkBounds("playing");
          window.document.getElementById("playlist-share-btn").textContent = "✓ Copied!";
          checkBounds("copied");
          const outsideQueue = window.document.getElementById("url-submit");
          window.setButtonLoadingState(outsideQueue, "Converting...");
          if (window.getComputedStyle(outsideQueue.querySelector(".button-state-text")).display === "none") {
            failuresFound.push("full-size conversion button must retain its text");
          }
          return failuresFound;
        }, width <= 600);
        if (failures.length) {
          throw new Error(failures.join("; "));
        }
        await page.waitForFunction(() => {
          const button = window.document.querySelector(".playlist-play-btn");
          return button.textContent === "Play" &&
            button.getAttribute("aria-label") === "Play Lizardking - Doskpop" &&
            !button.hasAttribute("data-default-aria-label");
        }, null, { timeout: 5000 });
      }
    }
  } finally {
    await context.close();
  }
};
