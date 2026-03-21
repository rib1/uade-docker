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
let currentLocalTrackData = null;
let playlistTracks = [];
let currentPlaylistTrackId = null;
let isPlaylistPanelOpen = false;
let isUiLocked = false;
const SAVED_QUEUE_STORAGE_KEY = "uade.savedQueue.v1";
const QUEUE_URL_WARNING_LENGTH = 2000;
const QUEUE_DROP_FILE_LIMIT = window.__UADE_CONFIG__
  ? window.__UADE_CONFIG__.queueDropFileLimit
  : 20;
const QUEUE_DROP_LIMIT_ENABLED = Number.isFinite(QUEUE_DROP_FILE_LIMIT) && QUEUE_DROP_FILE_LIMIT > 0;
const ADDED_TO_QUEUE_STATUS = (name) => `✓ Added ${name} to queue`;
const FILE_READ_TIMEOUT_MS = 5000;

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
const queueFileInput = document.getElementById("queue-file-input");
const queueBrowseBtn = document.getElementById("queue-browse-btn");
const mobileQueueMediaQuery = window.matchMedia("(max-width: 600px)");
const DRAG_UPLOAD_ICON = "⤴";

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

function filenameFromUrl(url) {
  try {
    const pathname = new URL(url).pathname;
    const lastSegment = decodeURIComponent(pathname.split("/").filter(Boolean).pop() || "");
    return lastSegment || "Module";
  } catch {
    return "Module";
  }
}

function getLocalTrackSourceIdentity(file) {
  return {
    originalLocalName: file?.name || null,
    originalLocalSize: Number.isFinite(file?.size) ? file.size : null,
    originalLocalType: file?.type || "",
  };
}

function matchesLocalTrackSource(track, file) {
  if (!track || track.source !== "local" || !file) {
    return false;
  }

  const trackName = track.localFile?.name || track.originalLocalName || null;
  const trackSize = Number.isFinite(track.localFile?.size) ? track.localFile.size : track.originalLocalSize;
  const trackType = track.localFile?.type || track.originalLocalType || "";

  return trackName === file.name && trackSize === file.size && trackType === file.type;
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
  initializeFileInputAccept();
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
  const playerContent = document.getElementById("player-content");
  const hasPlayableTrack = Boolean(audioPlayer.getAttribute("src"));
  playerContent.hidden = !hasPlayableTrack;
}

function updatePlayerMetaVisibility() {
  const hasFormatText = Boolean(trackFormat.textContent.trim());
  trackFormat.hidden = !hasFormatText;
  trackFormat.style.display = hasFormatText ? "inline-block" : "none";
}

function updatePrimaryPlayerActions() {
  syncUiLockState(isUiLocked);
}

async function readFileBufferWithTimeout(file, timeoutMs = FILE_READ_TIMEOUT_MS) {
  const timeoutPromise = new Promise((_, reject) => {
    window.setTimeout(() => {
      reject(new Error(`File read timed out after ${timeoutMs}ms`));
    }, timeoutMs);
  });

  return Promise.race([file.arrayBuffer(), timeoutPromise]);
}

async function materializeUploadFile(file) {
  const buffer = await readFileBufferWithTimeout(file);
  const normalizedType = file.type || "application/octet-stream";

  try {
    return new File([buffer], file.name, {
      type: normalizedType,
      lastModified: file.lastModified || Date.now(),
    });
  } catch (_err) {
    const blob = new Blob([buffer], { type: normalizedType });
    blob.name = file.name;
    blob.lastModified = file.lastModified || Date.now();
    return blob;
  }
}

/**
 * Synchronizes the disabled/busy state of lockable UI elements.
 */
function syncUiLockState(uiLocked) {
  isUiLocked = uiLocked;
  const hasPlaylist = playlistTracks.length > 0;
  const ariaBusy = uiLocked ? "true" : "false";

  const selectorMatchedElements = document.querySelectorAll(
    ".play-btn, .add-playlist-btn, .playlist-play-btn, .playlist-remove-btn, .playlist-move-btn, .playlist-toggle-btn, .playlist-prev-btn, .playlist-next-btn, .playlist-save-btn, .playlist-bookmark-btn, .playlist-share-btn, #playlist-clear-btn",
  );
  const lockableElements = [...elementsToDisable, ...selectorMatchedElements];
  const primaryActionButtons = [
    [downloadBtn, Boolean(currentDownloadUrl)],
    [shareBtn, Boolean(currentShareableUrl)],
    [addCurrentToPlaylistBtn, Boolean(currentShareableUrl || currentLocalTrackData)],
  ];

  lockableElements.forEach((el) => {
    if (!el) {
      return;
    }
    const contentDisabled = el.dataset.contentDisabled === "true";
    el.disabled = uiLocked || contentDisabled;
    el.setAttribute("aria-busy", ariaBusy);
  });

  // Handle specific elements not caught by the broad selector or requiring extra logic
  if (playlistLauncherHitbox) {
    playlistLauncherHitbox.disabled = uiLocked || !hasPlaylist;
  }
  if (playlistPanel) {
    playlistPanel.hidden = !isPlaylistPanelOpen || !hasPlaylist;
  }

  // Primary action buttons always depend on content availability AND the global lock.
  primaryActionButtons.forEach(([button, isAvailable]) => {
    button.disabled = uiLocked || !isAvailable;
    button.setAttribute("aria-busy", ariaBusy);
  });

  if (uploadLabel) {
    uploadLabel.classList.toggle("disabled", uiLocked);
    uploadLabel.setAttribute("aria-busy", ariaBusy);
  }
  if (queueFileInput) {
    queueFileInput.disabled = uiLocked;
    queueFileInput.setAttribute("aria-busy", ariaBusy);
  }
  if (queueBrowseBtn) {
    queueBrowseBtn.classList.toggle("disabled", uiLocked);
    queueBrowseBtn.setAttribute("aria-busy", ariaBusy);
    queueBrowseBtn.setAttribute("aria-disabled", uiLocked ? "true" : "false");
    queueBrowseBtn.tabIndex = uiLocked ? -1 : 0;
  }
  updatePlayerSectionVisibility();
}

function initializeFileInputAccept() {
  fileInput.removeAttribute("accept");
  queueFileInput.removeAttribute("accept");
}

function setDropCueActive(label, isActive) {
  if (!label || label.disabled || label.getAttribute("aria-busy") === "true") {
    return;
  }

  if (!label.dataset.defaultText) {
    label.dataset.defaultText = label.textContent;
  }

  label.textContent = isActive ? DRAG_UPLOAD_ICON : label.dataset.defaultText;
  label.dataset.dragCueActive = isActive ? "true" : "false";
}

function getButtonRestoreText(button, originalText) {
  if (button === queueBrowseBtn && queueBrowseBtn?.dataset.defaultText) {
    return queueBrowseBtn.dataset.defaultText;
  }

  return originalText;
}

/**
 * Shows '✓ Playing' on the button, then resets its HTML after a delay and unlocks the UI.
 */
function resetButtonAfterDelay(button, originalText, delay = 2000) {
  button.textContent = "✓ Playing";
  setTimeout(() => {
    button.textContent = originalText;
    syncUiLockState(false);
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
  let dragDepth = 0;

  ["dragenter", "dragover", "dragleave", "drop"].forEach((eventName) => {
    dropZone.addEventListener(eventName, preventDefaults, false);
  });

  function preventDefaults(e) {
    e.preventDefault();
    e.stopPropagation();
  }

  dropZone.addEventListener("dragenter", () => {
    dragDepth += 1;
    dropZone.classList.add("drag-over");
    setDropCueActive(uploadLabel, true);
  });

  dropZone.addEventListener("dragover", () => {
    dropZone.classList.add("drag-over");
    setDropCueActive(uploadLabel, true);
  });

  ["dragleave", "drop"].forEach((eventName) => {
    dropZone.addEventListener(eventName, () => {
      dragDepth = eventName === "drop" ? 0 : Math.max(0, dragDepth - 1);
      if (dragDepth === 0) {
        setDropCueActive(uploadLabel, false);
      }
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
    "✓ {moduleName} uploaded and converted, ready to play",
    null, // moduleNameOverride
    (data) => {
      currentLocalTrackData = {
        name: data.module_name || data.filename || file.name,
        playUrl: data.play_url,
        downloadUrl: data.download_url,
        audioFormat: data.audio_format || "wav",
        moduleFormat: data.module_format,
        playerFormat: data.player_format || "Module",
        subsongs: data.subsongs,
        subsongDurations: data.subsong_durations || [],
        localFile: file,
        moduleHash: data.module_hash || null,
        ...getLocalTrackSourceIdentity(file),
      };
      updatePrimaryPlayerActions();
    },
  );
}

// Perform a conversion (upload, URL, or example)
async function performConversion(
  endpoint,
  options,
  button,
  initialStatusMessage,
  successMessageTemplate,
  moduleNameOverride,
  onSuccessCallback = () => {},
  { uiAlreadyLocked = false, originalBtnText: providedOriginalBtnText = null } = {},
) {
  let originalBtnText = providedOriginalBtnText;
  if (!uiAlreadyLocked || originalBtnText === null) {
    syncUiLockState(true);
    originalBtnText = showButtonLoadingAndGetOriginal(button);
  } else {
    setButtonLoadingState(button, "Converting...");
  }
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
        onSuccessCallback(data);
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
  button.textContent = getButtonRestoreText(button, originalBtnText);
  syncUiLockState(false);
}

async function performProbe(url, sampleUrl, button) {
  syncUiLockState(true);
  const originalBtnText = button ? showButtonLoadingAndGetOriginal(button, "Checking...") : null;
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

    return data;
  } catch (error) {
    showStatus(`✗ Probe failed: ${error.message}`, "error");
    return null;
  } finally {
    if (button && originalBtnText !== null) {
      button.textContent = getButtonRestoreText(button, originalBtnText);
    }
    syncUiLockState(false);
  }
}

async function performFileProbe(
  file,
  button,
  { showInitialStatus = true, showErrorStatus = true } = {},
) {
  syncUiLockState(true);
  const originalBtnText = button ? showButtonLoadingAndGetOriginal(button, "Checking...") : null;
  const shouldShowInitialStatus = showInitialStatus && Boolean(button);
  if (shouldShowInitialStatus) {
    showStatus("Checking module metadata...", "info");
  }

  try {
    const formData = new FormData();
    formData.append("file", file);

    const response = await fetch("/probe-upload", {
      method: "POST",
      body: formData,
    });
    const contentType = response.headers.get("content-type") || "";
    const isJsonResponse = contentType.includes("application/json");

    if (!isJsonResponse) {
      throw new Error("Probe returned a non-JSON response");
    }

    const data = await response.json();

    if (!response.ok) {
      if (showErrorStatus) {
        showStatus(`✗ Error: ${data.error || "Probe failed"}`, "error");
      }
      return null;
    }

    if (!data.ok || !data.playable || !(data.module_name || data.filename)) {
      throw new Error("Probe returned incomplete module metadata");
    }

    return data;
  } catch (error) {
    if (showErrorStatus) {
      showStatus(`✗ Probe failed: ${error.message}`, "error");
    }
    return null;
  } finally {
    if (button && originalBtnText !== null) {
      button.textContent = getButtonRestoreText(button, originalBtnText);
    }
    syncUiLockState(false);
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
  setupQueueDropZone();
}

function setupQueueDropZone() {
  let queueDragDepth = 0;

  if (queueBrowseBtn && !queueBrowseBtn.dataset.defaultText) {
    queueBrowseBtn.dataset.defaultText = queueBrowseBtn.textContent.trim();
  }

  function preventDefaults(e) {
    e.preventDefault();
    e.stopPropagation();
  }

  const dropTargets = [playlistLauncherBar, playlistPanel];

  dropTargets.forEach((target) => {
    ["dragenter", "dragover", "dragleave", "drop"].forEach((eventName) => {
      target.addEventListener(eventName, preventDefaults, false);
    });

    target.addEventListener("dragenter", () => {
      queueDragDepth += 1;
      target.classList.add("queue-drag-over");
      setDropCueActive(queueBrowseBtn, true);
    });

    target.addEventListener("dragover", () => {
      target.classList.add("queue-drag-over");
      setDropCueActive(queueBrowseBtn, true);
    });

    ["dragleave", "drop"].forEach((eventName) => {
      target.addEventListener(eventName, () => {
        queueDragDepth = eventName === "drop" ? 0 : Math.max(0, queueDragDepth - 1);
        if (queueDragDepth === 0) {
          setDropCueActive(queueBrowseBtn, false);
        }
        target.classList.remove("queue-drag-over");
      });
    });

    target.addEventListener("drop", async (e) => {
      if (isUiLocked) {
        return;
      }
      await handleQueueFileBatch(e.dataTransfer.files);
    });
  });

  queueFileInput.addEventListener("change", async (e) => {
    await handleQueueFileBatch(e.target.files);
    e.target.value = "";
  });

  queueBrowseBtn.addEventListener("keydown", (e) => {
    if (e.key === "Enter" || e.key === " ") {
      e.preventDefault();
      queueFileInput.click();
    }
  });
}

async function handleQueueFileBatch(fileList) {
  const files = Array.from(fileList || []);
  if (files.length === 0) {
    return;
  }

  if (QUEUE_DROP_LIMIT_ENABLED && files.length > QUEUE_DROP_FILE_LIMIT) {
    showStatus(
      `✗ Queue accepts up to ${QUEUE_DROP_FILE_LIMIT} files at a time. Drop fewer files and try again.`,
      "warning",
    );
    return;
  }

  const batchStatus = showStatus(`Checking queue file 1 of ${files.length}: ${files[0].name}`, "info");
  const shouldAutoPlayAfterBatch = playlistTracks.length === 0 && !audioPlayer.getAttribute("src");
  let addedCount = 0;
  let skippedCount = 0;
  let lastAddedName = "";
  let firstAddedTrackId = null;

  for (const [index, file] of files.entries()) {
    updateStatusMessage(
      batchStatus,
      `Checking queue file ${index + 1} of ${files.length}: ${file.name}`,
      "info",
    );
    const result = await handleQueueFileDrop(file, {
      showStatusMessages: false,
      autoPlayWhenAdded: false,
    });
    if (result.added) {
      addedCount += 1;
      lastAddedName = result.name || lastAddedName;
      firstAddedTrackId = firstAddedTrackId || result.trackId || null;
    } else {
      skippedCount += 1;
    }
  }

  if (shouldAutoPlayAfterBatch && addedCount > 0 && firstAddedTrackId) {
    void playPlaylistTrack(firstAddedTrackId);
  }

  if (files.length === 1) {
    if (addedCount === 1) {
      updateStatusMessage(batchStatus, ADDED_TO_QUEUE_STATUS(lastAddedName), "success");
    } else {
      updateStatusMessage(batchStatus, `✗ Skipped ${files[0].name}`, "warning");
    }
    return;
  }

  if (addedCount > 0 && skippedCount === 0) {
    updateStatusMessage(batchStatus, `✓ Added ${addedCount} file(s) to queue`, "success");
  } else if (addedCount > 0) {
    updateStatusMessage(
      batchStatus,
      `✓ Added ${addedCount} file(s) to queue, skipped ${skippedCount}`,
      "warning",
    );
  } else {
    updateStatusMessage(batchStatus, `✗ Skipped all ${skippedCount} file(s)`, "warning");
  }
}

async function handleQueueFileDrop(file, { showStatusMessages = true, autoPlayWhenAdded = true } = {}) {
  if (file.size === 0) {
    if (showStatusMessages) {
      showStatus(`✗ Skipped empty file: ${file.name}`, "warning");
    }
    return { added: false, name: file.name };
  }

  let queueFile = file;
  try {
    queueFile = await materializeUploadFile(file);
  } catch (error) {
    if (showStatusMessages) {
      showStatus(`✗ Skipped unreadable dropped file: ${file.name}`, "warning");
    }
    return { added: false, name: file.name };
  }

  const existing = playlistTracks.find(
    (t) => matchesLocalTrackSource(t, queueFile),
  );

  if (existing) {
    return { added: false, name: existing.name, trackId: existing.id || null };
  }

  let name, moduleFormat, playerFormat, moduleHash;
  const probeData = await performFileProbe(queueFile, null, {
    showInitialStatus: false,
    showErrorStatus: showStatusMessages,
  });
  if (!probeData) {
    return { added: false, name: file.name };
  }
  name = probeData.module_name || probeData.filename || file.name;
  moduleFormat = probeData.module_format;
  playerFormat = probeData.player_format;
  moduleHash = probeData.module_hash || null;
  const shouldAutoPlay = autoPlayWhenAdded && playlistTracks.length === 0 && !audioPlayer.getAttribute("src");
  const sourceIdentity = getLocalTrackSourceIdentity(queueFile);
  const track = {
    id: createPlaylistTrackId(),
    name,
    url: null,
    sample_url: null,
    format: moduleFormat || playerFormat || "Module",
    source: "local",
    localFile: queueFile,
    playUrl: null,
    downloadUrl: null,
    audioFormat: null,
    moduleFormat,
    playerFormat,
    moduleHash,
    subsongs: null,
    subsongDurations: [],
    ...sourceIdentity,
  };
  addTrackToPlaylist(track);
  if (showStatusMessages) {
    showStatus(ADDED_TO_QUEUE_STATUS(name), "success");
  }
  if (shouldAutoPlay) {
    void playPlaylistTrack(track.id);
  }
  return { added: true, name, trackId: track.id };
}

function getSerializablePlaylistTracks() {
  return playlistTracks
    .filter((track) => track.source !== "local")
    .map((track) => ({
      n: track.name,
      u: track.url,
      s: track.sample_url || null,
      f: track.format || "Module",
      o: track.source || "queue",
    }));
}

function getSaveablePlaylistTracks() {
  return playlistTracks
    .filter((track) => track.source !== "local" || Boolean(track.moduleHash))
    .map((track) => {
      if (track.source === "local" && track.playUrl && track.moduleHash) {
        return {
          n: track.name,
          f: track.format || "Module",
          o: "local-cached",
          pu: track.playUrl,
          du: track.downloadUrl,
          af: track.audioFormat || "wav",
          mh: track.moduleHash,
          mf: track.moduleFormat || null,
          pf: track.playerFormat || null,
          ss: track.subsongs || null,
          sd: track.subsongDurations || null,
        };
      }
      if (track.source === "local" && track.moduleHash) {
        return {
          n: track.name,
          f: track.format || "Module",
          o: "local-deferred",
          mh: track.moduleHash,
          mf: track.moduleFormat || null,
          pf: track.playerFormat || null,
          ss: track.subsongs || null,
          sd: track.subsongDurations || null,
        };
      }
      return {
        n: track.name,
        u: track.url,
        s: track.sample_url || null,
        f: track.format || "Module",
        o: track.source || "queue",
      };
    });
}

function buildQueuePayload() {
  return {
    v: 1,
    t: getSerializablePlaylistTracks(),
  };
}

function buildSaveableQueuePayload() {
  return {
    v: 1,
    t: getSaveablePlaylistTracks(),
  };
}

function sanitizePlaylistTrack(track) {
  if (!track || typeof track !== "object") {
    return null;
  }

  const rawSource = typeof track.o === "string" ? track.o : track.source;
  const source = typeof rawSource === "string" && rawSource.trim() ? rawSource.trim() : "queue";

  if (source === "local-cached") {
    return sanitizeLocalCachedTrack(track);
  }
  if (source === "local-deferred") {
    return sanitizeLocalDeferredTrack(track);
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

  const sampleUrl = typeof rawSampleUrl === "string" ? rawSampleUrl.trim() : "";
  const name = typeof rawName === "string" && rawName.trim() ? rawName.trim() : "Module";
  const format = typeof rawFormat === "string" && rawFormat.trim() ? rawFormat.trim() : "Module";

  return {
    id: createPlaylistTrackId(),
    name,
    url,
    sample_url: sampleUrl || null,
    format,
    source,
  };
}

function sanitizeLocalDeferredTrack(track) {
  const moduleHash = typeof track.mh === "string" ? track.mh.trim() : "";
  if (!moduleHash) {
    return null;
  }

  const rawName = typeof track.n === "string" ? track.n : track.name;
  const rawFormat = typeof track.f === "string" ? track.f : track.format;

  return {
    id: createPlaylistTrackId(),
    name: typeof rawName === "string" && rawName.trim() ? rawName.trim() : "Module",
    url: null,
    sample_url: null,
    format: typeof rawFormat === "string" && rawFormat.trim() ? rawFormat.trim() : "Module",
    source: "local",
    playUrl: null,
    downloadUrl: null,
    audioFormat: null,
    moduleFormat: typeof track.mf === "string" ? track.mf.trim() : null,
    playerFormat: typeof track.pf === "string" ? track.pf.trim() : null,
    subsongs: typeof track.ss === "number" ? track.ss : null,
    subsongDurations: Array.isArray(track.sd) ? track.sd : null,
    localFile: null,
    moduleHash,
  };
}

function sanitizeLocalCachedTrack(track) {
  const playUrl = typeof track.pu === "string" ? track.pu.trim() : "";
  if (!playUrl) {
    return null;
  }

  const rawName = typeof track.n === "string" ? track.n : track.name;
  const rawFormat = typeof track.f === "string" ? track.f : track.format;

  return {
    id: createPlaylistTrackId(),
    name: typeof rawName === "string" && rawName.trim() ? rawName.trim() : "Module",
    url: null,
    sample_url: null,
    format: typeof rawFormat === "string" && rawFormat.trim() ? rawFormat.trim() : "Module",
    source: "local",
    playUrl,
    downloadUrl: typeof track.du === "string" ? track.du.trim() : playUrl,
    audioFormat: typeof track.af === "string" ? track.af.trim() : "wav",
    moduleFormat: typeof track.mf === "string" ? track.mf.trim() : null,
    playerFormat: typeof track.pf === "string" ? track.pf.trim() : null,
    subsongs: typeof track.ss === "number" ? track.ss : null,
    subsongDurations: Array.isArray(track.sd) ? track.sd : null,
    localFile: null,
    moduleHash: typeof track.mh === "string" && track.mh.trim() ? track.mh.trim() : null,
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

function hasSaveableTracks() {
  return playlistTracks.some(
    (track) => track.source !== "local" || Boolean(track.moduleHash),
  );
}

function hasSerializableTracks() {
  return playlistTracks.some((track) => track.source !== "local");
}

function savePlaylistLocally() {
  if (playlistTracks.length === 0) {
    showStatus("Queue is empty", "warning");
    return;
  }
  if (!hasSaveableTracks()) {
    showStatus("Queue contains only unconverted local files — play them first to save", "warning");
    return;
  }

  const payload = buildSaveableQueuePayload();
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
  if (!hasSerializableTracks()) {
    showStatus("Queue contains only local files — nothing to bookmark", "warning");
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
  const hasLocalTracks = playlistTracks.some((t) => t.source === "local");
  if (hasLocalTracks) {
    showStatus("✓ Queue bookmarked — local files were excluded (not bookmarkable)", "success");
  } else {
    showStatus("✓ Queue added to page URL for bookmarking", "success");
  }
}

async function sharePlaylist() {
  if (playlistTracks.length === 0) {
    showStatus("Queue is empty", "warning");
    return;
  }
  if (!hasSerializableTracks()) {
    showStatus("Queue contains only local files — nothing to share", "warning");
    return;
  }

  const payload = buildQueuePayload();
  const shareUrl = buildQueueUrlFromPayload(payload);

  warnIfQueueUrlIsLong(shareUrl);

  try {
    await navigator.clipboard.writeText(shareUrl);
    const hasLocalTracks = playlistTracks.some((t) => t.source === "local");
    if (hasLocalTracks) {
      showStatus("Link copied \u2014 local files were excluded (not shareable)", "warning");
    }
    const originalText = playlistShareBtn.textContent;
    playlistShareBtn.textContent = "✓ Copied!";
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
    return; // Empty or local-only queue — nothing to restore
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
    currentLocalTrackData = null;
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
  let track;

  if (currentShareableUrl) {
    track = {
      id: createPlaylistTrackId(),
      name: currentPlayableTrackName || currentTrack.textContent.trim() || "Module",
      url: currentShareableUrl,
      sample_url: currentShareableSampleUrl || null,
      format: currentPlayableTrackFormat || "Module",
      source: "current",
    };
  } else if (currentLocalTrackData) {
    track = {
      id: createPlaylistTrackId(),
      name: currentPlayableTrackName || currentLocalTrackData.name || "Module",
      url: null,
      sample_url: null,
      format: currentPlayableTrackFormat || currentLocalTrackData.playerFormat || "Module",
      source: "local",
      playUrl: currentLocalTrackData.playUrl,
      downloadUrl: currentLocalTrackData.downloadUrl,
      audioFormat: currentLocalTrackData.audioFormat,
      moduleFormat: currentLocalTrackData.moduleFormat,
      playerFormat: currentLocalTrackData.playerFormat,
      subsongs: currentLocalTrackData.subsongs,
      subsongDurations: currentLocalTrackData.subsongDurations,
      localFile: currentLocalTrackData.localFile,
      moduleHash: currentLocalTrackData.moduleHash,
      originalLocalName: currentLocalTrackData.originalLocalName || null,
      originalLocalSize: currentLocalTrackData.originalLocalSize ?? null,
      originalLocalType: currentLocalTrackData.originalLocalType || "",
    };
  } else {
    showStatus("Current track cannot be added to queue", "warning");
    return;
  }

  addTrackToPlaylist(track);
  showStatus(ADDED_TO_QUEUE_STATUS(track.name), "success");
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

  const name = probeData.module_name || probeData.filename || filenameFromUrl(url);
  const shouldAutoPlay = playlistTracks.length === 0 && !audioPlayer.getAttribute("src");
  const track = {
    id: createPlaylistTrackId(),
    name,
    url,
    sample_url: sampleUrl || null,
    format: probeData.module_format || probeData.player_format || "Module",
    source: "url",
  };
  addTrackToPlaylist(track);
  showStatus(ADDED_TO_QUEUE_STATUS(name), "success");
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
      playBtn.className = "btn btn-primary play-btn";
      playBtn.setAttribute("type", "button");
      playBtn.setAttribute("data-example-id", example.id);
      playBtn.textContent = "▶ Play Now";
      playBtn.addEventListener("click", () =>
        handleExamplePlay(example, playBtn),
      );
      actions.appendChild(playBtn);

      const addBtn = document.createElement("button");
      addBtn.className = "btn btn-secondary add-playlist-btn";
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
  showStatus(ADDED_TO_QUEUE_STATUS(example.name), "success");
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

function renderPlaylistLauncherBar(hasPlaylist) {
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
}

function renderPlaylistPanelControls(hasPlaylist, hasPreviousTrack, hasNextTrack) {
  playlistToggleBtn.dataset.contentDisabled = (!hasPlaylist).toString();
  playlistToggleBtn.disabled = isUiLocked || !hasPlaylist;

  playlistPrevBtn.dataset.contentDisabled = (!hasPreviousTrack).toString();
  playlistPrevBtn.disabled = isUiLocked || !hasPreviousTrack;

  playlistNextBtn.dataset.contentDisabled = (!hasNextTrack).toString();
  playlistNextBtn.disabled = isUiLocked || !hasNextTrack;

  const canSave = hasSaveableTracks();
  const canSerialize = hasSerializableTracks();

  playlistSaveBtn.dataset.contentDisabled = (!canSave).toString();
  playlistSaveBtn.disabled = isUiLocked || !canSave;

  playlistBookmarkBtn.dataset.contentDisabled = (!canSerialize).toString();
  playlistBookmarkBtn.disabled = isUiLocked || !canSerialize;

  playlistShareBtn.dataset.contentDisabled = (!canSerialize).toString();
  playlistShareBtn.disabled = isUiLocked || !canSerialize;

  playlistClearBtn.dataset.contentDisabled = (!hasPlaylist).toString();
  playlistClearBtn.disabled = isUiLocked || !hasPlaylist;
}

function renderPlaylistTrackItem(track, index) {
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
  if (track.source === "local") {
    const localBadge = document.createElement("span");
    localBadge.className = "playlist-local-badge";
    localBadge.textContent = "📁 local";
    meta.appendChild(localBadge);
    meta.appendChild(document.createTextNode(" " + (track.format || "Module")));
  } else {
    meta.textContent = track.format || "Module";
  }
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
  const moveUpContentDisabled = playlistTracks.length === 1 || index === 0;
  moveUpBtn.dataset.contentDisabled = moveUpContentDisabled.toString();
  moveUpBtn.disabled = isUiLocked || moveUpContentDisabled;
  moveUpBtn.addEventListener("click", () => movePlaylistTrack(track.id, -1));
  actions.appendChild(moveUpBtn);

  const moveDownBtn = document.createElement("button");
  moveDownBtn.type = "button";
  moveDownBtn.className = "btn btn-secondary btn-small playlist-move-btn";
  moveDownBtn.textContent = "↓";
  moveDownBtn.setAttribute("aria-label", `Move ${track.name} down in queue`);
  const moveDownContentDisabled =
    playlistTracks.length === 1 || index === playlistTracks.length - 1;
  moveDownBtn.dataset.contentDisabled = moveDownContentDisabled.toString();
  moveDownBtn.disabled = isUiLocked || moveDownContentDisabled;
  moveDownBtn.addEventListener("click", () => movePlaylistTrack(track.id, 1));
  actions.appendChild(moveDownBtn);

  actions.appendChild(removeBtn);

  item.appendChild(main);
  item.appendChild(actions);
  return item;
}

function renderPlaylist() {
  const hasPlaylist = playlistTracks.length > 0;
  const currentIndex = playlistTracks.findIndex((track) => track.id === currentPlaylistTrackId);
  const hasPreviousTrack = currentIndex > 0;
  const hasNextTrack =
    hasPlaylist && (currentIndex === -1 ? playlistTracks.length > 0 : currentIndex < playlistTracks.length - 1);

  renderPlaylistLauncherBar(hasPlaylist);
  renderPlaylistPanelControls(hasPlaylist, hasPreviousTrack, hasNextTrack);

  playlistList.replaceChildren();
  playlistEmptyState.hidden = playlistTracks.length > 0;
  playlistTracks.forEach((track, index) => {
    playlistList.appendChild(renderPlaylistTrackItem(track, index));
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

async function playCachedLocalTrack(track, trackId, button) {
  syncUiLockState(true);
  const originalBtnText = showButtonLoadingAndGetOriginal(button);
  showStatus(`Loading ${track.name}...`, "info");

  const abortPlayback = (message, { remove = false } = {}) => {
    if (remove) {
      removeTrackFromPlaylist(trackId);
    }
    showStatus(message, "error");
    button.textContent = originalBtnText;
    syncUiLockState(false);
  };

  const fallbackToLocalRecovery = async () => {
    if (!track.moduleHash && !track.localFile) {
      return false;
    }

    track.playUrl = null;
    track.downloadUrl = null;
    track.audioFormat = null;
    const recoveryMessage = track.moduleHash
      ? `Cached audio for ${track.name} expired — reconverting from saved upload...`
      : `Cached audio for ${track.name} expired — re-uploading saved local file...`;
    showStatus(recoveryMessage, "info");
    await playDeferredLocalTrack(track, trackId, button, {
      uiAlreadyLocked: true,
      originalBtnText,
    });
    return true;
  };

  try {
    const headResponse = await fetch(track.playUrl, { method: "HEAD" });
    if (!headResponse.ok) {
      if (headResponse.status === 404 || headResponse.status === 410) {
        if (await fallbackToLocalRecovery()) {
          return;
        }

        abortPlayback(`✗ "${track.name}" has expired from server cache and was removed — drop the file again to re-add`, {
          remove: true,
        });
        return;
      }

      abortPlayback(`✗ Couldn't verify cached audio for ${track.name}. Please try again.`);
      return;
    }
  } catch (_err) {
    abortPlayback(`✗ Couldn't verify cached audio for ${track.name}. Please try again.`);
    return;
  }

  currentPlaylistTrackId = trackId;
  currentShareableUrl = null;
  currentShareableSampleUrl = null;
  currentLocalTrackData = {
    name: track.name,
    playUrl: track.playUrl,
    downloadUrl: track.downloadUrl,
    audioFormat: track.audioFormat,
    moduleFormat: track.moduleFormat,
    playerFormat: track.playerFormat,
    subsongs: track.subsongs,
    subsongDurations: track.subsongDurations,
    localFile: track.localFile,
    moduleHash: track.moduleHash,
    originalLocalName: track.originalLocalName || null,
    originalLocalSize: track.originalLocalSize ?? null,
    originalLocalType: track.originalLocalType || "",
  };
  updateShareButton(false);
  showStatus(`✓ ${track.name} loaded from conversion cache and ready to play`, "success");
  playFile(
    null,
    track.name,
    track.playUrl,
    track.downloadUrl,
    track.playerFormat || "Module",
    track.audioFormat || "wav",
    track.moduleFormat,
    track.subsongs,
    track.subsongDurations || [],
  );
  // Restore playlist track ID after playFile clears it
  currentPlaylistTrackId = trackId;
  renderPlaylist();
  resetButtonAfterDelay(button, originalBtnText);
}

async function playDeferredLocalTrack(
  track,
  trackId,
  button,
  { uiAlreadyLocked = false, originalBtnText: providedOriginalBtnText = null } = {},
) {
  let originalBtnText = providedOriginalBtnText;

  const ensureLoadingState = (loadingText = "Converting...") => {
    if (!uiAlreadyLocked || originalBtnText === null) {
      syncUiLockState(true);
      originalBtnText = showButtonLoadingAndGetOriginal(button, loadingText);
      uiAlreadyLocked = true;
      return;
    }

    setButtonLoadingState(button, loadingText);
  };

  const restoreUiState = () => {
    if (originalBtnText !== null) {
      button.textContent = getButtonRestoreText(button, originalBtnText);
    }
    syncUiLockState(false);
  };

  const onConversionSuccess = (data) => {
    track.playUrl = data.play_url;
    track.downloadUrl = data.download_url;
    track.audioFormat = data.audio_format || "wav";
    track.subsongs = data.subsongs;
    track.subsongDurations = data.subsong_durations || [];

    currentPlaylistTrackId = trackId;
    currentShareableUrl = null;
    currentShareableSampleUrl = null;
    currentLocalTrackData = {
      name: track.name,
      playUrl: track.playUrl,
      downloadUrl: track.downloadUrl,
      audioFormat: track.audioFormat,
      moduleFormat: track.moduleFormat,
      playerFormat: track.playerFormat,
      subsongs: track.subsongs,
      subsongDurations: track.subsongDurations,
      localFile: track.localFile,
      moduleHash: track.moduleHash,
      originalLocalName: track.originalLocalName || null,
      originalLocalSize: track.originalLocalSize ?? null,
      originalLocalType: track.originalLocalType || "",
    };
    updateShareButton(false);
    renderPlaylist();
  };

  // Try converting by hash (module already on server from probe) before re-uploading
  if (track.moduleHash) {
    ensureLoadingState("Converting...");
    showStatus(`Converting ${track.name}...`, "info");

    try {
      const response = await fetch("/convert-probed", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ module_hash: track.moduleHash, filename: track.name }),
      });

      if (response.ok) {
        const data = await response.json();
        const moduleName = track.name || data.module_name || data.filename;
        const statusMessage = getCacheStatusMessage(
          data, moduleName, `✓ ${moduleName} converted and ready to play`,
        );
        showStatus(statusMessage, "success");
        playFile(
          data.file_id, moduleName, data.play_url, data.download_url,
          data.player_format || "Module", data.audio_format || "wav",
          data.module_format, data.subsongs, data.subsong_durations || [],
        );
        onConversionSuccess(data);
        resetButtonAfterDelay(button, originalBtnText);
        return;
      }

      if (response.status !== 404) {
        const errorData = await response.json().catch(() => ({}));
        showStatus(`✗ Error: ${errorData.error || "Conversion failed"}`, "error");
        restoreUiState();
        return;
      }
      // 404 means the probed source is no longer available on this server instance.
      // Treat /convert-probed as an optimization only and fall back to /upload.
    } catch (_err) {
      // Network error — fall through to re-upload
    }
  }

  if (!track.localFile) {
    restoreUiState();
    showStatus(`✗ "${track.name}" has expired from server — drop the file again to re-add`, "error");
    removeTrackFromPlaylist(track.id);
    return;
  }

  const formData = new FormData();
  formData.append("file", track.localFile);

  await performConversion(
    "/upload",
    { method: "POST", body: formData },
    button,
    `Converting ${track.name}...`,
    "✓ {moduleName} converted and ready to play",
    track.name,
    onConversionSuccess,
    { uiAlreadyLocked, originalBtnText },
  );
}

async function playUrlTrack(track, trackId, button) {
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

async function playPlaylistTrack(trackId, button) {
  const track = playlistTracks.find((candidate) => candidate.id === trackId);
  if (!track) {
    return;
  }

  if (!button || !button.parentNode) {
    const trackIndex = playlistTracks.indexOf(track);
    const items = playlistList.querySelectorAll(".playlist-item");
    button = items[trackIndex]?.querySelector(".playlist-play-btn") || playlistNextBtn;
  }

  if (track.source === "local" && track.playUrl) {
    return playCachedLocalTrack(track, trackId, button);
  }
  if (track.source === "local" && (track.localFile || track.moduleHash) && !track.playUrl) {
    return playDeferredLocalTrack(track, trackId, button);
  }
  return playUrlTrack(track, trackId, button);
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

  void playPlaylistTrack(nextTrack.id);
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

  void playPlaylistTrack(previousTrack.id);
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
      syncUiLockState(false);
      if (autoplayOverlay) {
        autoplayOverlay.style.display = "flex";
        autoplayOverlay.style.pointerEvents = "auto";
      }
      console.warn("Autoplay was prevented by browser policy.");
    } else {
      console.error("Playback error:", err);
      showStatus("An error occurred during playback. Check console for details.", "error");
      syncUiLockState(false);
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
function clearStatusMessageTimers(status) {
  if (status._removeTimer) {
    clearTimeout(status._removeTimer);
    status._removeTimer = null;
  }
  if (status._fadeTimer) {
    clearTimeout(status._fadeTimer);
    status._fadeTimer = null;
  }
}

function scheduleStatusRemoval(status) {
  clearStatusMessageTimers(status);
  status._removeTimer = setTimeout(() => {
    status.style.opacity = "0";
    status._fadeTimer = setTimeout(() => status.remove(), 300);
  }, 5000);
}

function updateStatusMessage(status, message, type = "info") {
  if (!status) {
    return showStatus(message, type);
  }

  status.className = `status-message status-${type}`;
  status.textContent = message;
  status.style.opacity = "1";
  scheduleStatusRemoval(status);
  return status;
}

function showStatus(message, type = "info") {
  const status = document.createElement("div");
  status.className = `status-message status-${type}`;
  status.textContent = message;

  statusContainer.appendChild(status);
  scheduleStatusRemoval(status);
  return status;
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
    audioPlayer.play().then(() => {
      syncUiLockState(false);
      audioPlayer.focus(); // Set focus after user-initiated play
    }).catch(err => {
      console.error("Playback error:", err);
      showStatus("An error occurred during playback. Check console for details.", "error");
      syncUiLockState(false);
    });
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
    const hasUadeVersion = data.uade_version && data.uade_version !== "unknown";
    const hasBuildTime = data.image_build_time && data.image_build_time !== "unknown";
    const isDevelopmentMode = data.mode === "development";
    const hasGitVersion =
      !isDevelopmentMode && data.version && data.version !== "unknown";
    let formattedBuildTime = data.image_build_time;

    if (hasBuildTime) {
      const buildTime = new Date(data.image_build_time);
      if (!Number.isNaN(buildTime.getTime())) {
        const year = String(buildTime.getFullYear());
        const month = String(buildTime.getMonth() + 1).padStart(2, "0");
        const day = String(buildTime.getDate()).padStart(2, "0");
        const hours = String(buildTime.getHours()).padStart(2, "0");
        const minutes = String(buildTime.getMinutes()).padStart(2, "0");
        const seconds = String(buildTime.getSeconds()).padStart(2, "0");
        formattedBuildTime = `${year}-${month}-${day} ${hours}:${minutes}:${seconds}`;
      }
    }

    const parts = [];

    if (hasUadeVersion) {
      parts.push({
        type: "text",
        value: `UADE ${data.uade_version}`,
      });
    }

    if (isDevelopmentMode) {
      parts.push({
        type: "text",
        value: "dev mode",
      });
    } else if (hasGitVersion) {
      parts.push({
        type: "link",
        value: `Web ${data.version.substring(0, 7)}`,
        href: `https://github.com/rib1/uade-docker/commit/${encodeURIComponent(data.version)}`,
      });
    }

    if (hasBuildTime) {
      parts.push({
        type: "time",
        value: formattedBuildTime,
        dateTime: data.image_build_time,
      });
    }

    if (parts.length > 0) {
      versionElement.textContent = "";
      parts.forEach((part, index) => {
        if (index > 0) {
          versionElement.appendChild(document.createTextNode(" • "));
        }

        if (part.type === "link") {
          const link = document.createElement("a");
          link.href = part.href;
          link.target = "_blank";
          link.style.color = "#666";
          link.style.textDecoration = "none";
          link.textContent = part.value;
          versionElement.appendChild(link);
          return;
        }

        if (part.type === "time") {
          const buildTimeElement = document.createElement("time");
          buildTimeElement.dateTime = part.dateTime;
          buildTimeElement.title = part.dateTime;
          buildTimeElement.textContent = part.value;
          versionElement.appendChild(buildTimeElement);
          return;
        }

        versionElement.appendChild(document.createTextNode(part.value));
      });

    } else {
      versionElement.textContent = "";
    }
  } catch (error) {
    console.error("Failed to load version info:", error);
    document.getElementById("version-info").textContent = "";
  }
}
