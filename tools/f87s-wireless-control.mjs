// F87S 2.4G controller: verified cmd36 RGB888 + cmd35 mode20 brightness5.
// Managed Node 22 and the existing node-hid installation are required.
// Stop other keyboard LED writers before using this tool.
import HID from 'node-hid';
import fs from 'node:fs';
import { performance } from 'node:perf_hooks';

const REPORT_BODY_BYTES = 64, PAYLOAD_BYTES = 56, SLOTS = 128;
const ALLOWED = new Set([16, 19, 20, 35, 36]);
// Embedded copy of the project's calibrated 87-key mapping, so this file is portable.
const mapping = {
  Escape: 0, F1: 1, F2: 2, F3: 3, F4: 4, F5: 5, F6: 6, F7: 7, F8: 8, F9: 9, F10: 10, F11: 11, F12: 12,
  PrintScreen: 99, ScrollLock: 100, Pause: 102,
  Backquote: 16, Digit1: 17, Digit2: 18, Digit3: 19, Digit4: 20, Digit5: 21, Digit6: 22, Digit7: 23, Digit8: 24, Digit9: 25, Digit0: 26, Minus: 27, Equal: 28,
  Backspace: 92, Insert: 103, Home: 104, PageUp: 105,
  Tab: 32, KeyQ: 33, KeyW: 34, KeyE: 35, KeyR: 36, KeyT: 37, KeyY: 38, KeyU: 39, KeyI: 40, KeyO: 41, KeyP: 42, BracketLeft: 43, BracketRight: 44, Backslash: 60,
  Delete: 106, End: 107, PageDown: 108,
  CapsLock: 48, KeyA: 49, KeyS: 50, KeyD: 51, KeyF: 52, KeyG: 53, KeyH: 54, KeyJ: 55, KeyK: 56, KeyL: 57, Semicolon: 58, Quote: 59, Enter: 76,
  ShiftLeft: 64, KeyZ: 65, KeyX: 66, KeyC: 67, KeyV: 68, KeyB: 69, KeyN: 70, KeyM: 71, Comma: 72, Period: 73, Slash: 74, ShiftRight: 75, ArrowUp: 90,
  ControlLeft: 80, MetaLeft: 81, AltLeft: 82, Space: 83, AltRight: 84, Fn: 85, ContextMenu: 86, ControlRight: 87, ArrowLeft: 88, ArrowDown: 89, ArrowRight: 91
};
const resultFile = new URL('./f87s-wireless-last-run.json', import.meta.url);
const snapshotFile = new URL('./f87s-wireless-demo-backup.json', import.meta.url);
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const result = { startedAt: new Date().toISOString(), transport: '2.4G', events: [] };
let device, interrupted = false;
process.on('SIGINT', () => { interrupted = true; });
process.on('SIGTERM', () => { interrupted = true; });

export function buildPacket(cmd, payload, address = 0, last = true) {
  if (!ALLOWED.has(cmd)) throw new Error('Command is not on the lighting allowlist');
  if (payload.length > PAYLOAD_BYTES || address < 0 || address > 65535) throw new Error('Invalid packet dimensions');
  const p = Buffer.alloc(REPORT_BODY_BYTES + 1);
  p[1] = 0xaa; p[2] = cmd; p[3] = payload.length;
  p.writeUInt16LE(address, 4); p[7] = last ? 1 : 0;
  payload.copy(p, 9);
  return p;
}

function record(event) { result.events.push(event); console.log(JSON.stringify(event)); }
function connect() {
  const info = HID.devices().find(d => d.vendorId === 0x0c45 && d.productId === 0xfef9 && d.interface === 3 && d.usagePage === 0xff60);
  if (!info) throw new Error('未找到 F87S 2.4G 接收器 MI_03/0xFF60，请插接收器并切无线模式');
  result.device = { vid: '0x0C45', pid: '0xFEF9', interface: 3, usagePage: '0xFF60', product: info.product };
  device = new HID.HID(info.path);
}
function drain() { for (let i = 0; i < 64; i++) if (!device.readTimeout(0).length) break; }
function waitForAck(cmd, address, size, timeout = 900) {
  const start = performance.now();
  while (performance.now() - start < timeout) {
    const p = Buffer.from(device.readTimeout(Math.max(1, Math.ceil(timeout - (performance.now() - start)))));
    if (p.length < 8 || p[0] !== 0x55 || p[1] !== cmd) continue;
    if (p.readUInt16LE(3) !== address || p[2] !== size || p.length < 8 + size) continue;
    return Buffer.from(p.subarray(8, 8 + size));
  }
  return null;
}
function command(cmd, data) {
  if (!Buffer.isBuffer(data) || !data.length) throw new Error('Expected declared query/write payload');
  const parts = [];
  for (let address = 0; address < data.length; address += PAYLOAD_BYTES) {
    const chunk = data.subarray(address, address + PAYLOAD_BYTES);
    const p = buildPacket(cmd, chunk, address, address + chunk.length === data.length);
    let ack;
    for (let attempt = 0; attempt < 4; attempt++) {
      drain();
      const written = device.write(p);
      if (written !== p.length) throw new Error('Incomplete HID write: ' + written);
      ack = waitForAck(cmd, address, chunk.length);
      if (ack) break;
    }
    if (!ack) throw new Error('无线响应超时 cmd=' + cmd + ' addr=' + address + '，请按键唤醒，并确认其他灯光软件已退出');
    parts.push(ack);
  }
  return Buffer.concat(parts);
}
function bytes(args, defaults = [0, 100, 180]) {
  const color = args.length ? args.map(Number) : defaults;
  if (color.length !== 3 || color.some(v => !Number.isInteger(v) || v < 0 || v > 255)) throw new Error('RGB 必须是三个 0..255 的整数');
  return color;
}
function solid(color, activeSlot = -1) {
  const table = Buffer.alloc(SLOTS * 4);
  for (let i = 0; i < SLOTS; i++) {
    table[i * 4] = i;
    if (activeSlot < 0 || i === activeSlot) table.set(color, i * 4 + 1);
  }
  return table;
}
function customEffect(saved) {
  const effect = Buffer.from(saved);
  effect[0] = 20; effect[9] = 5; effect[14] = 0xaa; effect[15] = 0x55;
  return effect;
}
function writeFrame(table, effect) {
  command(36, table);
  // Commit each complete table. CMD36-only optical refresh is not assumed.
  command(35, effect);
}
function snapshot() {
  return { device: result.device, effect: [...command(19, Buffer.alloc(16))], table: [...command(20, Buffer.alloc(512))], capturedAt: new Date().toISOString() };
}
function restore(saved) {
  if (!Array.isArray(saved.effect) || saved.effect.length !== 16 || !Array.isArray(saved.table) || saved.table.length !== 512 || [...saved.effect, ...saved.table].some(v => !Number.isInteger(v) || v < 0 || v > 255)) throw new Error('Invalid recovery snapshot');
  command(36, Buffer.from(saved.table)); command(35, Buffer.from(saved.effect));
  if (!command(20, Buffer.alloc(512)).equals(Buffer.from(saved.table)) || !command(19, Buffer.alloc(16)).equals(Buffer.from(saved.effect))) throw new Error('恢复回读不一致');
  record({ name: 'restored', verified: true });
}
function selftest() {
  const data = solid([17, 33, 99], 106);
  if (data.length !== 512 || data[424] !== 106 || data[425] !== 17 || data[1] !== 0) throw new Error('Slot mapping test failed');
  const p = buildPacket(36, data.subarray(504), 504, true);
  if (p.length !== 65 || p[0] !== 0 || p[1] !== 0xaa || p[2] !== 36 || p[3] !== 8 || p.readUInt16LE(4) !== 504 || p[7] !== 1) throw new Error('Header test failed');
  if (mapping.KeyW !== 34 || mapping.Delete !== 106 || new Set(Object.values(mapping)).size !== 87 || Object.keys(mapping).length !== 87) throw new Error('Calibration test failed');
  let blocked = false; try { buildPacket(79, Buffer.alloc(1)); } catch { blocked = true; }
  if (!blocked) throw new Error('Command allowlist failed');
  record({ name: 'selftest', passed: true, cases: ['slot106', 'reportId prefix', 'last fragment', '87 calibrated keys', 'firmware-command blocked'] });
}
async function main() {
  const [action = 'probe', ...args] = process.argv.slice(2);
  if (!['selftest', 'probe', 'set', 'single', 'off', 'demo', 'restore'].includes(action)) throw new Error('用法: probe | set R G B | single Delete [R G B] | off | demo [seconds] | restore [snapshot.json] | selftest');
  if (action === 'selftest') { selftest(); return; }
  let color, slot;
  if (action === 'set') color = bytes(args);
  if (action === 'single') {
    slot = Object.hasOwn(mapping, args[0]) ? mapping[args[0]] : Number(args[0]);
    if (!args[0] || !Number.isInteger(slot) || slot < 0 || slot >= SLOTS) throw new Error('按键用校准名称如 KeyW/Delete，或槽位0..127');
    color = bytes(args.slice(1));
  }
  const seconds = action === 'demo' ? Number(args[0] || 4) : 0;
  if (action === 'demo' && (!Number.isFinite(seconds) || seconds < 1 || seconds > 30)) throw new Error('demo 秒数范围1..30');
  connect();
  const info = command(16, Buffer.alloc(56));
  if (info.readUInt16LE(4) !== 0x38a6 || info.readUInt16LE(6) !== 0x2908) throw new Error('接收器所连设备不是 F87S，已停止写入');
  record({ name: 'device-info', bodyVid: '0x38A6', bodyPid: '0x2908', battery: info[17], frameVersion: info[30], lightingVersion: info[31] });
  if (action === 'probe') {
    const effect = command(19, Buffer.alloc(16));
    record({ name: 'effect', mode: effect[0], brightness: effect[9], raw: [...effect] }); return;
  }
  if (action === 'restore') {
    restore(JSON.parse(fs.readFileSync(args[0] || snapshotFile))); return;
  }
  const saved = snapshot();
  const effect = customEffect(saved.effect);
  if (action === 'demo') {
    fs.writeFileSync(snapshotFile, JSON.stringify(saved, null, 2));
    record({ name: 'demo-start', seconds, restoreOnExit: true });
    const start = performance.now(); let frames = 0, sendMs = 0;
    try {
      const colors = [[180, 0, 0], [0, 0, 180], [0, 140, 0]];
      while (performance.now() - start < seconds * 1000 && !interrupted) {
        const t = performance.now(); writeFrame(solid(colors[frames % colors.length]), effect);
        sendMs += performance.now() - t; frames++;
        await delay(250);
      }
      record({ name: 'demo-complete', frames, elapsedMs: performance.now() - start, totalSendMs: sendMs, hostAckFramesPerSecond: frames * 1000 / sendMs, opticalFpsMeasured: false });
    } finally { restore(saved); }
  } else {
    const table = solid(action === 'off' ? [0, 0, 0] : color, action === 'single' ? slot : -1);
    // Record state before mutation so manual recovery remains available.
    const recovery = new URL('./f87s-wireless-before-set.json', import.meta.url);
    fs.writeFileSync(recovery, JSON.stringify(saved, null, 2));
    try {
      const start = performance.now(); writeFrame(table, effect);
      const actualTable = command(20, Buffer.alloc(512)); const actualEffect = command(19, Buffer.alloc(16));
      if (!actualTable.equals(table) || !actualEffect.equals(effect)) throw new Error('写入回读不一致');
      record({ name: 'color-written', action, color: action === 'off' ? [0, 0, 0] : color, slot: slot ?? null, storageVerified: true, elapsedIncludingReadbackMs: performance.now() - start, visualConfirmationRequired: true });
    } catch (error) { restore(saved); throw error; }
  }
}
try { await main(); } catch (error) { record({ name: 'error', message: error.message }); process.exitCode = 1; }
finally { if (device) device.close(); result.finishedAt = new Date().toISOString(); fs.writeFileSync(resultFile, JSON.stringify(result, null, 2)); }
