// UADE Web Player - Client Side JavaScript

// State
let currentFileId = null;
let currentDownloadUrl = null;

// DOM Elements
const dropZone = document.getElementById('drop-zone');
const fileInput = document.getElementById('file-input');
const urlInput = document.getElementById('url-input');
const urlSubmit = document.getElementById('url-submit');
const mdatInput = document.getElementById('mdat-url');
const smplInput = document.getElementById('smpl-url');
const tfmxSubmit = document.getElementById('tfmx-submit');
const audioPlayer = document.getElementById('audio-player');
const playerSection = document.getElementById('player-section');
const currentTrack = document.getElementById('current-track');
const trackFormat = document.getElementById('track-format');
const downloadBtn = document.getElementById('download-btn');
const examplesGrid = document.getElementById('examples-grid');
const statusContainer = document.getElementById('status-container');

// Initialize
document.addEventListener('DOMContentLoaded', () => {
    setupDragAndDrop();
    setupFileInput();
    setupUrlForm();
    setupTfmxForm();
    setupDownloadButton();
    loadExamples();
});

// Drag and Drop
function setupDragAndDrop() {
    ['dragenter', 'dragover', 'dragleave', 'drop'].forEach(eventName => {
        dropZone.addEventListener(eventName, preventDefaults, false);
    });

    function preventDefaults(e) {
        e.preventDefault();
        e.stopPropagation();
    }

    ['dragenter', 'dragover'].forEach(eventName => {
        dropZone.addEventListener(eventName, () => {
            dropZone.classList.add('drag-over');
        });
    });

    ['dragleave', 'drop'].forEach(eventName => {
        dropZone.addEventListener(eventName, () => {
            dropZone.classList.remove('drag-over');
        });
    });

    dropZone.addEventListener('drop', handleDrop);
}

function handleDrop(e) {
    const dt = e.dataTransfer;
    const files = dt.files;

    if (files.length > 0) {
        handleFileUpload(files[0]);
    }
}

// File Input
function setupFileInput() {
    fileInput.addEventListener('change', (e) => {
        if (e.target.files.length > 0) {
            handleFileUpload(e.target.files[0]);
        }
    });
}

// Upload File
async function handleFileUpload(file) {
    showStatus('Uploading and converting...', 'info');
    
    const formData = new FormData();
    formData.append('file', file);

    try {
        const response = await fetch('/upload', {
            method: 'POST',
            body: formData
        });

        const data = await response.json();

        if (response.ok) {
            showStatus(`✓ Converted: ${data.filename}`, 'success');
            playFile(data.file_id, data.filename, data.play_url, data.download_url, '', data.format || 'wav');
        } else {
            showStatus(`✗ Error: ${data.error}`, 'error');
        }
    } catch (error) {
        showStatus(`✗ Upload failed: ${error.message}`, 'error');
    }
}

// URL Form
function setupUrlForm() {
    urlSubmit.addEventListener('click', handleUrlConvert);
    urlInput.addEventListener('keypress', (e) => {
        if (e.key === 'Enter') {
            handleUrlConvert();
        }
    });
}

async function handleUrlConvert() {
    const url = urlInput.value.trim();
    if (!url) {
        showStatus('Please enter a URL', 'warning');
        return;
    }

    showStatus('Downloading and converting...', 'info');
    urlSubmit.disabled = true;

    try {
        const response = await fetch('/convert-url', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({ url })
        });

        const data = await response.json();

        if (response.ok) {
            showStatus(`✓ Converted: ${data.filename}`, 'success');
            playFile(data.file_id, data.filename, data.play_url, data.download_url, '', data.format || 'wav');
            urlInput.value = '';
        } else {
            showStatus(`✗ Error: ${data.error}`, 'error');
        }
    } catch (error) {
        showStatus(`✗ Conversion failed: ${error.message}`, 'error');
    } finally {
        urlSubmit.disabled = false;
    }
}

// TFMX Form
function setupTfmxForm() {
    tfmxSubmit.addEventListener('click', handleTfmxConvert);
}

async function handleTfmxConvert() {
    const mdatUrl = mdatInput.value.trim();
    const smplUrl = smplInput.value.trim();

    if (!mdatUrl || !smplUrl) {
        showStatus('Please enter both TFMX URLs', 'warning');
        return;
    }

    showStatus('Converting TFMX module...', 'info');
    tfmxSubmit.disabled = true;

    try {
        const response = await fetch('/convert-tfmx', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({
                mdat_url: mdatUrl,
                smpl_url: smplUrl
            })
        });

        const data = await response.json();

        if (response.ok) {
            showStatus('✓ TFMX converted successfully', 'success');
            playFile(data.file_id, 'TFMX Module', data.play_url, data.download_url, 'TFMX', data.format || 'wav');
            mdatInput.value = '';
            smplInput.value = '';
        } else {
            showStatus(`✗ Error: ${data.error}`, 'error');
        }
    } catch (error) {
        showStatus(`✗ TFMX conversion failed: ${error.message}`, 'error');
    } finally {
        tfmxSubmit.disabled = false;
    }
}

// Load Examples
async function loadExamples() {
    try {
        const response = await fetch('/examples');
        const examples = await response.json();

        examples.forEach(example => {
            const card = document.createElement('div');
            card.className = 'example-card';
            
            card.innerHTML = `
                <h3>${example.name}</h3>
                <div class="example-meta">
                    <span class="format-badge">${example.format}</span>
                    <span>${example.duration}</span>
                </div>
                <button class="play-btn" data-example-id="${example.id}">
                    ▶ Play Now
                </button>
            `;

            const playBtn = card.querySelector('.play-btn');
            playBtn.addEventListener('click', () => handleExamplePlay(example, playBtn));

            examplesGrid.appendChild(card);
        });
    } catch (error) {
        console.error('Failed to load examples:', error);
    }
}

// Play Example
async function handleExamplePlay(example, button) {
    button.disabled = true;
    button.innerHTML = '<span class="loading"></span> Converting...';
    showStatus(`Converting ${example.name}...`, 'info');

    try {
        const response = await fetch(`/play-example/${example.id}`, {
            method: 'POST'
        });

        const data = await response.json();

        if (response.ok) {
            showStatus(`✓ ${example.name} ready to play`, 'success');
            playFile(data.file_id, example.name, data.play_url, data.download_url, example.format, data.format || 'wav');
            button.innerHTML = '✓ Playing';
            
            // Reset button after 2 seconds
            setTimeout(() => {
                button.innerHTML = '▶ Play Now';
                button.disabled = false;
            }, 2000);
        } else {
            showStatus(`✗ Error: ${data.error}`, 'error');
            button.innerHTML = '▶ Play Now';
            button.disabled = false;
        }
    } catch (error) {
        showStatus(`✗ Failed: ${error.message}`, 'error');
        button.innerHTML = '▶ Play Now';
        button.disabled = false;
    }
}

// Play File
function playFile(fileId, filename, playUrl, downloadUrl, format = '', audioFormat = 'wav') {
    currentFileId = fileId;
    currentDownloadUrl = downloadUrl;
    
    audioPlayer.src = playUrl;
    currentTrack.textContent = filename;
    trackFormat.textContent = format || 'Module';
    
    // Update download button text with correct format
    downloadBtn.textContent = audioFormat === 'flac' ? '⬇ Download FLAC' : '⬇ Download WAV';
    
    playerSection.style.display = 'block';
    playerSection.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    
    audioPlayer.play().catch(err => {
        console.error('Playback error:', err);
        showStatus('Playback error - check browser console', 'error');
    });
}

// Download Button
function setupDownloadButton() {
    downloadBtn.addEventListener('click', () => {
        if (currentDownloadUrl) {
            window.location.href = currentDownloadUrl;
            showStatus('Download started', 'success');
        }
    });
}

// Status Messages
function showStatus(message, type = 'info') {
    const status = document.createElement('div');
    status.className = `status-message status-${type}`;
    status.textContent = message;
    
    statusContainer.appendChild(status);
    
    // Auto-remove after 5 seconds
    setTimeout(() => {
        status.style.opacity = '0';
        setTimeout(() => status.remove(), 300);
    }, 5000);
}
