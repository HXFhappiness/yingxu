// test_yxpad_edit.js — 用最小 DOM 桩在 Node 里跑 yxpad 真实逻辑，验证 细化/取色/撤销
const fs = require('fs');
const path = require('path');

const html = fs.readFileSync(path.join(__dirname, 'yxpad.html'), 'utf8');
const js = html.slice(html.indexOf('<script>') + 8, html.lastIndexOf('</script>'));

// ---- 最小 DOM 桩 ----
const ctxStub = new Proxy({}, {
  get(t, k) {
    if (k === 'canvas') return { width: 320, height: 320 };
    if (k === 'measureText') return () => ({ width: 10 });
    if (k === 'getImageData') return (x, y, w, h) => ({
      data: new Uint8ClampedArray(Math.max(1, w * h * 4)), width: w, height: h,
    });
    if (k === 'createImageData') return (w, h) => ({
      data: new Uint8ClampedArray(Math.max(1, w * h * 4)), width: w, height: h,
    });
    if (k === 'putImageData') return () => {};
    return () => {};
  },
  set() { return true; },
});

function makeEl(id) {
  return {
    id, style: {}, value: '', textContent: '', title: '', dataset: {}, children: [],
    classList: {
      _s: new Set(),
      add(c) { this._s.add(c); }, remove(c) { this._s.delete(c); },
      toggle(c, on) { if (on === undefined) on = !this._s.has(c); on ? this._s.add(c) : this._s.delete(c); return on; },
      contains(c) { return this._s.has(c); },
    },
    appendChild(c) { this.children.push(c); return c; },
    addEventListener() {}, removeEventListener() {},
    setPointerCapture() {}, releasePointerCapture() {}, hasPointerCapture() { return false; },
    getBoundingClientRect() { return { left: 0, top: 0, width: 320, height: 320 }; },
    getContext() { return ctxStub; },
    onclick: null, onchange: null, oninput: null,
  };
}
const els = new Map();
const document = {
  getElementById(id) { if (!els.has(id)) els.set(id, makeEl(id)); return els.get(id); },
  createElement(tag) { return makeEl(tag); },
  addEventListener() {},
  createEvent() { return { initEvent() {} }; },
  body: makeEl('body'),
};
const window = { addEventListener() {}, devicePixelRatio: 1, getComputedStyle: () => ({}) };

const wrapper = js + `
;globalThis.__api = { get W(){return W}, set W(v){W=v}, get H(){return H}, set H(v){H=v},
    get px(){return px}, set px(v){px=v},
    get cur(){return cur}, set cur(v){cur=v},
    upscale2, pickAt, undo };
`;

const fn = new Function('document', 'window', 'Blob', 'URL', 'alert', 'confirm', 'navigator', wrapper);
fn(document, window, function () {}, { createObjectURL: () => 'x', revokeObjectURL: () => {} },
   () => {}, () => true, {});
const api = globalThis.__api;
if (!api) { console.error('stub failed: api undefined'); process.exit(2); }

let pass = 0, fail = 0;
function check(name, cond, extra) {
  if (cond) { pass++; console.log('  OK  ', name); }
  else { fail++; console.log('  FAIL', name, extra || ''); }
}

console.log('=== 细化 x2 ===');
api.W = 32; api.H = 32;
api.px = new Uint8Array(32 * 32).fill(0xFF);
api.px[0] = 0x21;
api.px[1] = 0x22;
api.upscale2();
check('画布 32x32 -> 64x64', api.W === 64 && api.H === 64, `${api.W}x${api.H}`);
check('(0,0) 扩成 2x2', api.px[0] === 0x21 && api.px[1] === 0x21 &&
                        api.px[64] === 0x21 && api.px[65] === 0x21);
check('(1,0) 扩到右侧', api.px[2] === 0x22 && api.px[3] === 0x22);
check('透明像素保持透明', api.px[10] === 0xFF);

console.log('=== 取色 ===');
api.pickAt(2, 0);
check('取 (2,0) = 0x22', api.cur === 0x22, '0x' + api.cur.toString(16));
api.pickAt(0, 0);
check('取 (0,0) = 0x21', api.cur === 0x21, '0x' + api.cur.toString(16));
api.cur = 0x11;
api.pickAt(-1, 0);
check('越界不改变当前色', api.cur === 0x11);

console.log('=== 撤销（含尺寸） ===');
api.undo();
check('撤销回到 32x32', api.W === 32 && api.H === 32, `${api.W}x${api.H}`);
check('撤销后像素恢复', api.px[0] === 0x21 && api.px.length === 32 * 32);

console.log('');
console.log(`结果: ${pass} 通过 / ${fail} 失败`);
process.exit(fail ? 1 : 0);
