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
const page = { appendChild() {} };
const frame = {
    isConnected: true,
    closest: () => page,
    getAttribute: name => name === 'data-src' ? 'report.cgi?dom=123' : null,
    setAttribute() {},
    addEventListener() {},
    contentWindow: { postMessage: message => messages.push(message) }
};

// Supply one already loaded, same-origin font without making network requests.
class CSSFontFaceRule {
    constructor() {
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
    observe() {}
    disconnect() {}
}
const document = {
    body: {}, documentElement: {},
    getElementById: () => frame,
    createElement: () => ({ style: {}, remove() {} }),
    querySelectorAll: () => [{ addEventListener: (event, callback) => {
        stylesheetEvents[event] = callback;
    } }],
    fonts: {
        ready: Promise.resolve(),
        forEach: callback => callback({ family: 'TestFont', weight: '400',
            style: 'normal', unicodeRange: 'U+0-FF', status: 'loaded' })
    },
    styleSheets: [{ href: 'https://webmin.example/ui-lib.css', cssRules: [new CSSFontFaceRule()] }]
};
const context = {
    document, CSSFontFaceRule, FileReader, MutationObserver, URL,
    location: new URL('https://webmin.example/virtualmin-goaccess/view.cgi'),
    window: { addEventListener() {}, removeEventListener() {} },
    getComputedStyle: () => ({ color: 'rgb(255, 255, 255)',
        getPropertyValue: name => tokens[name] || '' }),
    requestAnimationFrame: callback => callback(),
    fetch: async () => { fetched++; return { ok: true, blob: async () => ({}) }; }
};

// settle() drains font collection and FileReader promises between UI events.
const settle = () => new Promise(resolve => setImmediate(resolve));

// test() verifies delayed CSS, repeated load events and a disconnected frame.
async function test() {
    vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../report.js'), 'utf8'), context);
    await settle();
    assert.equal(fetched, 0, 'No font requests before the page has font tokens');

    tokens['--ui-font'] = 'TestFont';
    tokens['--ui-surface'] = '#ffffff';
    stylesheetEvents.load();
    await settle();
    assert.equal(fetched, 1, 'Stylesheet load collects the newly available font');
    assert.ok(messages.some(message => message.fonts?.includes('data:font/woff2;base64,AAAA')),
        'The opaque report frame receives an embedded font after CSS becomes ready');

    stylesheetEvents.load();
    await settle();
    assert.equal(fetched, 1, 'Unchanged fonts are not fetched repeatedly');
    frame.isConnected = false;
    stylesheetEvents.load();
    assert.equal(context.window.goaccessFrameSync, null, 'Navigation releases the old frame synchronizer');
    console.log('Report synchronization checks passed');
}
test().catch(error => { console.error(error); process.exitCode = 1; });
