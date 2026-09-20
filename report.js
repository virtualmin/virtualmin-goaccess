// Match the GoAccess frame's palette and fonts to Webmin, and size it to the report.
//
// Read the widget stylesheet's --ui-* properties from .ui_page. Send them
// in the frame's URL fragment on load, then by postMessage when the theme
// or stylesheet changes. The frame's opaque origin prevents direct DOM
// access. frame/theme.js applies the palette and sends back the report height.
(function () {
	'use strict';
	var frame = document.getElementById('goaccess-frame');
	if (!frame || frame.getAttribute('src')) return;
	var page = frame.closest('.ui_page') || document.body;
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

	// Resolve the surface color on a hidden element for the brightness check.
	var probe = document.createElement('span');
	probe.hidden = true;
	page.appendChild(probe);
	// isDark(color) selects the frame's color scheme from the page surface.
	function isDark(color) {
		probe.style.color = '';
		probe.style.color = color;
		var parts = (getComputedStyle(probe).color.match(/[\d.]+/g) || []).map(Number);
		if (parts.length < 3) return false;
		return (0.2126 * parts[0] + 0.7152 * parts[1] + 0.0722 * parts[2]) / 255 < 0.5;
	}

	// palette() returns the page's theme tokens, color scheme and collected fonts.
	var fonts = '';
	function palette() {
		var styles = getComputedStyle(page), tokens = {};
		TOKENS.forEach(function (name) {
			var value = styles.getPropertyValue('--ui-' + name).trim();
			// A theme without fonts of its own leaves those tokens as keywords.
			if (value && !/^(inherit|initial|unset|revert)$/i.test(value)) {
				tokens['--ui-' + name] = value;
			}
		});
		var surface = tokens['--ui-surface'];
		var message = { type: 'webmin-ui-palette', tokens: tokens,
				scheme: surface && isDark(surface) ? 'dark' : 'light' };
		if (fonts) message.fonts = fonts;
		return message;
	}

	var last = '';
	// send(force) updates changed palettes, or resends one after a frame load.
	function send(force) {
		if (!frame.isConnected) return stop();
		var message = palette(), key = JSON.stringify(message);
		if (!force && key === last) return;
		last = key;
		// The scheme on the frame element shows what it was given last.
		frame.setAttribute('data-ui-scheme', message.scheme);
		if (frame.contentWindow) frame.contentWindow.postMessage(message, '*');
		refreshFonts();
	}

	// Read theme changes on the next animation frame, after styles are updated.
	var observer = new MutationObserver(function () {
		requestAnimationFrame(function () { send(false); });
	});
	// Hide the spinner on frame load or the first size message, whichever is first.
	var loading = frame.parentElement &&
		frame.parentElement.querySelector('.goaccess-frame-loading');
	// ready() removes the loading indicator once the report can be displayed.
	function ready() {
		if (loading) loading.hidden = true;
	}

	// onFrameMessage(event) sizes the frame to the report, with a 320px minimum,
	// so the page scrolls without a separate scrollbar inside the report.
	function onFrameMessage(event) {
		if (event.source !== frame.contentWindow) return;
		var data = event.data;
		if (!data || data.type !== 'webmin-frame-size') return;
		var height = Number(data.height);
		if (!(height > 0 && height < 200000)) return;
		ready();
		frame.style.minHeight = '0';
		frame.style.height = Math.max(Math.ceil(height), 320) + 'px';
	}
	window.addEventListener('message', onFrameMessage);
	// stop() releases document listeners when this report is replaced or removed.
	function stop() {
		observer.disconnect();
		window.removeEventListener('message', onFrameMessage);
		probe.remove();
		if (window.goaccessFrameSync && window.goaccessFrameSync.stop === stop) {
			window.goaccessFrameSync = null;
		}
	}
	window.goaccessFrameSync = { stop: stop };

	// The frame blocks font requests but allows data: URIs. Embed only the
	// theme font faces already loaded by the parent page to limit the transfer.
	// unquote(text) normalizes CSS family names for comparison with FontFace data.
	function unquote(text) {
		return (text || '').trim().replace(/^["']|["']$/g, '');
	}
	// ranges(text) normalizes Unicode ranges to numbers, ignoring leading zeros.
	function ranges(text) {
		return (text || 'U+0-10FFFF').toUpperCase().split(',').map(function (part) {
			var match = /U\+([0-9A-F?]+)(?:-([0-9A-F]+))?/.exec(part.trim());
			if (!match) return '';
			var from = match[1], to = match[2] || match[1];
			if (from.indexOf('?') >= 0) {
				to = from.replace(/\?/g, 'F');
				from = from.replace(/\?/g, '0');
			}
			return parseInt(from, 16) + '-' + parseInt(to, 16);
		}).sort().join(',');
	}
	// faceKey(family, style, weight, range) identifies one loaded font variant.
	function faceKey(family, style, weight, range) {
		weight = (weight || '400').trim().toLowerCase();
		weight = weight === 'normal' ? '400' : weight === 'bold' ? '700' : weight;
		return [ unquote(family).toLowerCase(), (style || 'normal').trim().toLowerCase(),
			 weight, ranges(range) ].join('|');
	}
	// dataUri(url) resolves to an embedded same-origin font, or null on failure.
	function dataUri(url) {
		if (url.origin !== location.origin) return Promise.resolve(null);
		return fetch(url.href, { credentials: 'same-origin' }).then(function (response) {
			return response.ok ? response.blob() : null;
		}).then(function (blob) {
			if (!blob) return null;
			return new Promise(function (resolve) {
				var reader = new FileReader();
				reader.onload = function () { resolve(reader.result); };
				reader.onerror = function () { resolve(null); };
				reader.readAsDataURL(blob);
			});
		}).catch(function () { return null; });
	}
	// inlineRule(cssText, base) replaces every font URL or omits the whole rule.
	function inlineRule(cssText, base) {
		var urls = [], pattern = /url\((['"]?)([^'")]+)\1\)/g, match;
		while ((match = pattern.exec(cssText))) {
			try { urls.push(new URL(match[2], base)); } catch (e) { return Promise.resolve(''); }
		}
		return Promise.all(urls.map(dataUri)).then(function (datas) {
			if (!datas.length || datas.some(function (data) { return !data; })) return '';
			var i = 0;
			return cssText.replace(/url\((['"]?)([^'")]+)\1\)/g, function () {
				return 'url(' + datas[i++] + ')';
			});
		});
	}
	// collectFonts() copies the loaded faces belonging to the page's font tokens.
	function collectFonts() {
		var styles = getComputedStyle(page), wanted = {}, loaded = {}, jobs = [];
		['--ui-font', '--ui-font-mono'].forEach(function (name) {
			styles.getPropertyValue(name).split(',').forEach(function (family) {
				if (unquote(family)) wanted[unquote(family).toLowerCase()] = true;
			});
		});
		document.fonts.forEach(function (face) {
			if (face.status === 'loaded') {
				loaded[faceKey(face.family, face.style, face.weight, face.unicodeRange)] = true;
			}
		});
		Array.prototype.forEach.call(document.styleSheets, function (sheet) {
			var rules;
			try { rules = sheet.cssRules; } catch (e) { return; }
			Array.prototype.forEach.call(rules, function (rule) {
				if (!(rule instanceof CSSFontFaceRule)) return;
				var style = rule.style, family = unquote(style.getPropertyValue('font-family'));
				if (!wanted[family.toLowerCase()]) return;
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

	// refreshFonts() collects loaded fonts when the page's font families change.
	// Ajax navigation can run this script before the widget stylesheet loads.
	var fontKey = '';
	function refreshFonts() {
		if (!document.fonts || !document.fonts.ready) return;
		var styles = getComputedStyle(page);
		var key = ['--ui-font', '--ui-font-mono'].map(function (name) {
			return styles.getPropertyValue(name).trim();
		}).join('|');
		if (key === '|' || key === fontKey) return;
		fontKey = key;
		document.fonts.ready.then(collectFonts).then(function (css) {
			// Ignore work belonging to a removed page or an older font choice.
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
	// On Ajax navigation the widget stylesheet may still be loading.
	document.querySelectorAll('link[href*="ui-lib.css"]').forEach(function (link) {
		link.addEventListener('load', function () { send(false); });
	});
	refreshFonts();
})();
