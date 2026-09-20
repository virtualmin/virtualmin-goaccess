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

	// apply(message) validates and replaces palette tokens and embedded fonts.
	function apply(message) {
		if (!message || typeof message !== 'object' ||
		    message.type !== 'webmin-ui-palette') return;
		// The parent page handles scrolling once it sizes the frame to the report.
		if (!framed) {
			framed = true;
			root.style.overflow = 'hidden';
		}
		var tokens = message.tokens && typeof message.tokens === 'object' ?
			message.tokens : {};
		applied.forEach(function (name) { root.style.removeProperty(name); });
		applied = [];
		Object.keys(tokens).forEach(function (name) {
			var value = tokens[name];
			if (!NAME.test(name) || typeof value !== 'string' ||
			    !VALUE.test(value)) return;
			root.style.setProperty(name, value);
			applied.push(name);
		});
		var scheme = message.scheme === 'dark' ? 'dark' : 'light';
		root.setAttribute('data-ui-scheme', scheme);
		root.style.colorScheme = scheme;
		// Keep the parent's embedded font rules in one replaceable stylesheet.
		if (typeof message.fonts === 'string' && message.fonts.length < 4000000 &&
		    FONTS.test(message.fonts)) {
			var sheet = document.getElementById('webmin-ui-fonts');
			if (!sheet) {
				sheet = document.createElement('style');
				sheet.id = 'webmin-ui-fonts';
				document.head.appendChild(sheet);
			}
			if (sheet.textContent !== message.fonts) sheet.textContent = message.fonts;
		}
	}

	// The fragment carries the palette for the first paint.
	var match = /(?:^#|&)ui=([^&]+)/.exec(location.hash);
	if (match) {
		try { apply(JSON.parse(decodeURIComponent(match[1]))); } catch (e) {}
	}
	window.addEventListener('message', function (event) {
		// Only the page embedding the report may restyle it.
		if (event.source !== window.parent) return;
		apply(event.data);
	});

	// measure() sends changed content heights so the parent can resize the frame.
	var reported = 0;
	function measure() {
		if (window.parent === window) return;
		// Use the body height so the frame can shrink when content gets shorter.
		// The root height never drops below the frame's current height.
		var height = document.body ? document.body.scrollHeight : root.scrollHeight;
		if (!height || height === reported) return;
		reported = height;
		window.parent.postMessage({ type: 'webmin-frame-size', height: height }, '*');
	}
	// watch() measures the report after content, font or viewport changes.
	function watch() {
		if (typeof ResizeObserver === 'function') {
			new ResizeObserver(measure).observe(document.body);
		}
		window.addEventListener('load', measure);
		window.addEventListener('resize', measure);
		measure();
	}
	if (document.body) {
		watch();
	} else {
		document.addEventListener('DOMContentLoaded', watch);
	}
})();
