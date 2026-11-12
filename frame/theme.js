// Apply the parent page's palette and fonts, and send back the report height.
// See report.js for the parent-side code.
//
// The sandboxed frame receives its initial palette in the URL fragment and
// later updates through postMessage. Colors and font names become --ui-*
// properties for theme.css, which supplies light-theme defaults. Font files
// arrive as @font-face rules with data: URIs.
(function () {
	'use strict';
	var root = document.documentElement;
	var NAME = /^--ui-[a-z0-9-]{1,40}$/;
	var VALUE = /^[a-zA-Z0-9#(),.%\/ '"-]{1,160}$/;
	var FONTS = /^(\s*@font-face\s*\{[^{}<>]*\}\s*)+$/;
	var applied = [];
	var framed = false;

	// apply(message) validates and applies theme tokens and fonts.
	function apply(message) {
		// Ignore missing data and unrelated message types.
		if (!message || typeof message !== 'object' ||
		    message.type !== 'webmin-ui-palette') return;
		// Let the parent handle scrolling after it sizes the frame.
		if (!framed) {
			framed = true;
			root.style.overflow = 'hidden';
		}
		var tokens = message.tokens && typeof message.tokens === 'object' ?
			message.tokens : {};
		// Restore CSS defaults for tokens missing from the new palette.
		applied.forEach(function (name) { root.style.removeProperty(name); });
		applied = [];
		Object.keys(tokens).forEach(function (name) {
			var value = tokens[name];
			// Reject unsupported property names and CSS values.
			if (!NAME.test(name) || typeof value !== 'string' ||
			    !VALUE.test(value)) return;
			root.style.setProperty(name, value);
			applied.push(name);
		});
		var scheme = message.scheme === 'dark' ? 'dark' : 'light';
		root.setAttribute('data-ui-scheme', scheme);
		root.style.colorScheme = scheme;
		// Accept bounded font rules in one replaceable stylesheet.
		if (typeof message.fonts === 'string' && message.fonts.length < 4000000 &&
		    FONTS.test(message.fonts)) {
			var sheet = document.getElementById('webmin-ui-fonts');
			if (!sheet) {
				// Create the first font stylesheet.
				sheet = document.createElement('style');
				sheet.id = 'webmin-ui-fonts';
				document.head.appendChild(sheet);
			}
			// Avoid reloading unchanged fonts.
			if (sheet.textContent !== message.fonts) sheet.textContent = message.fonts;
		}
	}

	// The fragment carries the palette for the first paint.
	var match = /(?:^#|&)ui=([^&]+)/.exec(location.hash);
	if (match) {
		// Invalid fragment data leaves the default theme in place.
		try { apply(JSON.parse(decodeURIComponent(match[1]))); } catch (e) {}
	}
	window.addEventListener('message', function (event) {
		// Only the page embedding the report may restyle it.
		if (event.source !== window.parent) return;
		apply(event.data);
	});

	// fitTooltip(tooltip) keeps a visible tooltip inside the frame edges.
	function fitTooltip(tooltip) {
		// Missing or hidden tooltips have no visible edges to adjust.
		if (!tooltip || !tooltip.offsetWidth) return;
		var rect = tooltip.getBoundingClientRect();
		var left = Math.max(8, Math.min(rect.left, root.clientWidth - rect.width - 8));
		if (left !== rect.left) {
			// Keep the tooltip's offset relative to its chart.
			tooltip.style.left = (parseFloat(tooltip.style.left) || 0) + left - rect.left + 'px';
		}
	}
	// Run after tooltip positioning, including after chart redraws.
	document.addEventListener('mousemove', function (event) {
		var chart = event.target.closest && event.target.closest('.chart-wrap');
		// Mouse movement outside a chart needs no adjustment.
		if (chart) fitTooltip(chart.querySelector('.chart-tooltip-wrap'));
	});
	window.addEventListener('resize', function () {
		document.querySelectorAll('.chart-tooltip-wrap').forEach(fitTooltip);
	});

	var reported = 0;
	// measure() sends changed report heights to the parent page.
	function measure() {
		// A standalone report has no containing frame to resize.
		if (window.parent === window) return;
		// Body height lets the frame shrink when content gets shorter.
		// Root height cannot drop below the current frame height.
		var height = document.body ? document.body.scrollHeight : root.scrollHeight;
		// Skip empty or unchanged measurements to avoid a message loop.
		if (!height || height === reported) return;
		reported = height;
		window.parent.postMessage({ type: 'webmin-frame-size', height: height }, '*');
	}
	// watch() measures the report after content, font or viewport changes.
	function watch() {
		if (typeof ResizeObserver === 'function') {
			// Observe content changes when the browser supports it.
			new ResizeObserver(measure).observe(document.body);
		}
		window.addEventListener('load', measure);
		window.addEventListener('resize', measure);
		measure();
	}
	if (document.body) {
		// Start immediately when the body is already available.
		watch();
	} else {
		// The injected script can run before the report body is parsed.
		document.addEventListener('DOMContentLoaded', watch);
	}
})();
