// Match the frame's appearance to Webmin, and size it to the report.
//
// Read the page's theme properties and resolve its spacing and radius. Send them
// in the frame's URL fragment on load, then by postMessage when the theme
// or stylesheet changes. The frame's opaque origin prevents direct DOM
// access. frame/theme.js applies the palette and sends back the report height.
(function () {
	'use strict';
	var frame = document.getElementById('goaccess-frame');
	// Skip absent frames and copies of this script that already ran.
	if (!frame || frame.getAttribute('src')) return;
	var page = frame.closest('.ui_page') || document.body;
	var card = frame.closest('.ui_card') || page;
	var TOKENS = [ 'canvas', 'surface', 'surface-2', 'border', 'border-soft',
		'border-strong', 'fg', 'fg-muted', 'accent', 'accent-soft', 'ring',
		'success', 'success-text', 'success-soft', 'success-line',
		'warning', 'warning-text', 'warning-soft', 'warning-line',
		'danger', 'danger-text', 'danger-soft', 'danger-line',
		'info', 'info-text', 'info-soft', 'info-line',
		'neutral', 'neutral-text', 'neutral-soft', 'neutral-line',
		'font', 'font-mono' ];

	// Ajax navigation runs this script again on every visit, so only the
	// newest copy may watch the document.
	if (window.goaccessFrameSync) window.goaccessFrameSync.stop();

	// Resolve theme colors and lengths before sending them into the frame.
	var probe = document.createElement('span');
	probe.hidden = true;
	probe.style.marginLeft = 'var(--gap, var(--ui-gap, 7px))';
	page.appendChild(probe);
	// isDark(color) selects the frame's color scheme from the page surface.
	function isDark(color) {
		probe.style.color = '';
		probe.style.color = color;
		var parts = (getComputedStyle(probe).color.match(/[\d.]+/g) || []).map(Number);
		// Fall back to light when the browser cannot resolve the color.
		if (parts.length < 3) return false;
		return (0.2126 * parts[0] + 0.7152 * parts[1] + 0.0722 * parts[2]) / 255 < 0.5;
	}

	var fonts = '';
	// palette() returns theme tokens, the color scheme and fonts.
	function palette() {
		var styles = getComputedStyle(page), tokens = {};
		TOKENS.forEach(function (name) {
			var value = styles.getPropertyValue('--ui-' + name).trim();
			// Ignore empty values and inherited CSS keywords.
			if (value && !/^(inherit|initial|unset|revert)$/i.test(value)) {
				tokens['--ui-' + name] = value;
			}
		});
		// Resolve calc() and inherited variables in the parent document.
		var metrics = getComputedStyle(probe);
		tokens['--ui-gap'] = metrics.marginLeft;
		// Match the inner card, not the outer page's rounded container.
		tokens['--ui-radius'] = getComputedStyle(card).borderTopLeftRadius;
		var surface = tokens['--ui-surface'];
		var message = { type: 'webmin-ui-palette', tokens: tokens,
				scheme: surface && isDark(surface) ? 'dark' : 'light' };
		// Fonts arrive separately after their files have been read.
		if (fonts) message.fonts = fonts;
		return message;
	}

	var last = '';
	// send(force) sends palette changes; force resends unchanged values.
	function send(force) {
		// Release listeners after navigation removes the frame.
		if (!frame.isConnected) return stop();
		var message = palette(), key = JSON.stringify(message);
		// Skip unchanged values unless forced.
		if (!force && key === last) return;
		last = key;
		// The scheme on the frame element shows what it was given last.
		frame.setAttribute('data-ui-scheme', message.scheme);
		// The opaque frame origin requires '*' as the target.
		if (frame.contentWindow) frame.contentWindow.postMessage(message, '*');
		refreshFonts();
	}

	// Wait for styles to update before reading a changed theme.
	var observer = new MutationObserver(function () {
		requestAnimationFrame(function () { send(false); });
	});
	// onStylesheetLoad(event) refreshes tokens after a stylesheet is ready.
	function onStylesheetLoad(event) {
		if (event.target.matches && event.target.matches('link[rel~="stylesheet"]')) {
			send(false);
		}
	}
	// Hide the spinner on load or the first size message.
	var loading = frame.parentElement &&
		frame.parentElement.querySelector('.goaccess-frame-loading');
	// ready() hides the spinner, if present.
	function ready() {
		if (loading) loading.hidden = true;
	}

	// onFrameMessage(event) sizes the report frame, with a 320px minimum.
	// The parent page handles scrolling.
	function onFrameMessage(event) {
		// Accept messages only from this report frame.
		if (event.source !== frame.contentWindow) return;
		var data = event.data;
		// Only size messages affect the frame height.
		if (!data || data.type !== 'webmin-frame-size') return;
		var height = Number(data.height);
		// Reject invalid or excessive sizes before changing the frame.
		if (!(height > 0 && height < 200000)) return;
		ready();
		frame.style.minHeight = '0';
		frame.style.height = Math.max(Math.ceil(height), 320) + 'px';
	}
	window.addEventListener('message', onFrameMessage);
	// stop() removes this frame's document listeners and theme probe.
	function stop() {
		observer.disconnect();
		window.removeEventListener('message', onFrameMessage);
		document.removeEventListener('load', onStylesheetLoad, true);
		probe.remove();
		// Keep a newer instance's cleanup hook intact.
		if (window.goaccessFrameSync && window.goaccessFrameSync.stop === stop) {
			window.goaccessFrameSync = null;
		}
	}
	window.goaccessFrameSync = { stop: stop };

	// The frame blocks font requests but allows data: URIs. Embed only the
	// font faces already loaded by the parent page to limit the transfer.
	// unquote(text) strips surrounding spaces and quotes from font names.
	function unquote(text) {
		return (text || '').trim().replace(/^["']|["']$/g, '');
	}
	// ranges(text) normalizes Unicode bounds for font comparisons.
	function ranges(text) {
		return (text || 'U+0-10FFFF').toUpperCase().split(',').map(function (part) {
			var match = /U\+([0-9A-F?]+)(?:-([0-9A-F]+))?/.exec(part.trim());
			// Ignore malformed ranges when comparing font variants.
			if (!match) return '';
			var from = match[1], to = match[2] || match[1];
			if (from.indexOf('?') >= 0) {
				// Expand wildcard digits into range bounds.
				to = from.replace(/\?/g, 'F');
				from = from.replace(/\?/g, '0');
			}
			return parseInt(from, 16) + '-' + parseInt(to, 16);
		}).sort().join(',');
	}
	// faceKey(family, [style], [weight], [range]) identifies a font face.
	// Defaults are normal style, weight 400 and the full Unicode range.
	function faceKey(family, style, weight, range) {
		weight = (weight || '400').trim().toLowerCase();
		weight = weight === 'normal' ? '400' : weight === 'bold' ? '700' : weight;
		return [ unquote(family).toLowerCase(), (style || 'normal').trim().toLowerCase(),
			 weight, ranges(range) ].join('|');
	}
	// dataUri(url) resolves to font data, or null if fetching fails.
	function dataUri(url) {
		// Only fetch font files served by this Webmin origin.
		if (url.origin !== location.origin) return Promise.resolve(null);
		return fetch(url.href, { credentials: 'same-origin' }).then(function (response) {
			return response.ok ? response.blob() : null;
		}).then(function (blob) {
			// Keep fallback fonts after a failed fetch.
			if (!blob) return null;
			return new Promise(function (resolve) {
				var reader = new FileReader();
				reader.onload = function () { resolve(reader.result); };
				reader.onerror = function () { resolve(null); };
				reader.readAsDataURL(blob);
			});
		}).catch(function () { return null; });
	}
	// inlineRule(cssText, base) embeds all font URLs or omits the rule.
	function inlineRule(cssText, base) {
		var urls = [], pattern = /url\((['"]?)([^'")]+)\1\)/g, match;
		while ((match = pattern.exec(cssText))) {
			try { urls.push(new URL(match[2], base)); } catch (e) { return Promise.resolve(''); }
		}
		return Promise.all(urls.map(dataUri)).then(function (datas) {
			// Omit rules with any unavailable font file.
			if (!datas.length || datas.some(function (data) { return !data; })) return '';
			var i = 0;
			return cssText.replace(/url\((['"]?)([^'")]+)\1\)/g, function () {
				return 'url(' + datas[i++] + ')';
			});
		});
	}
	// collectFonts() embeds loaded fonts used by the page's font tokens.
	function collectFonts() {
		var styles = getComputedStyle(page), wanted = {}, loaded = {}, jobs = [];
		// Include proportional and monospace font families.
		['--ui-font', '--ui-font-mono'].forEach(function (name) {
			styles.getPropertyValue(name).split(',').forEach(function (family) {
				// Ignore empty family names.
				if (unquote(family)) wanted[unquote(family).toLowerCase()] = true;
			});
		});
		document.fonts.forEach(function (face) {
			// Copy only variants the browser has already loaded.
			if (face.status === 'loaded') {
				loaded[faceKey(face.family, face.style, face.weight, face.unicodeRange)] = true;
			}
		});
		Array.prototype.forEach.call(document.styleSheets, function (sheet) {
			var rules;
			// Skip stylesheets whose rules cannot be read.
			try { rules = sheet.cssRules; } catch (e) { return; }
			Array.prototype.forEach.call(rules, function (rule) {
				// Only font rules can supply embedded fonts.
				if (!(rule instanceof CSSFontFaceRule)) return;
				var style = rule.style, family = unquote(style.getPropertyValue('font-family'));
				// Skip families unused by this theme.
				if (!wanted[family.toLowerCase()]) return;
				// Match the loaded font variant exactly.
				if (!loaded[faceKey(family, style.getPropertyValue('font-style'),
						    style.getPropertyValue('font-weight'),
						    style.getPropertyValue('unicode-range'))]) return;
				jobs.push(inlineRule(rule.cssText, sheet.href || location.href));
			});
		});
		return Promise.all(jobs).then(function (texts) {
			return texts.filter(Boolean).join('\n');
		});
	}

	var fontKey = '';
	// refreshFonts() embeds fonts after the page's font families change.
	function refreshFonts() {
		// Use fallback fonts without the font-loading API.
		if (!document.fonts || !document.fonts.ready) return;
		var styles = getComputedStyle(page);
		var key = ['--ui-font', '--ui-font-mono'].map(function (name) {
			return styles.getPropertyValue(name).trim();
		}).join('|');
		// Wait for font tokens and skip unchanged families.
		if (key === '|' || key === fontKey) return;
		fontKey = key;
		document.fonts.ready.then(collectFonts).then(function (css) {
			// Discard results for an old page or font choice.
			if (!frame.isConnected || fontKey !== key) return;
			fonts = css;
			send(true);
		}).catch(function () {});
	}

	// Load the report with the current palette, then keep it in sync.
	var initial = palette();
	last = JSON.stringify(initial);
	frame.setAttribute('data-ui-scheme', initial.scheme);
	frame.addEventListener('load', function () { ready(); send(true); });
	frame.src = frame.getAttribute('data-src') + '#ui=' +
		encodeURIComponent(JSON.stringify(initial));
	observer.observe(document.documentElement, { attributes: true });
	observer.observe(document.body, { attributes: true });
	// Themes add, replace and remove stylesheets, including rounded corners.
	observer.observe(document.head, { childList: true, subtree: true, attributes: true });
	// Capture load events from existing and newly inserted stylesheets.
	document.addEventListener('load', onStylesheetLoad, true);
	refreshFonts();
})();
