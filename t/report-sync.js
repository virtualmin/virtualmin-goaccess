// Run with node t/report-sync.js. Exercise report.js before its CSS is ready.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

// The page starts without widget tokens, as it can during Ajax navigation.
const tokens = {};
const messages = [];
const stylesheetEvents = {};
// appendChild() ignores mounting the color probe in this mock page.
const page = { appendChild() {} };
const frame = {
    isConnected: true,
    // closest() supplies the page used for theme-token lookup.
    closest: () => page,
    // getAttribute(name) supplies only the deferred report URL.
    getAttribute: name => name === 'data-src' ? 'report.cgi?dom=123' : null,
    // setAttribute() and addEventListener() ignore unused DOM changes.
    setAttribute() {},
    addEventListener() {},
    // postMessage(message) records palettes sent to the frame.
    contentWindow: { postMessage: message => messages.push(message) }
};

// Supply one already loaded, same-origin font without making network requests.
class CSSFontFaceRule {
    // constructor() defines one font rule for the simulated stylesheet.
    constructor() {
        // getPropertyValue(name) supplies descriptors for the test font.
        this.style = { getPropertyValue: name => ({
            'font-family': 'TestFont', 'font-weight': '400',
            'font-style': 'normal', 'unicode-range': 'U+0000-00FF'
        })[name] || '' };
        this.cssText = '@font-face { font-family: TestFont; src: url(font.woff2); }';
    }
}
let fetched = 0;
class FileReader {
    // readAsDataURL() completes a synthetic font read asynchronously.
    readAsDataURL() {
        this.result = 'data:font/woff2;base64,AAAA';
        queueMicrotask(() => this.onload());
    }
}
class MutationObserver {
    // observe() and disconnect() are no-ops; tests trigger stylesheet events.
    observe() {}
    disconnect() {}
}
const document = {
    body: {}, documentElement: {},
    // getElementById() always returns the fixture frame.
    getElementById: () => frame,
    // createElement() returns a color probe with a no-op remove().
    createElement: () => ({ style: {}, remove() {} }),
    // querySelectorAll() returns one stylesheet link.
    // addEventListener(event, callback) records its load handler.
    querySelectorAll: () => [{ addEventListener: (event, callback) => {
        stylesheetEvents[event] = callback;
    } }],
    fonts: {
        ready: Promise.resolve(),
        // forEach(callback) exposes the single loaded font variant.
        forEach: callback => callback({ family: 'TestFont', weight: '400',
            style: 'normal', unicodeRange: 'U+0-FF', status: 'loaded' })
    },
    styleSheets: [{ href: 'https://webmin.example/ui-lib.css', cssRules: [new CSSFontFaceRule()] }]
};
// Resolve styles and font reads inside the test, without a real browser.
const context = {
    document, CSSFontFaceRule, FileReader, MutationObserver, URL,
    location: new URL('https://webmin.example/virtualmin-goaccess/view.cgi'),
    // Window addEventListener() and removeEventListener() need no mock state.
    window: { addEventListener() {}, removeEventListener() {} },
    // getComputedStyle() reads tokens through getPropertyValue(name).
    getComputedStyle: () => ({ color: 'rgb(255, 255, 255)',
        getPropertyValue: name => tokens[name] || '' }),
    requestAnimationFrame: callback => callback(),
    // fetch() counts reads; blob() supplies bytes to the fake FileReader.
    fetch: async () => { fetched++; return { ok: true, blob: async () => ({}) }; }
};

// settle() drains font collection and FileReader promises between UI events.
const settle = () => new Promise(resolve => setImmediate(resolve));

// test() verifies delayed CSS, repeated load events and a disconnected frame.
async function test() {
    vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../report.js'), 'utf8'), context);
    await settle();
    assert.equal(fetched, 0, 'No font requests before the page has font tokens');

    // Loading the stylesheet supplies the previously missing font family.
    tokens['--ui-font'] = 'TestFont';
    tokens['--ui-surface'] = '#ffffff';
    stylesheetEvents.load();
    await settle();
    assert.equal(fetched, 1, 'Stylesheet load collects the newly available font');
    assert.ok(messages.some(message => message.fonts?.includes('data:font/woff2;base64,AAAA')),
        'The opaque report frame receives an embedded font after CSS becomes ready');

    // Repeated loads reuse fonts; removing the frame stops synchronization.
    stylesheetEvents.load();
    await settle();
    assert.equal(fetched, 1, 'Unchanged fonts are not fetched repeatedly');
    frame.isConnected = false;
    stylesheetEvents.load();
    assert.equal(context.window.goaccessFrameSync, null, 'Navigation releases the old frame synchronizer');
    console.log('Report synchronization checks passed');
}
test().catch(error => { console.error(error); process.exitCode = 1; });
