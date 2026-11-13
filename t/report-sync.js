// Run with node t/report-sync.js. Exercise report.js before its CSS is ready.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

// The page starts without widget tokens, as it can during Ajax navigation.
const tokens = {};
const metrics = { marginLeft: '7px', borderTopLeftRadius: '0px' };
const cardMetrics = { borderTopLeftRadius: '0px' };
const messages = [];
const documentEvents = {};
const observations = new Map();
let themeChanged;
// appendChild() ignores mounting the theme probe in this mock page.
const page = { appendChild() {} };
const card = {};
const frame = {
    isConnected: true,
    // closest(selector) distinguishes the widget card from its outer page.
    closest: selector => selector === '.ui_card' ? card : page,
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
    // constructor(callback) exposes theme changes to the test.
    constructor(callback) { themeChanged = callback; }
    // observe(target, options) records which theme changes are watched.
    observe(target, options) { observations.set(target, options); }
    // disconnect() releases all observed nodes.
    disconnect() { observations.clear(); }
}
const document = {
    body: {}, head: {}, documentElement: {},
    // getElementById() always returns the fixture frame.
    getElementById: () => frame,
    // createElement() returns a theme probe with a no-op remove().
    createElement: () => ({ style: {}, remove() {} }),
    // addEventListener(event, callback, capture) captures stylesheet loads.
    addEventListener(event, callback, capture) {
        assert.equal(capture, true, 'Stylesheet load events require capture');
        documentEvents[event] = callback;
    },
    // removeEventListener(event, callback) releases the matching handler.
    removeEventListener(event, callback) {
        if (documentEvents[event] === callback) delete documentEvents[event];
    },
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
    // getComputedStyle() supplies resolved lengths and theme tokens.
    getComputedStyle: element => ({ ...(element === card ? cardMetrics : metrics), color: 'rgb(255, 255, 255)',
        getPropertyValue: name => tokens[name] || '' }),
    requestAnimationFrame: callback => callback(),
    // fetch() counts reads; blob() supplies bytes to the fake FileReader.
    fetch: async () => { fetched++; return { ok: true, blob: async () => ({}) }; }
};

// settle() drains font collection and FileReader promises between UI events.
const settle = () => new Promise(resolve => setImmediate(resolve));
// stylesheetLoaded() simulates a load from any existing or newly added link.
const stylesheetLoaded = () => documentEvents.load({ target: { matches: () => true } });

// test() verifies delayed CSS, repeated load events and a disconnected frame.
async function test() {
    vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../report.js'), 'utf8'), context);
    await settle();
    assert.equal(fetched, 0, 'No font requests before the page has font tokens');
    const initial = JSON.parse(decodeURIComponent(frame.src.split('#ui=')[1]));
    assert.equal(initial.tokens['--ui-gap'], '7px', 'Initial spacing reaches the frame URL');
    assert.equal(initial.tokens['--ui-radius'], '0px', 'Square corners reach the frame URL');

    // Loading the stylesheet supplies the previously missing font family.
    tokens['--ui-font'] = 'TestFont';
    tokens['--ui-surface'] = '#ffffff';
    metrics.marginLeft = '6px';
    metrics.borderTopLeftRadius = '10.6667px';
    stylesheetLoaded();
    await settle();
    assert.equal(fetched, 1, 'Stylesheet load collects the newly available font');
    assert.ok(messages.some(message => message.fonts?.includes('data:font/woff2;base64,AAAA')),
        'The opaque report frame receives an embedded font after CSS becomes ready');
    assert.equal(messages.at(-1).tokens['--ui-gap'], '6px', 'Loaded theme spacing reaches the frame');
    assert.equal(messages.at(-1).tokens['--ui-radius'], '0px', 'Rounded outer pages keep square report widgets');

    // Changing the outer page radius must not round the report widgets.
    metrics.marginLeft = '4px';
    metrics.borderTopLeftRadius = '20px';
    themeChanged();
    assert.equal(messages.at(-1).tokens['--ui-gap'], '4px', 'Theme changes refresh spacing');
    assert.equal(messages.at(-1).tokens['--ui-radius'], '0px', 'Report corners still match the square card');

    // Styles that change the widget card itself must reach the frame.
    const headOptions = observations.get(document.head);
    assert.ok(headOptions?.childList && headOptions.subtree && headOptions.attributes,
        'Stylesheet insertion, removal and attribute changes are watched');
    const count = messages.length;
    cardMetrics.borderTopLeftRadius = '6px';
    documentEvents.load({ target: { matches: () => false } });
    assert.equal(messages.length, count, 'Image and frame loads do not resync styles');
    stylesheetLoaded();
    assert.equal(messages.at(-1).tokens['--ui-radius'], '6px', 'The report follows a custom widget radius');
    cardMetrics.borderTopLeftRadius = '0px';
    themeChanged([{ target: document.head, type: 'childList' }]);
    assert.equal(messages.at(-1).tokens['--ui-radius'], '0px', 'Removing rounded styles restores square corners');

    // Repeated loads reuse fonts; removing the frame stops synchronization.
    stylesheetLoaded();
    await settle();
    assert.equal(fetched, 1, 'Unchanged fonts are not fetched repeatedly');
    frame.isConnected = false;
    stylesheetLoaded();
    assert.equal(context.window.goaccessFrameSync, null, 'Navigation releases the old frame synchronizer');
    assert.equal(documentEvents.load, undefined, 'Navigation releases the stylesheet listener');
    assert.equal(observations.size, 0, 'Navigation releases stylesheet observation');
    console.log('Report synchronization checks passed');
}
test().catch(error => { console.error(error); process.exitCode = 1; });
