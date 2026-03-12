// UADE Web Player - Client Side JavaScript

// State
let currentDownloadUrl = null;
let currentSubsongDurations = [];
let currentSubsongs = 1;
let currentSubsongIndex = 0;
let currentShareableUrl = null; // For shareable URLs feature
let currentShareableSampleUrl = null;
let currentPlayableTrackName = null;
let currentPlayableTrackFormat = null;
let playlistTracks = [];
let currentPlaylistTrackId = null;
let isPlaylistPanelOpen = false;
let isUiLocked = false;
const SAVED_QUEUE_STORAGE_KEY = "uade.savedQueue.v1";
const QUEUE_URL_WARNING_LENGTH = 2000;

// DOM Elements
const dropZone = document.getElementById("drop-zone");
const fileInput = document.getElementById("module-file-input");
const urlInput = document.getElementById("url-input");
const urlSubmit = document.getElementById("url-submit");
const playlistAddUrlBtn = document.getElementById("playlist-add-url-btn");
const sampleUrlInput = document.getElementById("sample-url-input");
const uploadLabel = document.getElementById("upload-btn"); // The label acts as the button
const audioPlayer = document.getElementById("audio-player");
const playerSection = document.getElementById("player-section");
const currentTrack = document.getElementById("current-track");
const trackFormat = document.getElementById("track-format");
const downloadBtn = document.getElementById("download-btn");
const shareBtn = document.getElementById("share-btn");
const addCurrentToPlaylistBtn = document.getElementById("add-current-to-playlist-btn");
const examplesGrid = document.getElementById("examples-grid");
const statusContainer = document.getElementById("status-container");
const playlistLauncher = document.getElementById("playlist-launcher");
const playlistLauncherBar = document.querySelector(".playlist-launcher-bar");
const playlistLauncherHitbox = document.getElementById("playlist-launcher-hitbox");
const playlistLauncherLabel = document.getElementById("playlist-launcher-label");
const playlistLauncherNext = document.getElementById("playlist-launcher-next");
const playlistToggleBtn = document.getElementById("playlist-toggle-btn");
const playlistPrevBtn = document.getElementById("playlist-prev-btn");
const playlistNextBtn = document.getElementById("playlist-next-btn");
const playlistSaveBtn = document.getElementById("playlist-save-btn");
const playlistBookmarkBtn = document.getElementById("playlist-bookmark-btn");
const playlistShareBtn = document.getElementById("playlist-share-btn");
const playlistPanel = document.getElementById("playlist-panel");
const playlistClearBtn = document.getElementById("playlist-clear-btn");
const playlistList = document.getElementById("playlist-list");
const playlistEmptyState = document.getElementById("playlist-empty-state");
const playlistPanelSummary = document.getElementById("playlist-panel-summary");
const mobileQueueMediaQuery = window.matchMedia("(max-width: 600px)");

const elementsToDisable = [
  fileInput,
  urlInput,
  urlSubmit,
  sampleUrlInput,
  playlistAddUrlBtn,
];

function extractDownloadFilename(contentDisposition, fallback = "downloaded_file") {
  if (!contentDisposition) {
    return fallback;
  }

  const filenameStarMatch = contentDisposition.match(/filename\*\s*=\s*UTF-8''([^;]+)/i);
  if (filenameStarMatch) {
    try {
      return decodeURIComponent(filenameStarMatch[1]).replace(/[/\\]/g, "_").trim() || fallback;
    } catch {
      return fallback;
    }
  }

  const filenameMatch = contentDisposition.match(/filename\s*=\s*"([^"]+)"|filename\s*=\s*([^;]+)/i);
  const rawFilename = filenameMatch ? (filenameMatch[1] || filenameMatch[2]) : "";
  const sanitizedFilename = rawFilename.replace(/["']/g, "").replace(/[/\\]/g, "_").trim();
  return sanitizedFilename || fallback;
}

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
  setupPlaylistControls();
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

  audioPlayer.addEventListener("ended", handlePlaylistEnded);

  restoreSavedOrSharedQueue();
  renderPlaylist();
  // Check for shared URL parameter and auto-convert
  checkSharedUrlParameter();
  updatePlaylistMobileLabels();
  mobileQueueMediaQuery.addEventListener("change", renderPlaylist);
  updatePlayerSectionVisibility();
  updatePlayerMetaVisibility();
  updatePrimaryPlayerActions();
});

// Check for ?url= parameter for shareable URLs
function checkSharedUrlParameter() {
  const urlParams = new URLSearchParams(window.location.search);
  if (urlParams.get("queue")) {
    return;
  }
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

function updatePlayerSectionVisibility() {
  const hasPlaylist = playlistTracks.length > 0;
  const hasPlayableTrack = Boolean(audioPlayer.getAttribute("src"));
  playerSection.style.display = hasPlaylist || hasPlayableTrack ? "block" : "none";
}

function updatePlayerMetaVisibility() {
  const hasFormatText = Boolean(trackFormat.textContent.trim());
  trackFormat.hidden = !hasFormatText;
  trackFormat.style.display = hasFormatText ? "inline-block" : "none";
}

function updatePrimaryPlayerActions() {
  downloadBtn.disabled = isUiLocked || !currentDownloadUrl;
  shareBtn.disabled = isUiLocked || !currentShareableUrl;
  addCurrentToPlaylistBtn.disabled = isUiLocked || !currentShareableUrl;
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
  isUiLocked = true;
  const dynamicElements = document.querySelectorAll(
    ".play-btn, .add-playlist-btn, .playlist-play-btn, .playlist-remove-btn, .playlist-move-btn, .playlist-toggle-btn, .playlist-prev-btn, .playlist-next-btn, .playlist-save-btn, .playlist-bookmark-btn, .playlist-share-btn, .playlist-clear-btn",
  );
  [...elementsToDisable, ...dynamicElements].forEach((el) => {
    if (!el) {
      return;
    }
    el.disabled = true;
    el.setAttribute("aria-busy", "true");
  });
  addCurrentToPlaylistBtn.disabled = true;
  addCurrentToPlaylistBtn.setAttribute("aria-busy", "true");
  downloadBtn.disabled = true;
  downloadBtn.setAttribute("aria-busy", "true");
  shareBtn.disabled = true;
  shareBtn.setAttribute("aria-busy", "true");
  if (uploadLabel) {
    uploadLabel.classList.add("disabled");
    uploadLabel.setAttribute("aria-busy", "true");
  }

  // Keep queue controls in sync with the common lock state immediately.
  renderPlaylist();
}

/**
 * Re-enables all interactive elements after a conversion is complete.
 */
function releaseUiLock() {
  isUiLocked = false;
  const dynamicElements = document.querySelectorAll(
    ".play-btn, .add-playlist-btn, .playlist-play-btn, .playlist-remove-btn, .playlist-move-btn, .playlist-toggle-btn, .playlist-prev-btn, .playlist-next-btn, .playlist-save-btn, .playlist-bookmark-btn, .playlist-share-btn, .playlist-clear-btn",
  );
  [...elementsToDisable, ...dynamicElements].forEach((el) => {
    if (!el) {
      return;
    }
    el.disabled = false;
    el.setAttribute("aria-busy", "false");
  });
  addCurrentToPlaylistBtn.setAttribute("aria-busy", "false");
  downloadBtn.setAttribute("aria-busy", "false");
  shareBtn.setAttribute("aria-busy", "false");
  if (uploadLabel) {
    uploadLabel.classList.remove("disabled");
    uploadLabel.setAttribute("aria-busy", "false");
  }

  // Restore primary player controls immediately, even if nothing else re-renders.
  updatePrimaryPlayerActions();

  // Re-apply queue state after the general UI unlock.
  renderPlaylist();
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

function setButtonLoadingState(button, loadingText) {
  const spinner = document.createElement("span");
  spinner.className = "loading";
  button.replaceChildren(spinner, document.createTextNode(` ${loadingText}`));
}

/**
 * Shows loading spinner on a button and returns its original text content.
 */
function showButtonLoadingAndGetOriginal(button, loadingText = "Converting...") {
  const originalText = button.textContent;
  setButtonLoadingState(button, loadingText);
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

async function performProbe(url, sampleUrl, button) {
  setUiLock();
  const originalBtnText = showButtonLoadingAndGetOriginal(button, "Checking...");
  showStatus("Checking module metadata...", "info");

  try {
    const payload = { url };
    if (sampleUrl) {
      payload.sample_url = sampleUrl;
    }

    const response = await fetch("/probe-url", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const contentType = response.headers.get("content-type") || "";
    const isJsonResponse = contentType.includes("application/json");

    if (!isJsonResponse) {
      throw new Error("Probe returned a non-JSON response");
    }

    const data = await response.json();

    if (!response.ok) {
      showStatus(`✗ Error: ${data.error || "Probe failed"}`, "error");
      return null;
    }

    if (!data.ok || !data.playable || !(data.module_name || data.filename)) {
      throw new Error("Probe returned incomplete module metadata");
    }

    showStatus(`✓ ${data.module_name || data.filename} is ready to add`, "success");
    return data;
  } catch (error) {
    showStatus(`✗ Probe failed: ${error.message}`, "error");
    return null;
  } finally {
    button.textContent = originalBtnText;
    releaseUiLock();
  }
}

// URL Form
function setupUrlForm() {
  urlSubmit.addEventListener("click", handleUrlConvert);
  playlistAddUrlBtn.addEventListener("click", handleAddUrlToPlaylist);
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

function setupPlaylistControls() {
  playlistLauncherHitbox.addEventListener("click", togglePlaylistPanel);
  playlistToggleBtn.addEventListener("click", togglePlaylistPanel);
  playlistSaveBtn.addEventListener("click", savePlaylistLocally);
  playlistBookmarkBtn.addEventListener("click", bookmarkPlaylist);
  playlistShareBtn.addEventListener("click", sharePlaylist);
  playlistClearBtn.addEventListener("click", clearPlaylist);
  playlistPrevBtn.addEventListener("click", (event) => {
    event.stopPropagation();
    playPreviousPlaylistTrack();
  });
  playlistNextBtn.addEventListener("click", (event) => {
    event.stopPropagation();
    playNextPlaylistTrack();
  });
  addCurrentToPlaylistBtn.addEventListener("click", handleAddCurrentToPlaylist);
}

function getSerializablePlaylistTracks() {
  return playlistTracks.map((track) => ({
    n: track.name,
    u: track.url,
    s: track.sample_url || null,
    f: track.format || "Module",
    o: track.source || "queue",
  }));
}

function buildQueuePayload() {
  return {
    v: 1,
    t: getSerializablePlaylistTracks(),
  };
}

function sanitizePlaylistTrack(track) {
  if (!track || typeof track !== "object") {
    return null;
  }

  const rawUrl = typeof track.u === "string" ? track.u : track.url;
  if (typeof rawUrl !== "string") {
    return null;
  }

  const url = rawUrl.trim();
  if (!url) {
    return null;
  }

  const rawSampleUrl = typeof track.s === "string" ? track.s : track.sample_url;
  const rawName = typeof track.n === "string" ? track.n : track.name;
  const rawFormat = typeof track.f === "string" ? track.f : track.format;
  const rawSource = typeof track.o === "string" ? track.o : track.source;

  const sampleUrl = typeof rawSampleUrl === "string" ? rawSampleUrl.trim() : "";
  const name = typeof rawName === "string" && rawName.trim() ? rawName.trim() : "Module";
  const format = typeof rawFormat === "string" && rawFormat.trim() ? rawFormat.trim() : "Module";
  const source = typeof rawSource === "string" && rawSource.trim() ? rawSource.trim() : "queue";

  return {
    id: createPlaylistTrackId(),
    name,
    url,
    sample_url: sampleUrl || null,
    format,
    source,
  };
}

function encodeQueuePayload(queuePayload) {
  const bytes = new TextEncoder().encode(JSON.stringify(queuePayload));
  let binary = "";
  bytes.forEach((byte) => {
    binary += String.fromCharCode(byte);
  });
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/u, "");
}

function decodeQueuePayload(encodedPayload) {
  const padded = encodedPayload.replace(/-/g, "+").replace(/_/g, "/");
  const base64 = padded + "=".repeat((4 - (padded.length % 4)) % 4);
  const binary = atob(base64);
  const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
  return JSON.parse(new TextDecoder().decode(bytes));
}

function buildQueueUrlFromPayload(queuePayload) {
  const baseUrl = window.location.origin + window.location.pathname;
  return `${baseUrl}?queue=${encodeURIComponent(encodeQueuePayload(queuePayload))}`;
}

function warnIfQueueUrlIsLong(queueUrl) {
  if (queueUrl.length <= QUEUE_URL_WARNING_LENGTH) {
    return false;
  }

  showStatus(
    `Queue URL is long (${queueUrl.length} chars) and may not share or bookmark reliably`,
    "warning",
  );
  return true;
}

function getStoredQueue() {
  try {
    return window.localStorage.getItem(SAVED_QUEUE_STORAGE_KEY);
  } catch (_error) {
    showStatus("Browser storage is unavailable; saved queue restore was skipped", "warning");
    return null;
  }
}

function setStoredQueue(serializedQueue) {
  try {
    window.localStorage.setItem(SAVED_QUEUE_STORAGE_KEY, serializedQueue);
    return true;
  } catch (_error) {
    showStatus("Browser storage is unavailable; queue was not saved locally", "warning");
    return false;
  }
}

function clearStoredQueue(options = {}) {
  try {
    window.localStorage.removeItem(SAVED_QUEUE_STORAGE_KEY);
    return true;
  } catch (_error) {
    if (!options.silent) {
      showStatus("Browser storage is unavailable; saved queue could not be cleared", "warning");
    }
    return false;
  }
}

function savePlaylistLocally() {
  if (playlistTracks.length === 0) {
    showStatus("Queue is empty", "warning");
    return;
  }

  const payload = buildQueuePayload();
  if (!setStoredQueue(JSON.stringify(payload))) {
    return;
  }
  showStatus("✓ Queue saved locally", "success");
}

function bookmarkPlaylist() {
  if (playlistTracks.length === 0) {
    showStatus("Queue is empty", "warning");
    return;
  }

  const payload = buildQueuePayload();
  const queueUrl = buildQueueUrlFromPayload(payload);
  const bookmarkUrl = new URL(window.location.href);
  const encodedQueue = new URL(queueUrl).searchParams.get("queue");

  if (bookmarkUrl.searchParams.get("queue") === encodedQueue) {
    bookmarkUrl.searchParams.delete("queue");
    window.history.replaceState({}, document.title, bookmarkUrl.toString());
    showStatus("✓ Queue bookmark removed from page URL", "success");
    return;
  }

  warnIfQueueUrlIsLong(queueUrl);
  bookmarkUrl.search = "";
  bookmarkUrl.searchParams.set("queue", encodedQueue);
  window.history.replaceState({}, document.title, bookmarkUrl.toString());
  showStatus("✓ Queue added to page URL for bookmarking", "success");
}

async function sharePlaylist() {
  if (playlistTracks.length === 0) {
    showStatus("Queue is empty", "warning");
    return;
  }

  const payload = buildQueuePayload();
  const shareUrl = buildQueueUrlFromPayload(payload);

  warnIfQueueUrlIsLong(shareUrl);

  try {
    await navigator.clipboard.writeText(shareUrl);
    const originalText = playlistShareBtn.textContent;
    playlistShareBtn.textContent = `${originalText} (Copied)`;
    setTimeout(() => {
      playlistShareBtn.textContent = originalText;
    }, 2000);
  } catch (_err) {
    showStatus("Failed to copy queue link to clipboard", "warning");
  }
}

function loadPlaylistFromPayload(payload) {
  const tracks = Array.isArray(payload?.t) ? payload.t : payload?.tracks;
  if (!payload || typeof payload !== "object" || !Array.isArray(tracks)) {
    throw new Error("Invalid queue payload");
  }

  const restoredTracks = tracks
    .map(sanitizePlaylistTrack)
    .filter((track) => track !== null);

  if (restoredTracks.length === 0) {
    throw new Error("Queue payload does not contain any playable tracks");
  }

  playlistTracks = restoredTracks;
  currentPlaylistTrackId = null;
  isPlaylistPanelOpen = false;
  renderPlaylist();
}

function restoreSavedOrSharedQueue() {
  const urlParams = new URLSearchParams(window.location.search);
  const sharedQueue = urlParams.get("queue");

  if (sharedQueue) {
    try {
      loadPlaylistFromPayload(decodeQueuePayload(sharedQueue));
      showStatus("✓ Queue loaded from shared link", "success");
    } catch (_error) {
      showStatus("✗ Failed to load shared queue", "error");
    }
    return;
  }

  const savedQueue = getStoredQueue();
  if (!savedQueue) {
    return;
  }

  try {
    loadPlaylistFromPayload(JSON.parse(savedQueue));
    showStatus("✓ Restored saved queue", "success");
  } catch (_error) {
    clearStoredQueue({ silent: true });
  }
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
    currentPlayableTrackName = null;
    currentPlayableTrackFormat = null;
  }
  updatePrimaryPlayerActions();
}

function handleAddCurrentToPlaylist() {
  if (!currentShareableUrl) {
    showStatus("Current track cannot be added to queue", "warning");
    return;
  }

  const name = currentPlayableTrackName || currentTrack.textContent.trim() || "Module";
  addTrackToPlaylist({
    id: createPlaylistTrackId(),
    name,
    url: currentShareableUrl,
    sample_url: currentShareableSampleUrl || null,
    format: currentPlayableTrackFormat || "Module",
    source: "current",
  });
  showStatus(`✓ Added ${name} to queue`, "success");
}

async function handleUrlConvert() {
  const url = urlInput.value.trim();
  const sampleUrl = sampleUrlInput.value.trim();

  if (!url) {
    showStatus("Please enter a URL", "warning");
    return;
  }

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
      currentShareableUrl = url;
      currentShareableSampleUrl = sampleUrl || null;
      urlInput.value = "";
      sampleUrlInput.value = "";
      // Show share button after successful URL conversion
      updateShareButton(true);
    }
  );
}

async function handleAddUrlToPlaylist() {
  const url = urlInput.value.trim();
  const sampleUrl = sampleUrlInput.value.trim();

  if (!url) {
    showStatus("Please enter a URL", "warning");
    return;
  }

  const probeData = await performProbe(url, sampleUrl, playlistAddUrlBtn);
  if (!probeData) {
    return;
  }

  const shouldAutoPlay = playlistTracks.length === 0 && !audioPlayer.getAttribute("src");
  const track = {
    id: createPlaylistTrackId(),
    name: probeData.module_name || probeData.filename || "Module",
    url,
    sample_url: sampleUrl || null,
    format: probeData.module_format || probeData.player_format || "Module",
    source: "url",
  };
  addTrackToPlaylist(track);
  urlInput.value = "";
  sampleUrlInput.value = "";
  if (shouldAutoPlay) {
    void playPlaylistTrack(track.id, playlistAddUrlBtn);
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
      const actions = document.createElement("div");
      actions.className = "example-actions";

      const playBtn = document.createElement("button");
      playBtn.className = "play-btn";
      playBtn.setAttribute("type", "button");
      playBtn.setAttribute("data-example-id", example.id);
      playBtn.textContent = "▶ Play Now";
      playBtn.addEventListener("click", () =>
        handleExamplePlay(example, playBtn),
      );
      actions.appendChild(playBtn);

      const addBtn = document.createElement("button");
      addBtn.className = "play-btn add-playlist-btn";
      addBtn.setAttribute("type", "button");
      addBtn.textContent = "+ Add To Queue";
      addBtn.addEventListener("click", () => handleExampleAddToPlaylist(example, addBtn));
      actions.appendChild(addBtn);

      card.appendChild(actions);

      examplesGrid.appendChild(card);
    });
  } catch (error) {
    console.error("Failed to load examples:", error);
  }
}

// Play Example
async function handleExamplePlay(example, button) {
  await performConversion(
    `/play-example/${example.id}`,
    { method: "POST" },
    button,
    `Converting ${example.name}...`,
    "✓ {moduleName} converted and ready to play",
    example.name, // Override module name to ensure it's displayed correctly
    () => {
      currentShareableUrl = example.url;
      currentShareableSampleUrl = example.sample_url || null;
      // Show share button after successful example conversion
      updateShareButton(true);
    }
  );
}

function handleExampleAddToPlaylist(example, button) {
  const shouldAutoPlay = playlistTracks.length === 0 && !audioPlayer.getAttribute("src");
  const track = {
    id: createPlaylistTrackId(),
    name: example.name,
    url: example.url,
    sample_url: example.sample_url || null,
    format: example.format || example.type || "Module",
    source: "example",
  };
  addTrackToPlaylist(track);
  showStatus(`✓ Added ${example.name} to queue`, "success");
  if (shouldAutoPlay) {
    void playPlaylistTrack(track.id, button);
  }
}

function createPlaylistTrackId() {
  if (window.crypto && "randomUUID" in window.crypto) {
    return window.crypto.randomUUID();
  }
  return `playlist-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function addTrackToPlaylist(track) {
  playlistTracks.push(track);
  renderPlaylist();
}

function removeTrackFromPlaylist(trackId) {
  const removedIndex = playlistTracks.findIndex((track) => track.id === trackId);
  if (removedIndex === -1) {
    return;
  }

  playlistTracks = playlistTracks.filter((track) => track.id !== trackId);
  if (currentPlaylistTrackId === trackId) {
    currentPlaylistTrackId = null;
  }

  if (playlistTracks.length === 0) {
    setPlaylistPanelOpen(false);
    if (getStoredQueue()) {
      showStatus("Queue is empty. Saved local queue is still available.", "info");
    }
  }

  renderPlaylist();
}

function clearPlaylist() {
  if (playlistTracks.length === 0) {
    return;
  }

  playlistTracks = [];
  currentPlaylistTrackId = null;
  isPlaylistPanelOpen = false;
  clearStoredQueue();
  renderPlaylist();
  showStatus("✓ Queue cleared. Saved local queue was also removed.", "success");
}

function movePlaylistTrack(trackId, direction) {
  const currentIndex = playlistTracks.findIndex((track) => track.id === trackId);
  if (currentIndex === -1) {
    return;
  }

  const targetIndex = currentIndex + direction;
  if (targetIndex < 0 || targetIndex >= playlistTracks.length) {
    return;
  }

  const updatedTracks = [...playlistTracks];
  const [movedTrack] = updatedTracks.splice(currentIndex, 1);
  updatedTracks.splice(targetIndex, 0, movedTrack);
  playlistTracks = updatedTracks;
  renderPlaylist();
}

function renderPlaylist() {
  const hasPlaylist = playlistTracks.length > 0;
  const currentIndex = playlistTracks.findIndex((track) => track.id === currentPlaylistTrackId);
  const hasPreviousTrack = currentIndex > 0;
  const hasNextTrack =
    hasPlaylist && (currentIndex === -1 ? playlistTracks.length > 0 : currentIndex < playlistTracks.length - 1);
  playlistLauncher.hidden = !hasPlaylist;
  playlistLauncher.classList.toggle("expanded", isPlaylistPanelOpen && hasPlaylist);
  playlistLauncherHitbox.disabled = isUiLocked || !hasPlaylist;
  playlistLauncherHitbox.setAttribute("aria-label", isPlaylistPanelOpen ? "Hide queue" : "Open queue");
  playlistPanelSummary.textContent = `${playlistTracks.length} track${playlistTracks.length === 1 ? "" : "s"}`;
  playlistLauncherLabel.replaceChildren(
    Object.assign(document.createElement("strong"), { textContent: "Queue" }),
    document.createTextNode(` (${playlistTracks.length})`),
  );
  playlistLauncherNext.textContent = getPlaylistNextLabel();
  playlistToggleBtn.textContent = isPlaylistPanelOpen ? "Hide" : "Open";
  playlistToggleBtn.setAttribute("aria-label", isPlaylistPanelOpen ? "Hide queue" : "Open queue");
  playlistToggleBtn.disabled = isUiLocked || !hasPlaylist;
  playlistPrevBtn.disabled = isUiLocked || !hasPreviousTrack;
  playlistNextBtn.disabled = isUiLocked || !hasNextTrack;
  playlistSaveBtn.disabled = isUiLocked || !hasPlaylist;
  playlistBookmarkBtn.disabled = isUiLocked || !hasPlaylist;
  playlistShareBtn.disabled = isUiLocked || !hasPlaylist;
  playlistClearBtn.disabled = isUiLocked || !hasPlaylist;

  playlistList.replaceChildren();
  playlistEmptyState.hidden = playlistTracks.length > 0;

  playlistTracks.forEach((track, index) => {
    const item = document.createElement("div");
    item.className = "playlist-item";
    item.setAttribute("role", "listitem");
    item.setAttribute("aria-label", `Queue item ${index + 1}: ${track.name}`);
    if (track.id === currentPlaylistTrackId) {
      item.classList.add("active");
    }

    const main = document.createElement("div");
    main.className = "playlist-item-main";

    const title = document.createElement("div");
    title.className = "playlist-item-title";
    title.textContent = track.name;
    main.appendChild(title);

    const meta = document.createElement("div");
    meta.className = "playlist-item-meta";
    meta.textContent = track.format || "Module";
    main.appendChild(meta);

    const actions = document.createElement("div");
    actions.className = "playlist-item-actions";

    const playBtn = document.createElement("button");
    playBtn.type = "button";
    playBtn.className = "btn btn-secondary btn-small playlist-play-btn";
    playBtn.textContent = "Play";
    playBtn.setAttribute("aria-label", `Play ${track.name}`);
    playBtn.disabled = isUiLocked;
    playBtn.addEventListener("click", () => playPlaylistTrack(track.id, playBtn));
    actions.appendChild(playBtn);

    const removeBtn = document.createElement("button");
    removeBtn.type = "button";
    removeBtn.className = "btn btn-secondary btn-small playlist-remove-btn";
    removeBtn.textContent = mobileQueueMediaQuery.matches ? "Del" : "Remove";
    removeBtn.setAttribute("aria-label", `Remove ${track.name} from queue`);
    removeBtn.disabled = isUiLocked;
    removeBtn.addEventListener("click", () => removeTrackFromPlaylist(track.id));
    const moveUpBtn = document.createElement("button");
    moveUpBtn.type = "button";
    moveUpBtn.className = "btn btn-secondary btn-small playlist-move-btn";
    moveUpBtn.textContent = "↑";
    moveUpBtn.setAttribute("aria-label", `Move ${track.name} up in queue`);
    moveUpBtn.disabled = isUiLocked || index === 0;
    moveUpBtn.addEventListener("click", () => movePlaylistTrack(track.id, -1));
    actions.appendChild(moveUpBtn);

    const moveDownBtn = document.createElement("button");
    moveDownBtn.type = "button";
    moveDownBtn.className = "btn btn-secondary btn-small playlist-move-btn";
    moveDownBtn.textContent = "↓";
    moveDownBtn.setAttribute("aria-label", `Move ${track.name} down in queue`);
    moveDownBtn.disabled = isUiLocked || index === playlistTracks.length - 1;
    moveDownBtn.addEventListener("click", () => movePlaylistTrack(track.id, 1));
    actions.appendChild(moveDownBtn);

    actions.appendChild(removeBtn);

    item.appendChild(main);
    item.appendChild(actions);
    playlistList.appendChild(item);
  });

  playlistPanel.hidden = !isPlaylistPanelOpen || playlistTracks.length === 0;
  updatePlayerSectionVisibility();
  updatePrimaryPlayerActions();
  updatePlaylistMobileLabels();
}

function updatePlaylistMobileLabels() {
  const isMobileQueueLayout = mobileQueueMediaQuery.matches;
  playlistPrevBtn.textContent = isMobileQueueLayout ? "Prev" : "⏮";
  playlistNextBtn.textContent = isMobileQueueLayout ? "Next" : "⏭";
}

function setPlaylistPanelOpen(isOpen) {
  isPlaylistPanelOpen = isOpen && playlistTracks.length > 0;
  renderPlaylist();
}

function togglePlaylistPanel() {
  setPlaylistPanelOpen(!isPlaylistPanelOpen);
}

function getPlaylistNextLabel() {
  if (playlistTracks.length === 0) {
    return "";
  }

  const currentIndex = playlistTracks.findIndex((track) => track.id === currentPlaylistTrackId);
  const nextTrack = currentIndex >= 0 ? playlistTracks[currentIndex + 1] : playlistTracks[0];
  return nextTrack ? `Next: ${nextTrack.name}` : "End of playlist";
}

async function playPlaylistTrack(trackId, button) {
  const track = playlistTracks.find((candidate) => candidate.id === trackId);
  if (!track) {
    return;
  }

  const body = { url: track.url };
  if (track.sample_url) {
    body.sample_url = track.sample_url;
  }

  await performConversion(
    "/convert-url",
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    },
    button,
    `Converting ${track.name}...`,
    "✓ {moduleName} converted and ready to play",
    track.name,
    () => {
      currentPlaylistTrackId = trackId;
      currentShareableUrl = track.url;
      currentShareableSampleUrl = track.sample_url;
      updateShareButton(true);
      renderPlaylist();
    },
  );
}

function playNextPlaylistTrack() {
  if (playlistTracks.length === 0) {
    return;
  }

  const currentIndex = playlistTracks.findIndex((track) => track.id === currentPlaylistTrackId);
  const nextTrack = currentIndex >= 0 ? playlistTracks[currentIndex + 1] : playlistTracks[0];
  if (!nextTrack) {
    return;
  }

  const tempButton = document.createElement("button");
  tempButton.textContent = "Play";
  void playPlaylistTrack(nextTrack.id, tempButton);
}

function playPreviousPlaylistTrack() {
  if (playlistTracks.length === 0) {
    return;
  }

  const currentIndex = playlistTracks.findIndex((track) => track.id === currentPlaylistTrackId);
  if (currentIndex <= 0) {
    return;
  }

  const previousTrack = playlistTracks[currentIndex - 1];
  if (!previousTrack) {
    return;
  }

  const tempButton = document.createElement("button");
  tempButton.textContent = "Play";
  void playPlaylistTrack(previousTrack.id, tempButton);
}

function handlePlaylistEnded() {
  const currentIndex = playlistTracks.findIndex((track) => track.id === currentPlaylistTrackId);
  if (currentIndex === -1 || currentIndex >= playlistTracks.length - 1) {
    return;
  }
  playNextPlaylistTrack();
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
  currentPlayableTrackName = moduleName || "Module";
  currentPlayableTrackFormat = moduleFormat || playerFormat || "Module";
  currentSubsongs = parseInt(subsongs) || 1;
  currentSubsongDurations = subsongDurations || [];

  // Non-queue playback should not leave queue navigation highlighted as active.
  if (currentPlaylistTrackId !== null) {
    currentPlaylistTrackId = null;
    renderPlaylist();
  }

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
  updatePlayerMetaVisibility();

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
  updatePlayerSectionVisibility();
  updatePrimaryPlayerActions();
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
  container.replaceChildren();

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
      setButtonLoadingState(downloadBtn, "Preparing download...");

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
          const filename = extractDownloadFilename(
            response.headers.get("content-disposition")
          );

          setButtonLoadingState(downloadBtn, "Downloading...");
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
          const filename = extractDownloadFilename(
            response.headers.get("content-disposition")
          );
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
  const overlayIcon = document.createElement("div");
  overlayIcon.className = "play-button-overlay-icon";
  overlay.appendChild(overlayIcon);

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
