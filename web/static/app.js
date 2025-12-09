// UADE Web Player - Client Side JavaScript

// State
let currentDownloadUrl = null;

// DOM Elements
const dropZone = document.getElementById("drop-zone");
const fileInput = document.getElementById("module-file-input");
const urlInput = document.getElementById("url-input");
const urlSubmit = document.getElementById("url-submit");
const mainUrlInput = document.getElementById("main-url");
const sampleUrlInput = document.getElementById("sample-url");
const dualFileSubmit = document.getElementById("dual-file-submit");
const uploadBtn = document.getElementById("upload-btn"); // The label acts as the button
const audioPlayer = document.getElementById("audio-player");
const playerSection = document.getElementById("player-section");
const currentTrack = document.getElementById("current-track");
const trackFormat = document.getElementById("track-format");
const downloadBtn = document.getElementById("download-btn");
const examplesGrid = document.getElementById("examples-grid");
const statusContainer = document.getElementById("status-container");

const elementsToDisable = [
  fileInput,
  urlInput,
  urlSubmit,
  mainUrlInput,
  sampleUrlInput,
  dualFileSubmit,
 ];

// Initialize
document.addEventListener("DOMContentLoaded", () => {
  setupDragAndDrop();
  setupFileInput();
  setupUrlForm();
  setupDualFileForm();
  setupDownloadButton();
  loadExamples();
  loadVersionInfo();
  loadSupportedExtensions();
  createAutoplayOverlay();

  // Hide overlay whenever playback starts for any reason (e.g., user clicks native play)
  audioPlayer.addEventListener("play", () => {
    const autoplayOverlay = document.getElementById("autoplay-overlay");
    if (autoplayOverlay) {
      autoplayOverlay.style.display = "none";
      autoplayOverlay.style.pointerEvents = "none"; // Disable interaction
    }
  });
});

async function loadSupportedExtensions() {
  try {
    const response = await fetch("/supported-extensions");
    const extensions = await response.json();
    if (extensions && extensions.length > 0) {
      fileInput.accept = extensions.join(",");
    }
  } catch (error) {
    console.error("Failed to load supported extensions:", error);
  }
}

// --- UI Lock Functions ---

/**
 * Disables all interactive elements to prevent simultaneous conversions.
 */
function setUiLock() {
  const dynamicElements = document.querySelectorAll(".play-btn");
  [...elementsToDisable, ...dynamicElements].forEach((el) => {
    el.disabled = true;
    el.setAttribute("aria-busy", "true");
  });
  if (uploadBtn) {
    uploadBtn.classList.add("disabled");
    uploadBtn.setAttribute("aria-busy", "true");
  }
}

/**
 * Re-enables all interactive elements after a conversion is complete.
 */
function releaseUiLock() {
  const dynamicElements = document.querySelectorAll(".play-btn");
  [...elementsToDisable, ...dynamicElements].forEach((el) => {
    el.disabled = false;
    el.setAttribute("aria-busy", "false");
  });
  if (uploadBtn) {
    uploadBtn.classList.remove("disabled");
    uploadBtn.setAttribute("aria-busy", "false");
  }
}

// Drag and Drop
function setupDragAndDrop() {
  ["dragenter", "dragover", "dragleave", "drop"].forEach((eventName) => {
    dropZone.addEventListener(eventName, preventDefaults, false);
  });

  function preventDefaults(e) {
    e.preventDefault();
    e.stopPropagation();
  }

  ["dragenter", "dragover"].forEach((eventName) => {
    dropZone.addEventListener(eventName, () => {
      dropZone.classList.add("drag-over");
    });
  });

  ["dragleave", "drop"].forEach((eventName) => {
    dropZone.removeEventListener(eventName, () => {
      dropZone.classList.remove("drag-over");
    });
    dropZone.addEventListener(eventName, () => {
      dropZone.classList.remove("drag-over");
    });
  });

  dropZone.addEventListener("drop", handleDrop);
}

function handleDrop(e) {
  if (dropZone.classList.contains("disabled")) {
    return; // Do nothing if UI is locked
  }
  const dt = e.dataTransfer;
  const files = dt.files;

  if (files.length > 0) {
    handleFileUpload(files[0]);
  }
}

// File Input
function setupFileInput() {
  fileInput.addEventListener("change", (e) => {
    if (e.target.files.length > 0) {
      handleFileUpload(e.target.files[0]);
    }
  });
}

// Upload File
async function handleFileUpload(file) {
  setUiLock(); // Lock all other UI elements
  showStatus("Uploading and converting...", "info");

  // Manage this button's specific state
  const originalUploadBtnHTML = uploadBtn.innerHTML;
  uploadBtn.innerHTML = "<span class=\"loading\"></span> Converting...";

  const formData = new FormData();
  formData.append("file", file);

  try {
    const response = await fetch("/upload", {
      method: "POST",
      body: formData,
    });

    const data = await response.json();

    if (response.ok) {
      const statusMessage = data.cached
        ? `✓ From cache: ${data.module_name || data.filename}`
        : `✓ Converted: ${data.module_name || data.filename}`;
      showStatus(statusMessage, "success");
      playFile(
        data.file_id,
        data.module_name || data.filename,
        data.play_url,
        data.download_url,
        data.player_format || "Module",
        data.audio_format || "wav",
        data.module_format,
        data.subsongs
      );
    } else {
      showStatus(`✗ Error: ${data.error}`, "error");
    }
  } catch (error) {
    showStatus(`✗ Upload failed: ${error.message}`, "error");
  } finally {
    releaseUiLock(); // Re-enable all other UI elements
    uploadBtn.innerHTML = originalUploadBtnHTML; // Restore this button's text
  }
}

// URL Form
function setupUrlForm() {
  urlSubmit.addEventListener("click", handleUrlConvert);
  urlInput.addEventListener("keypress", (e) => {
    if (e.key === "Enter") {
      handleUrlConvert();
    }
  });
}

async function handleUrlConvert() {
  const url = urlInput.value.trim();
  if (!url) {
    showStatus("Please enter a URL", "warning");
    return;
  }

  setUiLock();
  showStatus("Downloading and converting...", "info");  
  const originalUrlBtnHTML = urlSubmit.innerHTML;
  urlSubmit.innerHTML = "<span class=\"loading\"></span> Converting...";

  try {
    const response = await fetch("/convert-url", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ url }),
    });

    const data = await response.json();

    if (response.ok) {
      const statusMessage = data.cached
        ? `✓ From cache: ${data.module_name || data.filename}`
        : `✓ Converted: ${data.module_name || data.filename}`;
      showStatus(statusMessage, "success");
      playFile(
        data.file_id,
        data.module_name || data.filename,
        data.play_url,
        data.download_url,
        data.player_format || "Module",
        data.audio_format || "wav",
        data.module_format,
        data.subsongs
      );
      urlInput.value = "";
    } else {
      showStatus(`✗ Error: ${data.error}`, "error");
    }
  } catch (error) {
    showStatus(`✗ Conversion failed: ${error.message}`, "error");
  } finally {
    releaseUiLock();
    urlSubmit.innerHTML = originalUrlBtnHTML;
  }
}

// Dual-File Form
function setupDualFileForm() {
  dualFileSubmit.addEventListener("click", handleDualFileConvert);
}

async function handleDualFileConvert() {
  const mainUrl = mainUrlInput.value.trim();
  const sampleUrl = sampleUrlInput.value.trim();

  if (!mainUrl || !sampleUrl) {
    showStatus("Please enter both URLs for the dual-file module", "warning");
    return;
  }

  setUiLock();
  showStatus("Converting dual-file module...", "info");
  const originalBtnHTML = dualFileSubmit.innerHTML;
  dualFileSubmit.innerHTML = "<span class=\"loading\"></span> Converting...";

  try {
    // Call convert-url with both URLs
    const response = await fetch("/convert-url", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        url: mainUrl,
        sample_url: sampleUrl,
      }),
    });

    const data = await response.json();

    if (response.ok) {
      const statusMessage = data.cached
        ? `✓ From cache: ${data.module_name || data.filename}`
        : `✓ Dual-file module converted successfully: ${data.module_name || data.filename}`;
      showStatus(statusMessage, "success");
      playFile(
        data.file_id,
        data.module_name || data.filename,
        data.play_url,
        data.download_url,
        data.player_format || "Dual-File Module", // Generic description for player format
        data.audio_format || "wav",
        data.module_format,
        data.subsongs
      );
      mainUrlInput.value = "";
      sampleUrlInput.value = "";
    } else {
      showStatus(`✗ Error: ${data.error}`, "error");
    }
  } catch (error) {
    showStatus(`✗ Dual-file module conversion failed: ${error.message}`, "error");
  } finally {
    releaseUiLock();
    dualFileSubmit.innerHTML = originalBtnHTML;
  }
}

// Load Examples
async function loadExamples() {
  try {
    const response = await fetch("/examples");
    const examples = await response.json();

    examples.forEach((example) => {
      const card = document.createElement("div");
      card.className = "example-card";

      // Title
      const h3 = document.createElement("h3");
      h3.textContent = example.name;
      card.appendChild(h3);

      // Meta
      const metaDiv = document.createElement("div");
      metaDiv.className = "example-meta";

      const formatSpan = document.createElement("span");
      formatSpan.className = "format-badge";
      formatSpan.textContent = example.format;
      metaDiv.appendChild(formatSpan);

      const durationSpan = document.createElement("span");
      durationSpan.textContent = example.duration;
      metaDiv.appendChild(durationSpan);

      card.appendChild(metaDiv);

      // Play button
      const playBtn = document.createElement("button");
      playBtn.className = "play-btn";
      playBtn.setAttribute("type", "button");
      playBtn.setAttribute("data-example-id", example.id);
      playBtn.textContent = "▶ Play Now";
      playBtn.addEventListener("click", () =>
        handleExamplePlay(example, playBtn),
      );
      card.appendChild(playBtn);

      examplesGrid.appendChild(card);
    });
  } catch (error) {
    console.error("Failed to load examples:", error);
  }
}

// Play Example
async function handleExamplePlay(example, button) {
  setUiLock(); // Lock the UI
  button.disabled = true;
  button.innerHTML = "<span class=\"loading\"></span> Converting...";
  showStatus(`Converting ${example.name}...`, "info");

  try {
    const response = await fetch(`/play-example/${example.id}`, {
      method: "POST",
    });

    const data = await response.json();

    if (response.ok) {
      const statusMessage = data.cached
        ? `✓ From cache: ${example.name || data.module_name || data.filename} ready to play`
        : `✓ ${example.name || data.module_name || data.filename} ready to play`;
      showStatus(statusMessage, "success");
      playFile(
        data.file_id,
        example.name || data.module_name || data.filename,
        data.play_url,
        data.download_url,
        data.player_format || example.format,
        data.audio_format || "wav",
        data.module_format,
        data.subsongs
      );
      button.innerHTML = "✓ Playing";

      // Reset button after 2 seconds
      setTimeout(() => {
        button.innerHTML = "▶ Play Now";
        releaseUiLock(); // Re-enable all UI elements on error
      }, 2000);
    } else {
      showStatus(`✗ Error: ${data.error}`, "error");
      button.innerHTML = "▶ Play Now";
      releaseUiLock(); // Re-enable all UI elements on error
    }
  } catch (error) {
    showStatus(`✗ Failed: ${error.message}`, "error");
    button.innerHTML = "▶ Play Now";
    releaseUiLock(); // Re-enable all UI elements on error
  }
}

// Play File
function playFile(
  fileId,
  moduleName,
  playUrl,
  downloadUrl,
  playerFormat = "",
  audioFormat = "wav",
  moduleFormat,
  subsongs = "1"
) {
  currentDownloadUrl = downloadUrl;

  audioPlayer.src = playUrl;

  // Build current track display: moduleName + subsongs if more than 1
  let trackDisplay = moduleName;
  if (subsongs && parseInt(subsongs) > 1) {
    trackDisplay += ` (${subsongs} subsongs)`;
  }
  currentTrack.textContent = trackDisplay;

  trackFormat.textContent = ""; // Clear previous content
  if (moduleFormat && playerFormat && moduleFormat !== playerFormat) {
    // Show both if they're different, separated by a line break (use <br> safely)
    trackFormat.appendChild(document.createTextNode(moduleFormat));
    trackFormat.appendChild(document.createElement("br"));
    trackFormat.appendChild(document.createTextNode(playerFormat));
  } else if (moduleFormat) {
    // Show module format if available
    trackFormat.textContent = moduleFormat;
  } else if (playerFormat) {
    // Fallback to player format
    trackFormat.textContent = playerFormat;
  } else {
    trackFormat.textContent = "Module";
  }

  // Show infobox for Custom modules
  const customInfo = document.getElementById("custom-info");
  if (playerFormat === "Custom") {
    customInfo.style.display = "block";
  } else {
    customInfo.style.display = "none";
  }

  // Update download button text with correct format
  downloadBtn.textContent =
    audioFormat === "flac" ? "⬇ Download FLAC" : "⬇ Download WAV";

  playerSection.style.display = "block";
  playerSection.scrollIntoView({ behavior: "smooth", block: "nearest" });

  const autoplayOverlay = document.getElementById("autoplay-overlay");
  if (autoplayOverlay) {
    autoplayOverlay.style.display = "none";
    autoplayOverlay.style.pointerEvents = "none";
  }

  // Remove previous error handler to avoid stacking
  audioPlayer.onerror = null;

  // Add error handler for failed playback (e.g., rate limit, invalid audio)
  audioPlayer.onerror = function () {
    showStatus("Audio cannot be played. You may have hit the rate limit or the file is invalid.", "error");
  };

  audioPlayer.play().catch((err) => {
    // Gracefully handle autoplay rejection on mobile
    if (err.name === "NotAllowedError") {
      showStatus("Autoplay blocked. Tap the play icon to start.", "info");
      if (autoplayOverlay) {
        autoplayOverlay.style.display = "flex";
        autoplayOverlay.style.pointerEvents = "auto";
      }
      console.warn("Autoplay was prevented by browser policy.");
    } else {
      console.error("Playback error:", err);
      showStatus("An error occurred during playback. Check console for details.", "error");
    }
  });

  // Update media session for lock screen
  updateMediaSession(trackDisplay, moduleFormat || playerFormat || "Amiga Module", "UADE Web Player");
}

// Update Media Session
// NOTE: As of iOS Safari 18, the Media Session API (for lock screen and media widget metadata)
// appears to be buggy or inconsistent, and may not display song information or artwork
// even when correctly implemented. This is believed to be a browser-specific issue and
// is out of the control of this application's developers.
function updateMediaSession(title, artist, album) {
  if ("mediaSession" in navigator) {
    navigator.mediaSession.metadata = new MediaMetadata({
      title: title,
      artist: artist,
      album: album,
      artwork: [
        { src: "/static/protracker_square.png", sizes: "96x96", type: "image/png" },
        { src: "/static/protracker_square.png", sizes: "128x128", type: "image/png" },
        { src: "/static/protracker_square.png", sizes: "192x192", type: "image/png" },
        { src: "/static/protracker_square.png", sizes: "256x256", type: "image/png" },
        { src: "/static/protracker_square.png", sizes: "384x384", type: "image/png" },
        { src: "/static/protracker_square.png", sizes: "512x512", type: "image/png" },
      ],
    });
  }
}

// Download Button
function setupDownloadButton() {
  downloadBtn.addEventListener("click", async () => {
    if (currentDownloadUrl) {
      downloadBtn.disabled = true;
      try {
        const response = await fetch(currentDownloadUrl);
        const contentType = response.headers.get("content-type") || "";
        if (contentType.includes("application/json")) {
          const data = await response.json();
          showStatus(`✗ Error: ${data.error || "Rate limit exceeded"}`, "error");
          downloadBtn.disabled = false;
        } else if (response.ok) {
          // Use direct link for streaming download
          // Extract filename from Content-Disposition header
          let filename = "downloaded_file";
          const disposition = response.headers.get("content-disposition");
          if (disposition && disposition.includes("filename=")) {
            filename = disposition.split("filename=")[1].replace(/["']/g, "").trim();
          }
          // Create a temporary anchor and trigger download
          const a = document.createElement("a");
          a.href = currentDownloadUrl;
          a.download = filename;
          a.target = "_blank";
          document.body.appendChild(a);
          a.click();
          a.remove();
          showStatus("Download started", "success");
          // Re-enable after short delay to avoid duplicate clicks
          setTimeout(() => { downloadBtn.disabled = false; }, 1000);
        } else {
          showStatus("✗ Download failed: Server error", "error");
          downloadBtn.disabled = false;
        }
      } catch (error) {
        showStatus(`✗ Download failed: ${error.message}`, "error");
      } finally {
        // Ensure button is re-enabled if an error occurs but wasn't caught in the try block (e.g. network error)
        if (downloadBtn.disabled) {
            downloadBtn.disabled = false;
        }
      }
    }
  });
}

// Status Messages
function showStatus(message, type = "info") {
  const status = document.createElement("div");
  status.className = `status-message status-${type}`;
  status.textContent = message;

  statusContainer.appendChild(status);

  // Auto-remove after 5 seconds
  setTimeout(() => {
    status.style.opacity = "0";
    setTimeout(() => status.remove(), 300);
  }, 5000);
}

// Create and setup the overlay for blocked autoplay
function createAutoplayOverlay() {
  const playerContainer = document.getElementById("player-container");
  if (!playerContainer) {
    return;
  }

  const overlay = document.createElement("div");
  overlay.id = "autoplay-overlay";
  overlay.setAttribute("aria-label", "Play"); // Added aria-label
  overlay.tabIndex = 0; // Added tabIndex for keyboard accessibility
  overlay.innerHTML = "<div class=\"play-button-overlay-icon\"></div>";

  playerContainer.appendChild(overlay);

  overlay.addEventListener("click", () => {
    const audioPlayer = document.getElementById("audio-player");
    audioPlayer.play(); // This is now a direct user interaction
    overlay.style.display = "none";
    overlay.style.pointerEvents = "none"; // Disable interaction after click
  });
}

// Load Version Info
async function loadVersionInfo() {
  try {
    const response = await fetch("/health");
    const data = await response.json();
    const versionElement = document.getElementById("version-info");

    if (data.version && data.version !== "unknown") {
      // Safely create version link without innerHTML
      versionElement.textContent = "Version: ";
      const link = document.createElement("a");
      link.href = `https://github.com/rib1/uade-docker/commit/${encodeURIComponent(data.version)}`;
      link.target = "_blank";
      link.style.color = "#666";
      link.style.textDecoration = "none";
      link.textContent = data.version;
      versionElement.appendChild(link);
    } else {
      versionElement.textContent = "";
    }
  } catch (error) {
    console.error("Failed to load version info:", error);
    document.getElementById("version-info").textContent = "";
  }
}
