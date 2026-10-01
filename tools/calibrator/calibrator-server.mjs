import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import HID from "node-hid";

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const HTML_FILE = path.join(ROOT, "calibrator.html");
const CALIBRATION_FILE = path.join(ROOT, "calibration.json");
const PLUGIN_LAYOUT = process.env.F87S_PLUGIN_LAYOUT || path.join(ROOT, "layout.lua");
const PORT = Number(process.env.F87S_CALIBRATOR_PORT || 8765);
const VID = Number(process.env.F87S_VID || 0x38A6);
const PID = Number(process.env.F87S_PID || 0x2908);
const INTERFACE = Number(process.env.F87S_INTERFACE || 3);
const REPORT_SIZE = 64;
const PAYLOAD_SIZE = 56;
const LED_SLOTS = 128;
const CUSTOM_MODE = 20;
const BRIGHTNESS = 5;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function key(code, label, row, col, span = 1) {
  return { code, label, row, col, span };
}

const KEY_DEFS = [
  key("Escape", "Esc", 0, 0),
  key("F1", "F1", 0, 2), key("F2", "F2", 0, 3), key("F3", "F3", 0, 4), key("F4", "F4", 0, 5),
  key("F5", "F5", 0, 7), key("F6", "F6", 0, 8), key("F7", "F7", 0, 9), key("F8", "F8", 0, 10),
  key("F9", "F9", 0, 12), key("F10", "F10", 0, 13), key("F11", "F11", 0, 14), key("F12", "F12", 0, 15),
  key("PrintScreen", "Print", 0, 16), key("ScrollLock", "Scroll", 0, 17), key("Pause", "Pause", 0, 18),
  key("Backquote", "`~", 1, 0),
  key("Digit1", "!1", 1, 1), key("Digit2", "@2", 1, 2), key("Digit3", "#3", 1, 3), key("Digit4", "$4", 1, 4),
  key("Digit5", "%5", 1, 5), key("Digit6", "^6", 1, 6), key("Digit7", "&7", 1, 7), key("Digit8", "*8", 1, 8),
  key("Digit9", "(9", 1, 9), key("Digit0", ")0", 1, 10), key("Minus", "-_", 1, 11), key("Equal", "+=", 1, 12),
  key("Backspace", "Backspace", 1, 14, 2), key("Insert", "Insert", 1, 16), key("Home", "Home", 1, 17), key("PageUp", "PgUp", 1, 18),
  key("Tab", "Tab", 2, 0),
  key("KeyQ", "Q", 2, 2), key("KeyW", "W", 2, 3), key("KeyE", "E", 2, 4), key("KeyR", "R", 2, 5),
  key("KeyT", "T", 2, 6), key("KeyY", "Y", 2, 7), key("KeyU", "U", 2, 8), key("KeyI", "I", 2, 9),
  key("KeyO", "O", 2, 10), key("KeyP", "P", 2, 11), key("BracketLeft", "[{", 2, 12), key("BracketRight", "]}", 2, 13),
  key("Backslash", "\\|", 2, 14), key("Delete", "Del", 2, 16), key("End", "End", 2, 17), key("PageDown", "PgDn", 2, 18),
  key("CapsLock", "CapsLock", 3, 0, 2),
  key("KeyA", "A", 3, 2), key("KeyS", "S", 3, 3), key("KeyD", "D", 3, 4), key("KeyF", "F", 3, 5),
  key("KeyG", "G", 3, 6), key("KeyH", "H", 3, 7), key("KeyJ", "J", 3, 8), key("KeyK", "K", 3, 9),
  key("KeyL", "L", 3, 10), key("Semicolon", ";:", 3, 11), key("Quote", "'\"", 3, 12), key("Enter", "Enter", 3, 14),
  key("ShiftLeft", "L-Shift", 4, 0, 2),
  key("KeyZ", "Z", 4, 2), key("KeyX", "X", 4, 3), key("KeyC", "C", 4, 4), key("KeyV", "V", 4, 5),
  key("KeyB", "B", 4, 6), key("KeyN", "N", 4, 7), key("KeyM", "M", 4, 8), key("Comma", "<,", 4, 9),
  key("Period", ">.", 4, 10), key("Slash", "?/", 4, 11), key("ShiftRight", "R-Shift", 4, 13, 2), key("ArrowUp", "↑", 4, 18),
  key("ControlLeft", "L-Ctrl", 5, 0), key("MetaLeft", "L-Win/CMD", 5, 1), key("AltLeft", "L-Alt/CPT", 5, 2),
  key("Space", "Space", 5, 5, 6), key("AltRight", "R-Alt/CMD", 5, 9), key("Fn", "Fn", 5, 11), key("ContextMenu", "APP", 5, 12),
  key("ControlRight", "R-Ctrl/CPT", 5, 13, 2), key("ArrowLeft", "←", 5, 15), key("ArrowDown", "↓", 5, 16), key("ArrowRight", "→", 5, 17),
];

const KEY_BY_CODE = new Map(KEY_DEFS.map((item) => [item.code, item]));

let device = null;
let deviceInfo = null;
let modeReady = false;
let queue = Promise.resolve();
let currentLedId = null;
let mapping = loadCalibration().mapping;

function loadCalibration() {
  try {
    const parsed = JSON.parse(fs.readFileSync(CALIBRATION_FILE, "utf8"));
    return parsed && parsed.mapping ? parsed : { mapping: {} };
  } catch {
    return { mapping: {} };
  }
}

function saveCalibration() {
  const payload = {
    version: 1,
    device: "AULA F87S",
    vid: "0x38A6",
    pid: "0x2908",
    interface: 3,
    updatedAt: new Date().toISOString(),
    mapping,
  };
  fs.writeFileSync(CALIBRATION_FILE, JSON.stringify(payload, null, 2), "utf8");
}

function findDevice() {
  const all = HID.devices();
  return all.find((item) => item.vendorId === VID && item.productId === PID && item.interface === INTERFACE) || null;
}

function buildReport(cmd, chunkSize, address, data, isLast) {
  const report = Buffer.alloc(REPORT_SIZE, 0);
  report[0] = 0xAA;
  report[1] = cmd;
  report[2] = chunkSize & 0xFF;
  report[3] = address & 0xFF;
  report[4] = (address >> 8) & 0xFF;
  report[6] = isLast ? 1 : 0;
  if (data?.length) data.copy(report, 8);
  return report;
}

function writeReport(report) {
  const output = Buffer.alloc(report.length + 1, 0);
  report.copy(output, 1);
  device.write(output);
}

async function sendCommand(cmd, data, contentSize, readResponses = false) {
  const packets = Math.max(1, Math.ceil(contentSize / PAYLOAD_SIZE));
  for (let index = 0; index < packets; index += 1) {
    const address = index * PAYLOAD_SIZE;
    const chunkSize = Math.min(PAYLOAD_SIZE, contentSize - address);
    const chunk = data ? data.subarray(address, address + chunkSize) : null;
    writeReport(buildReport(cmd, chunkSize, address, chunk, index === packets - 1));
    if (readResponses) {
      try {
        device.readTimeout(120);
      } catch {
        // The F87S firmware may omit a response for a packet.
      }
    }
  }
}

function modeData() {
  const data = Buffer.alloc(16, 0);
  data[0] = CUSTOM_MODE;
  data[1] = 255;
  data[2] = 255;
  data[3] = 255;
  data[4] = 255;
  data[8] = 0;
  data[9] = BRIGHTNESS;
  data[10] = 3;
  data[14] = 0xAA;
  data[15] = 0x55;
  return data;
}

function colorsToData(colors) {
  const data = Buffer.alloc(LED_SLOTS * 4, 0);
  for (let id = 0; id < LED_SLOTS; id += 1) {
    const rgb = colors[id] || [0, 0, 0];
    const offset = id * 4;
    data[offset] = id;
    data[offset + 1] = rgb[0] || 0;
    data[offset + 2] = rgb[1] || 0;
    data[offset + 3] = rgb[2] || 0;
  }
  return data;
}

function allBlack() {
  return Array.from({ length: LED_SLOTS }, () => [0, 0, 0]);
}

async function ensureDevice() {
  if (device && modeReady) return;
  deviceInfo = findDevice();
  if (!deviceInfo) {
    throw new Error("没有找到 F87S 的 MI_03 主配置口。请确认有线连接，并暂时退出 SKYdimo。");
  }
  try {
    device = new HID.HID(deviceInfo.path);
    await sendCommand(35, modeData(), 16, true);
    await sendCommand(36, colorsToData(allBlack()), 512, false);
    modeReady = true;
  } catch (error) {
    try { device?.close(); } catch {}
    device = null;
    modeReady = false;
    throw new Error(`打开 F87S 失败：${error.message}`);
  }
}

function closeDevice() {
  if (!device) return;
  try { device.close(); } catch {}
  device = null;
  modeReady = false;
}

function enqueue(task) {
  const result = queue.then(task, task);
  queue = result.catch(() => undefined);
  return result;
}

function validateLedId(value) {
  const id = Number(value);
  if (!Number.isInteger(id) || id < 0 || id >= LED_SLOTS) throw new Error("硬件槽位必须是 0 到 127 的整数");
  return id;
}

function validateCode(value) {
  if (!KEY_BY_CODE.has(value)) throw new Error(`不支持的按键代码：${value}`);
  return value;
}

function statusPayload() {
  const mappedCodes = Object.keys(mapping);
  const used = new Map();
  const duplicates = [];
  for (const code of mappedCodes) {
    const id = mapping[code];
    if (used.has(id)) duplicates.push({ ledId: id, codes: [used.get(id), code] });
    else used.set(id, code);
  }
  return {
    ok: true,
    connected: Boolean(device && modeReady),
    device: deviceInfo ? { product: deviceInfo.product, interface: deviceInfo.interface, path: deviceInfo.path } : null,
    currentLedId,
    mappedCount: mappedCodes.length,
    totalKeys: KEY_DEFS.length,
    duplicates,
    mapping,
    keys: KEY_DEFS,
    file: CALIBRATION_FILE,
  };
}

function generatedLayout() {
  const missing = KEY_DEFS.filter((item) => !Number.isInteger(mapping[item.code])).map((item) => item.label);
  if (missing.length) throw new Error(`还有 ${missing.length} 个按键未校准：${missing.join(", ")}`);
  const seen = new Map();
  for (const item of KEY_DEFS) {
    const id = mapping[item.code];
    if (seen.has(id)) throw new Error(`硬件槽位 ${id} 被 ${seen.get(id)} 和 ${item.label} 重复使用`);
    seen.set(id, item.label);
  }
  const width = 20;
  const height = 6;
  const indexByCode = new Map(KEY_DEFS.map((item, index) => [item.code, index]));
  const cells = Array.from({ length: width * height }, () => -1);
  for (const item of KEY_DEFS) {
    const index = indexByCode.get(item.code);
    for (let offset = 0; offset < item.span; offset += 1) cells[item.row * width + item.col + offset] = index;
  }
  const hardwareIds = KEY_DEFS.map((item) => mapping[item.code]);
  return `--- Generated by F87S calibrator. Do not edit while calibration is in progress.\nlocal layout = {}\nlayout.WIDTH = ${width}\nlayout.HEIGHT = ${height}\nlayout.LED_COUNT = ${KEY_DEFS.length}\nlayout.MAP = {\n  ${cells.slice(0, width).join(", ")},\n  ${cells.slice(width, width * 2).join(", ")},\n  ${cells.slice(width * 2, width * 3).join(", ")},\n  ${cells.slice(width * 3, width * 4).join(", ")},\n  ${cells.slice(width * 4, width * 5).join(", ")},\n  ${cells.slice(width * 5, width * 6).join(", ")},\n}\nlayout.HARDWARE_IDS = {\n  ${hardwareIds.join(", ")}\n}\nreturn layout\n`;
}

function jsonResponse(response, status, payload) {
  const body = JSON.stringify(payload);
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
  });
  response.end(body);
}

async function readBody(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  if (!chunks.length) return {};
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

async function handleApi(request, response, pathname) {
  if (request.method === "OPTIONS") return jsonResponse(response, 204, {});
  if (request.method === "GET" && pathname === "/api/status") return jsonResponse(response, 200, statusPayload());

  let body = {};
  if (request.method === "POST") body = await readBody(request);

  if (request.method === "POST" && pathname === "/api/connect") {
    await enqueue(async () => { await ensureDevice(); });
    return jsonResponse(response, 200, statusPayload());
  }

  if (request.method === "POST" && pathname === "/api/light") {
    const id = validateLedId(body.ledId);
    const color = Array.isArray(body.color) ? body.color.map((x) => Math.max(0, Math.min(255, Number(x) || 0))) : [255, 40, 40];
    await enqueue(async () => {
      await ensureDevice();
      const colors = allBlack();
      colors[id] = color;
      currentLedId = id;
      await sendCommand(36, colorsToData(colors), 512, false);
    });
    return jsonResponse(response, 200, statusPayload());
  }

  if (request.method === "POST" && pathname === "/api/off") {
    await enqueue(async () => {
      await ensureDevice();
      currentLedId = null;
      await sendCommand(36, colorsToData(allBlack()), 512, false);
    });
    return jsonResponse(response, 200, statusPayload());
  }

  if (request.method === "POST" && pathname === "/api/assign") {
    const id = validateLedId(body.ledId);
    const code = validateCode(body.code);
    for (const [oldCode, oldId] of Object.entries(mapping)) if (oldCode !== code && oldId === id) delete mapping[oldCode];
    mapping[code] = id;
    saveCalibration();
    return jsonResponse(response, 200, statusPayload());
  }

  if (request.method === "POST" && pathname === "/api/unassign") {
    const code = validateCode(body.code);
    delete mapping[code];
    saveCalibration();
    return jsonResponse(response, 200, statusPayload());
  }

  if (request.method === "POST" && pathname === "/api/reset") {
    mapping = {};
    saveCalibration();
    return jsonResponse(response, 200, statusPayload());
  }

  if (request.method === "POST" && pathname === "/api/apply") {
    const source = generatedLayout();
    if (fs.existsSync(PLUGIN_LAYOUT)) {
      fs.copyFileSync(PLUGIN_LAYOUT, `${PLUGIN_LAYOUT}.before-calibration.bak`);
    }
    fs.writeFileSync(PLUGIN_LAYOUT, source, "utf8");
    saveCalibration();
    return jsonResponse(response, 200, { ...statusPayload(), applied: true, backup: `${PLUGIN_LAYOUT}.before-calibration.bak` });
  }

  if (request.method === "POST" && pathname === "/api/close") {
    await enqueue(async () => {
      if (device && modeReady) await sendCommand(36, colorsToData(allBlack()), 512, false);
      closeDevice();
      currentLedId = null;
    });
    return jsonResponse(response, 200, statusPayload());
  }

  return jsonResponse(response, 404, { ok: false, error: "未知接口" });
}

const server = http.createServer(async (request, response) => {
  try {
    const parsed = new URL(request.url, `http://${request.headers.host || "127.0.0.1"}`);
    if (parsed.pathname.startsWith("/api/")) return await handleApi(request, response, parsed.pathname);
    if (request.method !== "GET") return jsonResponse(response, 405, { ok: false, error: "仅支持 GET" });
    const file = parsed.pathname === "/" ? HTML_FILE : path.join(ROOT, parsed.pathname.replace(/^\/+/, ""));
    if (!file.startsWith(ROOT) || !fs.existsSync(file)) return jsonResponse(response, 404, { ok: false, error: "文件不存在" });
    const ext = path.extname(file).toLowerCase();
    const type = ext === ".html" ? "text/html; charset=utf-8" : "text/plain; charset=utf-8";
    response.writeHead(200, { "Content-Type": type, "Cache-Control": "no-store" });
    fs.createReadStream(file).pipe(response);
  } catch (error) {
    jsonResponse(response, 500, { ok: false, error: error.message });
  }
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`F87S calibrator: http://127.0.0.1:${PORT}`);
  console.log(`Calibration file: ${CALIBRATION_FILE}`);
});

process.on("SIGINT", () => { closeDevice(); server.close(() => process.exit(0)); });
process.on("SIGTERM", () => { closeDevice(); server.close(() => process.exit(0)); });
