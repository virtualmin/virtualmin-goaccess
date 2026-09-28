// Run with node t/report-tooltips.js. Check positioning with a simulated DOM.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const documentEvents = {}, windowEvents = {};
const root = { clientWidth: 600 };
let tooltips = [];
const document = {
    documentElement: root,
    addEventListener: (name, callback) => { documentEvents[name] = callback; },
    querySelectorAll: () => tooltips
};
const window = {
    parent: {},
    addEventListener: (name, callback) => { windowEvents[name] = callback; }
};
vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../frame/theme.js'), 'utf8'),
    { document, window, location: { hash: '' } });

// tooltip(origin, width) models an absolutely positioned tooltip in a chart.
// origin is the chart's left edge in viewport coordinates.
function tooltip(origin, width) {
    return {
        style: { left: '0px' }, offsetWidth: width,
        getBoundingClientRect() {
            const left = origin + parseFloat(this.style.left);
            return { left, right: left + width, width };
        }
    };
}

// hover(tip, left) simulates GoAccess positioning a tooltip before the
// document's mousemove handler runs.
function hover(tip, left) {
    tip.style.left = left + 'px';
    documentEvents.mousemove?.({ target: {
        closest: () => ({ querySelector: () => tip })
    } });
}

// Include the chart's offset when checking the frame's right edge.
let tip = tooltip(300, 200);
hover(tip, 240);
assert.equal(tip.getBoundingClientRect().right, 592, 'Right edge stays inside the frame');
hover(tip, 250);
assert.equal(tip.getBoundingClientRect().right, 592, 'Repeated hover keeps the tooltip in bounds');

// Moving back to a point with enough room restores GoAccess's chosen position.
hover(tip, 20);
assert.equal(tip.style.left, '20px', 'An unclipped tooltip keeps its original position');
tip = tooltip(-30, 200);
hover(tip, 0);
assert.equal(tip.getBoundingClientRect().left, 8, 'The left edge also stays visible');

// Handle replacement tooltips after a chart redraw, then a narrower frame.
const replacement = tooltip(350, 230);
hover(replacement, 180);
assert.equal(replacement.getBoundingClientRect().right, 592, 'Replacement tooltips stay in bounds');
tooltips = [replacement];
root.clientWidth = 400;
windowEvents.resize();
assert.equal(replacement.getBoundingClientRect().right, 392, 'Resizing keeps visible tooltips in bounds');

// Model the width limit set by CSS. This test does not check CSS layout.
root.clientWidth = 280;
tip = tooltip(20, 264);
hover(tip, 200);
assert.equal(tip.getBoundingClientRect().left, 8, 'Wide tooltips fit a narrow frame');
assert.equal(tip.getBoundingClientRect().right, 272);

// Hidden tooltips and mouse movement outside a chart do not need repositioning.
tip = tooltip(500, 0);
hover(tip, 40);
assert.equal(tip.style.left, '40px', 'Hidden tooltips are ignored');
documentEvents.mousemove({ target: { closest: () => null } });
documentEvents.mousemove({ target: {} });
documentEvents.mousemove({ target: { closest: () => ({ querySelector: () => null }) } });
console.log('Report tooltip checks passed');
