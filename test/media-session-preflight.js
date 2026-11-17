const { Buffer } = require("buffer");
const { URL } = require("url");

function createAudioFixture() {
  const sampleRate = 8000;
  const audio = Buffer.alloc(44 + sampleRate * 60);
  audio.write("RIFF", 0);
  audio.writeUInt32LE(audio.length - 8, 4);
  audio.write("WAVEfmt ", 8);
  audio.writeUInt32LE(16, 16);
  audio.writeUInt16LE(1, 20);
  audio.writeUInt16LE(1, 22);
  audio.writeUInt32LE(sampleRate, 24);
  audio.writeUInt32LE(sampleRate, 28);
  audio.writeUInt16LE(1, 32);
  audio.writeUInt16LE(8, 34);
  audio.write("data", 36);
  audio.writeUInt32LE(audio.length - 44, 40);
  for (let i = 44; i < audio.length; i++) {
    audio[i] = 128 + Math.round(16 * Math.sin(2 * Math.PI * 440 * (i - 44) / sampleRate));
  }
  return audio;
}

module.exports = async function verifyMediaSessionNavigation(browser, url) {
  console.log("Checking browser media controls: queue tracks and standalone subtunes");
  const context = await browser.newContext();
  try {
    await context.addInitScript(() => {
      const session = window.navigator.mediaSession;
      const register = session.setActionHandler.bind(session);
      window.mediaTestHandlers = {};
      session.setActionHandler = (action, handler) => {
        register(action, handler);
        window.mediaTestHandlers[action] = handler;
      };
    });
    const page = await context.newPage();
    const audio = createAudioFixture();
    let failMiddleAudio = false;
    let delayedMiddleAudio = null;
    await page.route("**/media-session-test.wav*", async (route) => {
      if (failMiddleAudio && route.request().url().includes("track=middle")) {
        return route.fulfill({ contentType: "audio/wav", body: "invalid audio" });
      }
      if (delayedMiddleAudio && route.request().url().includes("track=middle")) {
        const metadataGate = delayedMiddleAudio;
        delayedMiddleAudio = null;
        await metadataGate;
        if (route.request().failure()) {
          return undefined;
        }
      }
      const range = route.request().headers().range?.match(/^bytes=(\d+)-(\d*)$/);
      const start = range ? Number(range[1]) : 0;
      const end = range?.[2] ? Math.min(Number(range[2]), audio.length - 1) : audio.length - 1;
      const headers = { "Accept-Ranges": "bytes" };
      if (range) {
        headers["Content-Range"] = `bytes ${start}-${end}/${audio.length}`;
      }
      return route.fulfill({ status: range ? 206 : 200, headers,
        contentType: "audio/wav", body: audio.subarray(start, end + 1) }).catch((error) => {
        if (!route.request().failure()) {
          throw error;
        }
      });
    });
    await page.route("**/convert-url", (route) => {
      const name = new URL(route.request().postDataJSON().url).pathname.slice(1);
      return route.fulfill({ json: {
        success: true, file_id: name, module_name: name, subsongs: 3,
        subsong_durations: [10, 20, 30], audio_format: "wav", module_format: "Test",
        play_url: `/media-session-test.wav?track=${name}`, download_url: "/unused.wav",
      } });
    });
    await page.goto(url, { waitUntil: "networkidle" });
    await page.click("h1");
    await page.evaluate(() => {
      window.loadPlaylistFromPayload({ v: 1, t: [
        { n: "First", u: "https://example.com/first" },
        { n: "Middle", u: "https://example.com/middle" },
        { n: "Last", u: "https://example.com/last" },
      ] });
      window.mediaTestHandlers.nexttrack();
      if (window.mediaTestHandlers.nexttrack !== null || window.mediaTestHandlers.previoustrack !== null) {
        throw new Error("Media track navigation must be disabled during conversion.");
      }
    });
    await page.waitForFunction(() =>
      window.document.getElementById("current-track").textContent.startsWith("First") &&
      !window.document.getElementById("url-submit").disabled,
    null, { timeout: 5000 });
    const expectTrack = async (name, position = 0) => {
      await page.waitForFunction((expected) =>
        window.document.getElementById("current-track").textContent.startsWith(expected.name) &&
        window.document.getElementById("audio-player").seekable.length > 0 &&
        Math.abs(window.document.getElementById("audio-player").currentTime - expected.position) < 2,
      { name, position }, { timeout: 5000 });
      // The UI stays locked for two seconds after playback has already started.
      await page.waitForFunction(() => !window.document.getElementById("url-submit").disabled,
        null, { timeout: 5000 });
    };
    const media = (action) => page.evaluate((mediaAction) =>
      window.mediaTestHandlers[mediaAction](), action);

    await expectTrack("First");
    await media("previoustrack");
    await expectTrack("First");
    await media("nexttrack");
    await expectTrack("First", 10);
    await media("nexttrack");
    await expectTrack("First", 30);
    await media("nexttrack");
    await expectTrack("Middle");
    await media("previoustrack");
    await expectTrack("First", 30);
    await media("nexttrack");
    await expectTrack("Middle");

    // HTML queue controls still skip whole modules, including any remaining subtunes.
    await page.click("#playlist-next-btn");
    await expectTrack("Last");
    await page.click("#playlist-prev-btn");
    await expectTrack("Middle");
    await page.click("#playlist-next-btn");
    await expectTrack("Last");
    await page.click(".subsong-buttons button:nth-child(3)");
    await expectTrack("Last", 30);
    await page.click(".subsong-buttons button:first-child");
    await expectTrack("Last");
    await media("nexttrack");
    await expectTrack("Last", 10);
    await media("nexttrack");
    await expectTrack("Last", 30);
    await page.evaluate(() => {
      if (window.mediaTestHandlers.nexttrack !== null) {
        throw new Error("Next must be disabled only at the last subtune of the last queue track.");
      }
    });
    await page.evaluate(() => { window.document.getElementById("audio-player").currentTime = 35; });
    await media("previoustrack");
    await expectTrack("Last", 30);
    await media("previoustrack");
    await expectTrack("Last", 10);
    await media("previoustrack");
    await expectTrack("Last");
    await media("previoustrack");
    await expectTrack("Middle", 30);
    await media("nexttrack");
    await expectTrack("Last");

    // A failed cross-module seek must not affect a later HTML Play action.
    failMiddleAudio = true;
    await media("previoustrack");
    await page.waitForFunction(() =>
      window.document.getElementById("current-track").textContent.startsWith("Middle") &&
      window.document.getElementById("audio-player").error !== null &&
      !window.document.getElementById("url-submit").disabled,
    null, { timeout: 5000 });
    failMiddleAudio = false;
    await page.click("#playlist-toggle-btn");
    await page.click(".playlist-item.active .playlist-play-btn");
    await expectTrack("Middle");
    await page.click("#playlist-next-btn");
    await expectTrack("Last");

    console.log("Checking same-track HTML replay before delayed metadata arrives");
    let releaseMetadata;
    delayedMiddleAudio = new Promise((resolve) => { releaseMetadata = resolve; });
    try {
      await media("previoustrack");
      await page.waitForFunction(() =>
        window.document.getElementById("current-track").textContent.startsWith("Middle") &&
        window.document.getElementById("audio-player").readyState === 0 &&
        !window.document.getElementById("url-submit").disabled,
      null, { timeout: 5000 });
      await page.click(".playlist-item.active .playlist-play-btn");
      await page.waitForFunction(() =>
        window.document.querySelector(".playlist-item.active .playlist-play-btn")
          .textContent.includes("Playing"),
      null, { timeout: 5000 });
      releaseMetadata();
      await expectTrack("Middle");
    } finally {
      releaseMetadata();
    }
    await page.click("#playlist-next-btn");
    await expectTrack("Last");

    await page.evaluate(() => { window.clearPlaylist(); });
    await page.evaluate(() => {
      if (window.navigator.mediaSession.playbackState !== "playing") {
        throw new Error("Media session must reflect active playback.");
      }
      window.mediaTestHandlers.pause();
    });
    await page.waitForFunction(() => window.navigator.mediaSession.playbackState === "paused",
      null, { timeout: 5000 });
    await page.evaluate(() => window.mediaTestHandlers.play());
    await page.waitForFunction(() => window.navigator.mediaSession.playbackState === "playing",
      null, { timeout: 5000 });
    const jumps = await page.evaluate(() => {
      window.mediaTestHandlers.nexttrack();
      const first = window.document.getElementById("audio-player").currentTime;
      window.mediaTestHandlers.nexttrack();
      return { first, second: window.document.getElementById("audio-player").currentTime };
    });
    console.log("Subtune skip positions:", jumps);
    await page.waitForFunction(() => {
      const player = window.document.getElementById("audio-player");
      return player.currentTime >= 30 && player.currentTime < 32 && !player.paused;
    }, null, { timeout: 5000 });
    await page.evaluate(() => {
      if (window.mediaTestHandlers.nexttrack !== null) {
        throw new Error("Next must be disabled at the last subtune.");
      }
      window.mediaTestHandlers.previoustrack();
    });
    await page.waitForFunction(() => {
      const time = window.document.getElementById("audio-player").currentTime;
      return time >= 10 && time < 12;
    }, null, { timeout: 5000 });
    await page.evaluate(() => { window.document.getElementById("audio-player").currentTime = 35; });
    await page.waitForFunction(() => window.mediaTestHandlers.nexttrack === null,
      null, { timeout: 5000 });
    await page.evaluate(() => { window.document.getElementById("audio-player").currentTime = 15; });
    await page.waitForFunction(() => typeof window.mediaTestHandlers.nexttrack === "function",
      null, { timeout: 5000 });
    await media("previoustrack");
    await expectTrack("Last", 10);
    await media("previoustrack");
    await expectTrack("Last");
    await page.evaluate(() => {
      window.mediaTestHandlers.previoustrack();
      if (window.document.getElementById("audio-player").currentTime >= 1) {
        throw new Error("Previous at the first subtune must restart it.");
      }
      window.playFile("single", "Single", "/media-session-test.wav", "/unused.wav");
      if (window.mediaTestHandlers.nexttrack !== null ||
          typeof window.mediaTestHandlers.previoustrack !== "function") {
        throw new Error("A standalone module without subtunes must allow restart but disable Next.");
      }
    });
  } finally {
    await context.close();
  }
};
