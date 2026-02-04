// UADE Web Player - Client Side JavaScript

// State
let currentDownloadUrl = null;
let currentSubsongDurations = [];
let currentSubsongs = 1;
let currentSubsongIndex = 0;
let currentShareableUrl = null; // For shareable URLs feature
let currentShareableSampleUrl = null;

// DOM Elements
const dropZone = document.getElementById("drop-zone");
const fileInput = document.getElementById("module-file-input");
const urlInput = document.getElementById("url-input");
const urlSubmit = document.getElementById("url-submit");
const sampleUrlInput = document.getElementById("sample-url-input");
const uploadLabel = document.getElementById("upload-btn"); // The label acts as the button
const audioPlayer = document.getElementById("audio-player");
const playerSection = document.getElementById("player-section");
const currentTrack = document.getElementById("current-track");
const trackFormat = document.getElementById("track-format");
const downloadBtn = document.getElementById("download-btn");
const shareBtn = document.getElementById("share-btn");
const examplesGrid = document.getElementById("examples-grid");
const statusContainer = document.getElementById("status-container");

const elementsToDisable = [
  fileInput,
  urlInput,
  urlSubmit,
  sampleUrlInput,
 ];

// Helper function to download large files using range requests
async function downloadWithRangeRequests(url, filename, fileSize) {
  const chunkSize = 10 * 1024 * 1024; // 10MB chunks (well under 32MB limit)
  const chunks = [];

  for (let start = 0; start < fileSize; start += chunkSize) {
    const end = Math.min(start + chunkSize - 1, fileSize - 1);
    const response = await fetch(url, {
      headers: { "Range": `bytes=${start}-${end}` }
    });

    if (!response.ok && response.status !== 206) {
      throw new Error(`Server returned ${response.status} for range request`);
    }

    const chunk = await response.arrayBuffer();
    chunks.push(chunk);
  }

  // Combine chunks into single blob
  const blob = new Blob(chunks);
  const blobUrl = URL.createObjectURL(blob);

  // Trigger download
  const a = document.createElement("a");
  a.href = blobUrl;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();

  // Clean up blob URL after short delay
  setTimeout(() => URL.revokeObjectURL(blobUrl), 1000);
}

// Initialize
document.addEventListener("DOMContentLoaded", () => {
  setupDragAndDrop();
  setupFileInput();
  setupUrlForm();
  setupShareButton();
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

  // Check for shared URL parameter and auto-convert
  checkSharedUrlParameter();
});

// Check for ?url= parameter for shareable URLs
function checkSharedUrlParameter() {
  const urlParams = new URLSearchParams(window.location.search);
  const sharedUrl = urlParams.get("url");
  const sampleUrl = urlParams.get("sample");

  if (sharedUrl) {
    // Populate URL input fields
    urlInput.value = sharedUrl;
    if (sampleUrl) {
      sampleUrlInput.value = sampleUrl;
    }

    // Scroll to URL input section for visibility
    urlInput.scrollIntoView({ behavior: "smooth", block: "center" });

    // Auto-trigger conversion after short delay (allow UI to settle)
    setTimeout(() => {
      handleUrlConvert();
      // Clear URL parameters after conversion starts to prevent accidental bookmarking
      clearUrlParameters();
    }, 300);
  }
}

// Clear URL parameters from address bar without page reload
function clearUrlParameters() {
  const cleanUrl = window.location.origin + window.location.pathname;
  window.history.replaceState({}, document.title, cleanUrl);
}

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

/**
 * Disables all interactive elements to prevent simultaneous conversions.
 */
function setUiLock() {
  const dynamicElements = document.querySelectorAll(".play-btn");
  [...elementsToDisable, ...dynamicElements].forEach((el) => {
    el.disabled = true;
    el.setAttribute("aria-busy", "true");
  });
  if (uploadLabel) {
    uploadLabel.classList.add("disabled");
    uploadLabel.setAttribute("aria-busy", "true");
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
  if (uploadLabel) {
    uploadLabel.classList.remove("disabled");
    uploadLabel.setAttribute("aria-busy", "false");
  }
}

/**
 * Shows '✓ Playing' on the button, then resets its HTML after a delay and unlocks the UI.
 */
function resetButtonAfterDelay(button, originalText, delay = 2000) {
  button.textContent = "✓ Playing";
  setTimeout(() => {
    button.textContent = originalText;
    releaseUiLock();
  }, delay);
}

/**
 * Shows loading spinner on a button and returns its original text content.
 */
function showButtonLoadingAndGetOriginal(button) {
  const originalText = button.textContent;
  button.innerHTML = "<span class=\"loading\"></span> Converting...";
  return originalText;
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
  // Prevent drop if upload label is disabled (UI locked)
  if (uploadLabel && uploadLabel.classList.contains("disabled")) {
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

  // Make label keyboard accessible
  uploadLabel.addEventListener("keydown", (e) => {
    if (e.key === "Enter" || e.key === " ") {
      e.preventDefault();
      fileInput.click();
    }
  });
}

// Upload File
async function handleFileUpload(file) {
  // Hide share button for uploaded files (not shareable via URL)
  updateShareButton(false);

  const formData = new FormData();
  formData.append("file", file);

  await performConversion(
    "/upload",
    { method: "POST", body: formData },
    uploadLabel, // The button/label element
    "Uploading and converting...",
    "✓ {moduleName} uploaded and converted, ready to play"
  );
}

// Perform a conversion (upload, URL, or example)
async function performConversion(endpoint, options, button, initialStatusMessage, successMessageTemplate, moduleNameOverride, onSuccessCallback = () => {}) {
  setUiLock();
  const originalBtnText = showButtonLoadingAndGetOriginal(button);
  showStatus(initialStatusMessage, "info");

  try {
    const response = await fetch(endpoint, options);
    const data = await response.json();

    if (response.ok) {
      const moduleName = moduleNameOverride || data.module_name || data.filename;
      const statusMessage = getCacheStatusMessage(data, moduleName, successMessageTemplate.replace("{moduleName}", moduleName));
      showStatus(statusMessage, "success");
      playFile(
        data.file_id,
        moduleName,
        data.play_url,
        data.download_url,
        data.player_format || "Module",
        data.audio_format || "wav",
        data.module_format,
        data.subsongs,
        data.subsong_durations || []
      );
      if (onSuccessCallback) {
        onSuccessCallback();
      }
      resetButtonAfterDelay(button, originalBtnText);
      return; // on success, the function ends here.
    } else {
      showStatus(`✗ Error: ${data.error}`, "error");
    }
  } catch (error) {
    showStatus(`✗ Conversion failed: ${error.message}`, "error");
  }
  // This part is only reached if the conversion failed
  // (i.e., if `response.ok` was false or an error was thrown).
  button.textContent = originalBtnText;
  releaseUiLock();
}

// URL Form
function setupUrlForm() {
  urlSubmit.addEventListener("click", handleUrlConvert);
  urlInput.addEventListener("keypress", (e) => {
    if (e.key === "Enter") {
      handleUrlConvert();
    }
  });
  sampleUrlInput.addEventListener("keypress", (e) => {
    if (e.key === "Enter") {
      handleUrlConvert();
    }
  });
}

// Share Button
function setupShareButton() {
  shareBtn.addEventListener("click", handleShare);
}

async function handleShare() {
  if (!currentShareableUrl) {
    return;
  }

  // Build share URL
  const baseUrl = window.location.origin + window.location.pathname;
  let shareUrl = `${baseUrl}?url=${encodeURIComponent(currentShareableUrl)}`;

  if (currentShareableSampleUrl) {
    shareUrl += `&sample=${encodeURIComponent(currentShareableSampleUrl)}`;
  }

  // Copy to clipboard
  try {
    await navigator.clipboard.writeText(shareUrl);
    const originalText = shareBtn.textContent;
    shareBtn.textContent = "✓ Copied!";
    setTimeout(() => {
      shareBtn.textContent = originalText;
    }, 2000);
  } catch (err) {
    // Fallback for older browsers or insecure contexts
    showStatus("Failed to copy link to clipboard", "warning");
  }
}

function updateShareButton(show) {
  if (show && currentShareableUrl) {
    shareBtn.style.display = "inline-block";
  } else {
    shareBtn.style.display = "none";
    currentShareableUrl = null;
    currentShareableSampleUrl = null;
  }
}

async function handleUrlConvert() {
  const url = urlInput.value.trim();
  const sampleUrl = sampleUrlInput.value.trim();

  if (!url) {
    showStatus("Please enter a URL", "warning");
    return;
  }

  // Store URLs for share button
  currentShareableUrl = url;
  currentShareableSampleUrl = sampleUrl || null;

  const body = { url };
  let initialStatusMessage = "Downloading and converting...";
  let successMessageTemplate = "✓ {moduleName} downloaded and converted, ready to play";

  if (sampleUrl) {
    // Specific for dual-file
    body.sample_url = sampleUrl;
    initialStatusMessage = "Downloading and converting dual-file module...";
    successMessageTemplate = "✓ {moduleName} (dual-file) downloaded and converted, ready to play";
  }

  await performConversion(
    "/convert-url",
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    },
    urlSubmit,
    initialStatusMessage,
    successMessageTemplate,
    null, // moduleNameOverride
    () => {
      urlInput.value = "";
      sampleUrlInput.value = "";
      // Show share button after successful URL conversion
      updateShareButton(true);
    }
  );
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
  // Store URLs for share button (examples have url and optional sample_url)
  currentShareableUrl = example.url;
  currentShareableSampleUrl = example.sample_url || null;

  await performConversion(
    `/play-example/${example.id}`,
    { method: "POST" },
    button,
    `Converting ${example.name}...`,
    "✓ {moduleName} converted and ready to play",
    example.name, // Override module name to ensure it's displayed correctly
    () => {
      // Show share button after successful example conversion
      updateShareButton(true);
    }
  );
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
  subsongs = "1",
  subsongDurations = []
) {
  currentDownloadUrl = downloadUrl;
  currentSubsongs = parseInt(subsongs) || 1;
  currentSubsongDurations = subsongDurations || [];

  audioPlayer.src = playUrl;

  // Build current track display: moduleName + subsongs if more than 1
  let trackDisplay = moduleName;
  if (subsongs && parseInt(subsongs) > 1) {
    trackDisplay += ` (${subsongs} subsongs)`;
  }
  currentTrack.textContent = trackDisplay;

  // Update subsong navigation
  updateSubsongNavigation();

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

  audioPlayer.play().then(() => {
    // On successful autoplay, set focus to audio player for keyboard control
    audioPlayer.focus();
  }).catch((err) => {
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

    // Set up subsong navigation with media controls (prev/next track buttons)
    navigator.mediaSession.setActionHandler("previoustrack", () => {
      if (currentSubsongs > 1 && currentSubsongDurations.length > 0) {
        navigateToPreviousSubsong();
      }
    });

    navigator.mediaSession.setActionHandler("nexttrack", () => {
      if (currentSubsongs > 1 && currentSubsongDurations.length > 0) {
        navigateToNextSubsong();
      }
    });
  }
}

// Subsong Navigation
function updateSubsongNavigation() {
  const container = document.getElementById("subsong-navigation");
  if (!container) return;

  // Clear existing content
  container.innerHTML = "";

  // Only show navigation if there are multiple subsongs with duration data
  if (currentSubsongs <= 1 || currentSubsongDurations.length === 0) {
    container.style.display = "none";
    currentSubsongIndex = 0;
    return;
  }

  container.style.display = "flex";
  currentSubsongIndex = 0;

  // Track which subsong we're in based on playback time
  audioPlayer.addEventListener("timeupdate", updateCurrentSubsongIndex);

  // Create subsong buttons
  const buttonsContainer = document.createElement("div");
  buttonsContainer.className = "subsong-buttons";

  // Calculate cumulative start times for each subsong
  let cumulativeTime = 0;
  const subsongStartTimes = [];

  for (let i = 0; i < currentSubsongDurations.length; i++) {
    subsongStartTimes.push(cumulativeTime);
    cumulativeTime += currentSubsongDurations[i];

    const button = document.createElement("button");
    button.type = "button";
    button.className = "btn btn-subsong";
    button.textContent = `${i + 1}`;
    button.title = `Jump to subsong ${i + 1} (${formatTime(currentSubsongDurations[i])})`;

    const startTime = subsongStartTimes[i];
    button.addEventListener("click", () => {
      jumpToSubsong(startTime);
    });

    buttonsContainer.appendChild(button);
  }

  const label = document.createElement("span");
  label.className = "subsong-label";
  label.textContent = "Jump to subsong: ";

  container.appendChild(label);
  container.appendChild(buttonsContainer);
}

function jumpToSubsong(startTime) {
  if (audioPlayer) {
    audioPlayer.currentTime = startTime;
    if (audioPlayer.paused) {
      audioPlayer.play().catch(err => {
        console.error("Playback error:", err);
      });
    }
  }
}

function formatTime(seconds) {
  if (!seconds || seconds === 0) return "0:00";
  const mins = Math.floor(seconds / 60);
  const secs = Math.floor(seconds % 60);
  return `${mins}:${secs.toString().padStart(2, "0")}`;
}

function updateCurrentSubsongIndex() {
  if (!audioPlayer || currentSubsongDurations.length === 0) return;

  const currentTime = audioPlayer.currentTime;
  let cumulativeTime = 0;

  for (let i = 0; i < currentSubsongDurations.length; i++) {
    cumulativeTime += currentSubsongDurations[i];
    if (currentTime < cumulativeTime) {
      currentSubsongIndex = i;
      return;
    }
  }
  // If we're past all subsongs, we're on the last one
  currentSubsongIndex = currentSubsongDurations.length - 1;
}

function navigateToPreviousSubsong() {
  if (currentSubsongIndex > 0) {
    // Calculate start time of previous subsong
    let startTime = 0;
    for (let i = 0; i < currentSubsongIndex - 1; i++) {
      startTime += currentSubsongDurations[i];
    }
    jumpToSubsong(startTime);
  } else {
    // If at first subsong, restart it
    audioPlayer.currentTime = 0;
  }
}

function navigateToNextSubsong() {
  if (currentSubsongIndex < currentSubsongDurations.length - 1) {
    // Calculate start time of next subsong
    let startTime = 0;
    for (let i = 0; i <= currentSubsongIndex; i++) {
      startTime += currentSubsongDurations[i];
    }
    jumpToSubsong(startTime);
  }
}

// Download Button
function setupDownloadButton() {
  downloadBtn.addEventListener("click", async () => {
    if (currentDownloadUrl) {
      // Lock button and show spinner
      downloadBtn.disabled = true;
      const originalText = downloadBtn.textContent;
      downloadBtn.innerHTML = "<span class=\"loading\"></span> Preparing download...";

      try {
        const response = await fetch(currentDownloadUrl);
        const contentType = response.headers.get("content-type") || "";
        if (contentType.includes("application/json")) {
          const data = await response.json();
          showStatus(`✗ Error: ${data.error || "Rate limit exceeded"}`, "error");
          downloadBtn.textContent = originalText;
          downloadBtn.disabled = false;
        } else if (response.status === 206 && response.headers.get("content-length") === "0") {
          // Server sent empty 206 prompt for large file - download with range requests
          const contentRange = response.headers.get("content-range");
          const fileSizeMatch = contentRange ? contentRange.match(/\/(\d+)$/) : null;
          const fileSize = fileSizeMatch ? parseInt(fileSizeMatch[1]) : null;

          if (!fileSize) {
            showStatus("✗ Download failed: Invalid server response", "error");
            downloadBtn.textContent = originalText;
            downloadBtn.disabled = false;
            return;
          }

          // Extract filename from Content-Disposition header
          let filename = "downloaded_file";
          const disposition = response.headers.get("content-disposition");
          if (disposition && disposition.includes("filename=")) {
            filename = disposition.split("filename=")[1].replace(/["']/g, "").trim();
          }

          downloadBtn.innerHTML = "<span class=\"loading\"></span> Downloading...";
          showStatus("Downloading large file...", "info");

          try {
            await downloadWithRangeRequests(currentDownloadUrl, filename, fileSize);
            showStatus("Download complete", "success");
            // Re-enable after short delay to allow download window to pop up
            setTimeout(() => {
              downloadBtn.textContent = originalText;
              downloadBtn.disabled = false;
            }, 1000);
          } catch (error) {
            showStatus(`✗ Download failed: ${error.message}`, "error");
            downloadBtn.textContent = originalText;
            downloadBtn.disabled = false;
          }
        } else if (response.ok) {
          // Standard download for small files
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
          // Re-enable after short delay to allow download window to pop up
          setTimeout(() => {
            downloadBtn.textContent = originalText;
            downloadBtn.disabled = false;
          }, 1000);
        } else {
          showStatus("✗ Download failed: Server error", "error");
          downloadBtn.textContent = originalText;
          downloadBtn.disabled = false;
        }
      } catch (error) {
        showStatus(`✗ Download failed: ${error.message}`, "error");
        downloadBtn.textContent = originalText;
        downloadBtn.disabled = false;
      }
    }
  });
}

function getCacheStatusMessage(data, moduleName, nonCacheMessage) {
  if (data.url_cached && data.cached) {
    return `✓ ${moduleName} loaded from URL & conversion cache and ready to play`;
  }
  if (data.cached) {
    return `✓ ${moduleName} loaded from conversion cache and ready to play`;
  }
  if (data.url_cached) {
    return `✓ ${moduleName} loaded from URL cache, converted and ready to play`;
  }
  return nonCacheMessage;
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
    audioPlayer.focus(); // Set focus after user-initiated play
  });
}

// Load Version Info
async function loadVersionInfo() {
  try {
    const response = await fetch("/health");
    const data = await response.json();
    const versionElement = document.getElementById("version-info");

    // Build version info string
    const parts = [];

    // Add UADE version if available
    if (data.uade_version && data.uade_version !== "unknown") {
      parts.push(`UADE ${data.uade_version}`);
    }

    // Add git commit version if available
    if (data.version && data.version !== "unknown") {
      parts.push(`Build: ${data.version.substring(0, 7)}`);
    }

    if (parts.length > 0) {
      versionElement.textContent = "";

      // Add UADE version as plain text
      if (data.uade_version && data.uade_version !== "unknown") {
        versionElement.appendChild(document.createTextNode(`UADE ${data.uade_version}`));
      }

      // Add separator and git link if both exist
      if (data.uade_version && data.uade_version !== "unknown" && data.version && data.version !== "unknown") {
        versionElement.appendChild(document.createTextNode(" • "));
      }

      // Add git commit as clickable link
      if (data.version && data.version !== "unknown") {
        const link = document.createElement("a");
        link.href = `https://github.com/rib1/uade-docker/commit/${encodeURIComponent(data.version)}`;
        link.target = "_blank";
        link.style.color = "#666";
        link.style.textDecoration = "none";
        link.textContent = `Build ${data.version.substring(0, 7)}`;
        versionElement.appendChild(link);
      }
    } else {
      versionElement.textContent = "";
    }
  } catch (error) {
    console.error("Failed to load version info:", error);
    document.getElementById("version-info").textContent = "";
  }
}
