// aula-f87s-light.mjs — 狼蛛 AULA F87S 灯效控制工具（实测可用）
// 用法：
//   node aula-f87s-light.mjs set 255 0 0 [brightness]   全键盘设色
//   node aula-f87s-light.mjs single <ledId> R G B        单槽设色(0..127)
//   node aula-f87s-light.mjs read                         读物理输出
//   node aula-f87s-light.mjs rainbow                      彩虹渐变(87键)
//   node aula-f87s-light.mjs off                          熄灭
import HID from 'node-hid';

const B = 64, H = 8, W = B - H;
const CMD_SET_LED_EFFECT = 35, CMD_SET_CUSTOM_LED_DATA = 36, CMD_GET_ALL_LIGHTS_RGB = 51;
const CUSTOM_MODE = 20;   // custom 模式（实测确认）
const DEFAULT_BRIGHT = 5; // 官方亮度量程 0-5，5=最亮；255 会溢出全黑

function buildReport(cmd, chunkSize, addr, data, isLast) {
  const buf = Buffer.alloc(B, 0);
  buf[0] = 0xAA; buf[1] = cmd; buf[2] = chunkSize & 0xFF;
  buf[3] = addr & 0xFF; buf[4] = (addr >> 8) & 0xFF; buf[6] = isLast ? 1 : 0;
  if (data) data.copy(buf, 8);
  return buf;
}
function writeReport(dev, r) { const o = Buffer.alloc(r.length + 1, 0); r.copy(o, 1); return dev.write(o); }
const sleep = ms => new Promise(r => setTimeout(r, ms));
const toBuf = r => r == null ? null : (Buffer.isBuffer(r) ? r : Buffer.from(r));

async function sendCommand(dev, cmd, data, contentSize) {
  const Q = Math.max(1, Math.ceil(contentSize / W));
  const resps = [];
  for (let M = 0; M < Q; M++) {
    const addr = M * W, rem = contentSize - M * W, chunk = (M === Q - 1) ? rem : W, isLast = (M === Q - 1);
    let d = null; if (data) { const off = M * W; if (off < data.length) d = data.subarray(off, Math.min(off + W, data.length)); }
    writeReport(dev, buildReport(cmd, chunk, addr, d, isLast));
    await sleep(12); resps.push(dev.readTimeout(200));
  }
  return resps;
}
function concat(resps, n) { const out = Buffer.alloc(n, 0); let off = 0; for (const r0 of resps) { const r = toBuf(r0); if (!r) continue; r.subarray(8).copy(out, off); off += r.length - 8; if (off >= n) break; } return out; }

function connect() {
  const d = HID.devices().find(x => x.vendorId === 0x38A6 && x.productId === 0x2908 && x.interface === 3);
  if (!d) { console.error('未找到 F87S (0x38A6:0x2908) 主配置口 MI_03，请确认有线连接'); process.exit(1); }
  return new HID.HID(d.path);
}

async function setEffect(dev, mode, brightness) {
  const t = Buffer.alloc(16, 0);
  t[0] = mode; t[1] = 255; t[2] = 255; t[3] = 255; t[4] = 255;
  t[8] = 0; t[9] = brightness; t[10] = 3; t[11] = 0; t[12] = 0; t[14] = 0xAA; t[15] = 0x55;
  await sendCommand(dev, CMD_SET_LED_EFFECT, t, 16);
}

async function writeColors(dev, colors, brightness) {
  const data = Buffer.alloc(512, 0);
  for (let i = 0; i < 128; i++) { data[i*4] = i; data[i*4+1] = colors[i][0]; data[i*4+2] = colors[i][1]; data[i*4+3] = colors[i][2]; }
  await sendCommand(dev, CMD_SET_CUSTOM_LED_DATA, data, 512);
  await setEffect(dev, CUSTOM_MODE, brightness);
}

async function readPhysical(dev) {
  const q = Buffer.alloc(512, 0); for (let i = 0; i < 128; i++) q[i*4] = i;
  const resps = await sendCommand(dev, CMD_GET_ALL_LIGHTS_RGB, q, 512);
  return concat(resps, 512);
}

function rainbow() {
  const cols = [];
  for (let i = 0; i < 128; i++) {
    const h = i / 87 * 360;
    cols.push(hsv2rgb(h, 1, 1));
  }
  return cols;
}
function hsv2rgb(h, s, v) {
  const c = v * s, x = c * (1 - Math.abs((h / 60) % 2 - 1)), m = v - c;
  let r = 0, g = 0, b = 0;
  if (h < 60) { r = c; g = x; } else if (h < 120) { r = x; g = c; }
  else if (h < 180) { g = c; b = x; } else if (h < 240) { g = x; b = c; }
  else if (h < 300) { r = x; b = c; } else { r = c; b = x; }
  return [Math.round((r + m) * 255), Math.round((g + m) * 255), Math.round((b + m) * 255)];
}

async function main() {
  const [cmd, a, b2, c2, d2] = process.argv.slice(2);
  const dev = connect();
  try {
    if (cmd === 'set') {
      const r = +a, g = +b2, bl = +c2, bright = d2 ? +d2 : DEFAULT_BRIGHT;
      await writeColors(dev, Array(128).fill([r, g, bl]), bright);
      console.log('已设置全键盘 RGB(' + r + ',' + g + ',' + bl + ') brightness=' + bright + ' mode=20');
    } else if (cmd === 'single') {
      const ledId = +a, r = +b2, g = +c2, bl = +d2;
      const cols = Array(128).fill([0, 0, 0]); cols[ledId] = [r, g, bl];
      await writeColors(dev, cols, DEFAULT_BRIGHT);
      console.log('已设置 ledId=' + ledId + ' 为 RGB(' + r + ',' + g + ',' + bl + ')');
    } else if (cmd === 'rainbow') {
      await writeColors(dev, rainbow(), DEFAULT_BRIGHT);
      console.log('已设置 87 键彩虹渐变');
    } else if (cmd === 'off') {
      await writeColors(dev, Array(128).fill([0, 0, 0]), DEFAULT_BRIGHT);
      console.log('已熄灭');
    } else if (cmd === 'read') {
      const ph = await readPhysical(dev);
      let nz = 0; for (let i = 0; i < 128; i++) if (ph[i*4+1] || ph[i*4+2] || ph[i*4+3]) nz++;
      console.log('物理输出非黑槽位 ' + nz + '/128');
      console.log('槽0 RGB=[' + ph[1] + ',' + ph[2] + ',' + ph[3] + ']');
    } else {
      console.log('用法: node aula-f87s-light.mjs <set R G B [bright] | single ledId R G B | rainbow | off | read>');
    }
  } finally { dev.close(); }
}
main().catch(e => { console.error(e); process.exit(1); });
