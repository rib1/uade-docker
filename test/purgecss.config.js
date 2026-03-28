module.exports = {
  content: [
    "../web/static/*.html",
    "../web/static/*.js",
    {
      raw: `
        <div id="upload-btn" data-drag-cue-active="true"></div>
        <div class="playlist-launcher-drop-hint" data-drag-cue-active="true"></div>
        <div class="status-success status-error status-info status-warning"></div>
      `,
      extension: "html"
    }
  ],
  css: [
    "../web/static/style.css"
  ],
  // The checker script writes output back to CSS files only when called with --fix.
  safelist: {
    standard: [
      "#upload-btn[data-drag-cue-active=\"true\"]",
      ".playlist-launcher-drop-hint[data-drag-cue-active=\"true\"]",
      ".status-success",
      ".status-error",
      ".status-info",
      ".status-warning"
    ]
  }, // Add any selectors you want to always keep
};
