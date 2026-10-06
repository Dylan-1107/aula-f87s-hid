import argparse
import json
import sys
from pathlib import Path
from lupa.lua54 import LuaRuntime

parser = argparse.ArgumentParser()
parser.add_argument('--controller', choices=('wired', 'wireless'), default='wireless')
parser.add_argument('--report', type=Path)
parser.add_argument('--verbose', action='store_true')
args = parser.parse_args()
controller_name = 'controller.aula_f87s' + ('_wireless' if args.controller == 'wireless' else '')
ROOT = Path(__file__).resolve().parent.parent / controller_name
lua = LuaRuntime(encoding=None, unpack_returned_tuples=True)
lua.execute(b'''
device={packets={},queue={},colors='',mode=string.rep('x',16),ring=string.char(2)..string.rep('r',23),side=string.char(2)..string.rep('s',23),outputs={},suppress={},fail=false,prefix=false,asleep=false}
for i=0,127 do device.colors=device.colors..string.char(i,0,0,0) end
function device:write(p)
 assert(#p==65 and p:byte(1)==0 and p:byte(2)==170)
 self.packets[#self.packets+1]=p
 if self.fail then return 0 end
 local cmd,n,addr=p:byte(3),p:byte(4),p:byte(5)+p:byte(6)*256
 local data=p:sub(10,9+n)
 if cmd==19 then data=self.mode
 elseif cmd==20 then data=self.colors:sub(addr+1,addr+n)
 elseif cmd==27 then data=self.ring
 elseif cmd==29 then data=self.side
 elseif cmd==35 then self.mode=data
 elseif cmd==36 then self.colors=self.colors:sub(1,addr)..data..self.colors:sub(addr+n+1)
 elseif cmd==43 then self.ring=data
 elseif cmd==45 then self.side=data
 elseif cmd==16 then data=string.rep(string.char(0),4)..(self.ident or string.char(166,56,8,41))..string.rep(string.char(0),48)
 else error('Unsafe command') end
 -- A sleeping keyboard body still ACKs nothing, but the always-on receiver
 -- swallows the report and reports success: this asymmetry is exactly why
 -- the diff baseline can advance onto hardware that is not lit.
 if self.asleep then return #p end
 if not self.suppress[cmd] then
  local ack=string.char(85,cmd,n,addr%256,math.floor(addr/256),0,0,0)..data..string.rep(string.char(0),56-n)
  if self.prefix then ack=string.char(0)..ack end
  self.queue[#self.queue+1]=ack
 end
 return #p
end
function device:read(size,timeout) return table.remove(self.queue,1) or '' end
-- Waking a real keyboard re-initialises its LED engine, so the on-chip
-- colour table comes back blank regardless of what the host last wrote.
-- Exposed as a plain function because the Python side calls it with '.'.
function device.asleep_reset()
 local self=device
 self.colors=string.rep(string.char(0),512)
 self.mode=string.rep(string.char(0),16)
 self.ring=string.rep(string.char(0),24)
 self.side=string.rep(string.char(0),24)
end
function device:error(e) self.last_error=e end
for _,name in ipairs({'log','set_manufacturer','set_model','set_device_type','set_description','set_serial_id'}) do device[name]=function(self,v) self[name..'_value']=v end end
function device:serial_id() return 'receiver-test' end
function device:controller_port() return 'port-test' end
function device:add_output(o) self.outputs[o.id]=o end
function device:get_rgb_bytes(id) assert(id=='keys'); return self.rgb end
''')
p = lua.execute((ROOT / 'lib/protocol.lua').read_bytes())
l = lua.execute((ROOT / 'lib/layout.lua').read_bytes())
d = lua.globals().device
lua.globals().package.loaded[b'lib.protocol'] = p
lua.globals().package.loaded[b'lib.layout'] = l
entry = lua.execute((ROOT / 'main.lua').read_bytes())
checks = []
def check(name, condition):
    assert condition, name
    checks.append(name)
def reset():
    d.packets = lua.table()
def cmds():
    return [d.packets[i][2] for i in range(1, len(d.packets) + 1)]
def update(frame):
    keys, ring, side = l.split_frame(frame)
    return p.update(keys, l.HARDWARE_IDS, ring, side)

check(args.controller + ' device validation', entry.on_validate())
check('complete compact 19x6 matrix', len(l.MAP) == 114)
check('every logical sample appears exactly once', sorted(v for v in l.MAP.values() if v >= 0) == list(range(101)))
check('87 calibrated hardware IDs unique', len(set(l.HARDWARE_IDS.values())) == 87)
check('left strip unchanged and right strip adjacent to arrows', all(l.MAP[y * 19 + 1] == 89 + y and l.MAP[y * 19 + 19] == 95 + y for y in range(6)))
check('ring uses two stacked cells beside arrows', l.MAP[3 * 19 + 18] == 87 and l.MAP[4 * 19 + 18] == 88)
check('ring uses exactly two samples', sum(87 <= v <= 88 for v in l.MAP.values()) == 2)
check('arrow keys remain in original positions', l.MAP[4 * 19 + 17] == 75 and [l.MAP[5 * 19 + x + 1] for x in (15, 16, 17)] == [84, 85, 86])
check('invalid frame rejected', l.split_frame(bytes(261)) is None)
original = (d.colors, d.mode, d.ring, d.side)

# on_validate must not put anything on the bus: a sleeping 2.4G keyboard
# cannot answer cmd16, and rejecting the device there loses it for good.
check('nothing was sent before validation', len(d.packets) == 0)
check('validation accepts the receiver unconditionally', entry.on_validate())
check('validation issued no HID traffic', len(d.packets) == 0)

reset()
entry.on_init()
check('only one output registered', list(d.outputs.keys()) == [b'keys'])
check('single output size matches frame', d.outputs[b'keys'].size == 101)
check('an awake keyboard is identified, then snapshotted, during init',
      cmds() == [16] + [19] + [20] * 10 + [27, 29])
check('initialization does not modify hardware', original == (d.colors, d.mode, d.ring, d.side))
frame = bytearray(101 * 3)
ids = list(l.HARDWARE_IDS.values())
logical = ids.index(106)
frame[logical * 3:logical * 3 + 3] = bytes([0, 0, 160])
frame[87 * 3:89 * 3] = bytes([180, 0, 0]) * 2
frame[89 * 3:] = bytes([0, 0, 180]) * 12
d.rgb = bytes(frame)
reset()
entry.on_tick(0.008)
check('60Hz tick throttle', len(d.packets) == 0)
entry.on_tick(0.010)
check('first unified frame uses established commands', cmds() == [36] * 10 + [35, 43, 45])
check('Delete key calibration retained', d.colors[424:428] == bytes([106, 0, 0, 160]))
check('ring and strips derive colors from same frame', d.ring[1:4] == bytes([180, 0, 0]) and d.side[1:4] == bytes([0, 0, 180]))
reset()
entry.on_tick(0.020)
check('unchanged frame sends nothing', len(d.packets) == 0)
d.rgb = bytes([10, 20, 30]) * 101
reset()
entry.on_tick(0.020)
check('changed frame has eight keyboard chunks and two zone packets', cmds() == [36] * 8 + [43, 45])
check('keyboard differences keep lastFlag zero', all(d.packets[i][7] == 0 for i in range(1, 9)))
check('each keyboard chunk carries 14 complete key slots', all(d.packets[i][3] == 56 and d.packets[i][4] + d.packets[i][5] * 256 == (i - 1) * 56 for i in range(1, 9)))
new_frame = bytearray(d.rgb)
new_frame[logical * 3] = 11
d.rgb = bytes(new_frame)
reset()
entry.on_tick(0.020)
check('one changed key writes one chunk', cmds() == [36])
new_frame[87 * 3:89 * 3] = bytes([40, 50, 60]) * 2
d.rgb = bytes(new_frame)
reset()
entry.on_tick(0.020)
check('ring-only change writes only ring', cmds() == [43] and d.ring[1:4] == bytes([40, 50, 60]))
new_frame[89 * 3:95 * 3] = bytes([100, 0, 0]) * 6
new_frame[95 * 3:] = bytes([0, 0, 100]) * 6
d.rgb = bytes(new_frame)
reset()
entry.on_tick(0.020)
check('side-only change writes only shared hardware zone', cmds() == [45])
check('left/right samples averaged explicitly', d.side[1:4] == bytes([50, 0, 50]))
d.fail = True
d.rgb = bytes([60, 80, 100]) * 101
reset()
entry.on_tick(0.020)
check('write failure detected', len(d.packets) == 1 and d.last_error is not None)
d.fail = False
d.prefix = True
reset()
entry.on_tick(0.020)
check('failure retry backed off', len(d.packets) == 0)
entry.on_tick(2.1)
# 2.1 s also crosses PROBE_INTERVAL, so the frame is preceded by one heartbeat.
check('failed frame fully resynchronized', cmds() == [16] + [36] * 10 + [35, 43, 45])
reset()
entry.on_shutdown()
check('shutdown restores all saved state', original == (d.colors, d.mode, d.ring, d.side))
check('shutdown uses restore commands only', cmds() == [36] * 10 + [35, 43, 45])
reset()
check('shutdown idempotent', p.shutdown() and len(d.packets) == 0)
d.suppress[20] = True
reset()
entry.on_init()
check('missing snapshot blocks updates', not update(bytes(frame)))
d.suppress[20] = False
d.rgb = bytes(frame)
reset()
entry.on_tick(2.1)
check('initialization retried after wakeup',
      cmds() == [16] + [19] + [20] * 10 + [27, 29] + [36] * 10 + [35, 43, 45])
entry.on_shutdown()
check('final restore complete', original == (d.colors, d.mode, d.ring, d.side))
manifest = json.loads((ROOT / 'manifest.json').read_text(encoding='utf-8'))
expected_match = {'vid': '0x0C45', 'pid': '0xFEF9', 'interface_number': 3} if args.controller == 'wireless' else {'vid': '0x38A6', 'pid': '0x2908', 'interface_number': 3}
check(args.controller + ' match unchanged', manifest['match']['rules'] == [expected_match])
# Exercise the actual entrypoint with a mocked protocol to isolate tick scheduling.
lua.execute(b'''
local count, init_ok, update_ok = 0, true, true
local verdict, resyncs, probes = 'f87s', 0, 0
local awake = true
local mock = {
 identify = function() probes = probes + 1; return verdict end,
 resync = function() resyncs = resyncs + 1 end,
 ping = function() return awake end,
 initialize = function() return init_ok end,
 update = function() count = count + 1; return update_ok end,
 shutdown = function() return true end
}
package.loaded['lib.protocol'] = mock
function tick_test_reset() count = 0 end
function tick_test_count() return count end
function tick_test_verdict(v) verdict = v end
function tick_test_awake(v) awake = v end
function tick_test_probes() return probes end
function tick_test_resyncs() return resyncs end
function tick_test_init(ok) init_ok = ok end
function tick_test_update(ok) update_ok = ok end
''')
scheduler = lua.execute((ROOT / 'main.lua').read_bytes())
schedules = []
for dt in (0.008, 0.016, 0.0165, 1 / 60, 0.020, 0.033):
    scheduler.on_init()
    lua.globals().tick_test_reset()
    for _ in range(1000):
        scheduler.on_tick(dt)
    count = lua.globals().tick_test_count()
    expected = min(1000, 1000 * dt * 60)
    check(f'{dt}s ticks preserve 60Hz budget without bursts', abs(count - expected) <= 1)
    elapsed = 0.0
    old_count = 0
    for _ in range(1000):
        elapsed += dt
        if elapsed >= 1 / 60:
            old_count += 1
            elapsed = 0.0
    schedules.append({'tickSeconds': dt, 'callbacks': 1000, 'beforeFrames': old_count,
                      'afterFrames': count, 'beforeFps': old_count / (1000 * dt),
                      'afterFps': count / (1000 * dt)})
scheduler.on_init()
lua.globals().tick_test_reset()
scheduler.on_tick(5.005)
check('stall emits at most one frame', lua.globals().tick_test_count() == 1)
scheduler.on_tick(0)
check('stall discards backlog', lua.globals().tick_test_count() == 1)
scheduler.on_init()
lua.globals().tick_test_reset()
lua.globals().tick_test_update(False)
scheduler.on_tick(0.033)
lua.globals().tick_test_update(True)
scheduler.on_tick(1.99)
check('failure starts a fresh two-second backoff', lua.globals().tick_test_count() == 1)
scheduler.on_tick(0.011)
check('failure recovery resumes after backoff', lua.globals().tick_test_count() == 2)
scheduler.on_tick(0)
check('recovery drops backoff time remainder', lua.globals().tick_test_count() == 2)
lua.globals().tick_test_init(False)
scheduler.on_init()
lua.globals().tick_test_reset()
scheduler.on_tick(0.033)
lua.globals().tick_test_init(True)
scheduler.on_tick(1.99)
check('initialization failure backs off', lua.globals().tick_test_count() == 0)
scheduler.on_tick(0.011)
check('initialization failure recovers', lua.globals().tick_test_count() == 1)
# --- Sleeping-keyboard behaviour at the scheduler level. ---
# Uses the real protocol module with a suppressed cmd16 ACK, so the only thing
# under test is main.lua's throttling, not the mock plumbing.
lua.globals().package.loaded[b'lib.protocol'] = p
drowsy = lua.execute((ROOT / 'main.lua').read_bytes())
d.suppress[16] = True
d.ident = None
d.rgb = bytes(101 * 3)
drowsy.on_init()
reset()
probes_before = cmds()
for _ in range(62):
    drowsy.on_tick(0.016)
check('a sleeping keyboard emits no lighting traffic', set(cmds()) <= {16})
reset()
drowsy.on_tick(1.0)
check('identify stays throttled below the interval', len(d.packets) == 0)
drowsy.on_tick(1.0)
check('identify retries once the interval elapses', set(cmds()) == {16})
reset()
drowsy.on_tick(1.0)
check('identify does not run twice inside one interval', len(d.packets) == 0)
d.suppress[16] = False
reset()
drowsy.on_tick(2.0)
# Same tick: identify() confirms the body, then the heartbeat probes it again.
check('waking the keyboard needs no rescan',
      cmds() == [16, 16] + [19] + [20] * 10 + [27, 29] + [36] * 10 + [35, 43, 45])
reset()
drowsy.on_tick(0.016)
check('the identified device then follows the normal frame budget', len(d.packets) == 0)
drowsy.on_shutdown()
check('the woken device restores the original lighting', original == (d.colors, d.mode, d.ring, d.side))

# --- End-to-end regression: the keyboard is asleep when SKYdimo scans. ---
# A fresh main.lua chunk so the module-level state starts clean.
d.ident = None
d.suppress[16] = True
d.rgb = bytes(101 * 3)
reset()
asleep = lua.execute((ROOT / 'main.lua').read_bytes())
check('a sleeping receiver is still claimed', asleep.on_validate())
check('claiming a sleeping receiver stays off the bus', len(d.packets) == 0)
reset()
asleep.on_init()
check('a sleeping keyboard still registers its output', list(d.outputs.keys()) == [b'keys'])
check('a sleeping keyboard is probed, never snapshotted', cmds() == [16, 16])

# A receiver with some other keyboard behind it must be dropped, not driven.
d.suppress[16] = False
d.ident = bytes([0x11, 0x22, 0x33, 0x44])
wrong = lua.execute((ROOT / 'main.lua').read_bytes())
check('a non-F87S keyboard passes VID-only validation', wrong.on_validate())
reset()
wrong.on_init()
check('a non-F87S keyboard is never snapshotted', set(cmds()) <= {16})
reset()
wrong.on_tick(1.0)
check('a non-F87S keyboard is not re-probed inside the interval', len(d.packets) == 0)
wrong.on_tick(1.0)
check('a non-F87S keyboard is rejected on the first retry',
      set(cmds()) == {16} and d.last_error is not None)
wrong.on_tick(10.0)
check('a rejected keyboard is not retried forever', len(d.packets) == 1)
d.ident = None

# --- Regression: waking a sleeping keyboard must restore the running preset. ---
# The diff baseline lives in this process; the colour table lives on the keyboard.
# The 2.4G receiver is an always-on HID endpoint, so while the body sleeps every
# write still "succeeds" and the baseline advances onto hardware that is not lit.
# On wake the host must notice the body is answering again and push a full table,
# otherwise a static preset is lost for the rest of the session.
d.ident = None
d.rgb = bytes([9, 200, 90]) * 101
sleeper = lua.execute((ROOT / 'main.lua').read_bytes())
sleeper.on_validate()
# Drop stale ACKs left by the previous device instance on the shared receiver.
d.queue = lua.table()
reset()
sleeper.on_init()
check('a live keyboard initializes normally',
      cmds() == [16] + [19] + [20] * 10 + [27, 29])
reset()
sleeper.on_tick(0.020)
check('the first frame lands on the hardware', cmds() == [36] * 10 + [35, 43, 45])
check('the preset is lit', d.colors[424:428] == bytes([106, 9, 200, 90]))
# The body now sleeps. The receiver keeps accepting reports, so any further
# frame would be swallowed while still advancing the diff baseline.
d.asleep = True
reset()
sleeper.on_tick(2.0)
check('the heartbeat notices the body stopped answering', cmds() == [16])
check('no lighting frame is sent while the body sleeps',
      not (set(cmds()) & {35, 36, 43, 45}))
check('the sleeping body returns no ACK at all', len(d.queue) == 0)
# Wipe the on-chip table the way a real LED engine re-init does.
d.asleep_reset()
check('the keyboard really did forget the frame', d.colors == bytes(512))
# A changed preset during sleep must not be written onto the blank hardware.
d.rgb = bytes([1, 2, 3]) * 101
reset()
for _ in range(500):
    sleeper.on_tick(0.020)
check('a long sleep emits heartbeats but never lighting frames',
      cmds().count(16) >= 4 and set(cmds()) == {16})
check('the sleeping body still has not applied anything', d.colors == bytes(512))
# The user presses a key: the body wakes and starts answering again.
d.asleep = False
d.rgb = bytes([9, 200, 90]) * 101
reset()
sleeper.on_tick(0.020)
check('the heartbeat is still throttled right after the last probe', len(d.packets) == 0)
sleeper.on_tick(2.0)
# The same callback also carries a lighting frame: waking relights immediately.
check('the heartbeat detects the body is back', cmds() and cmds()[0] == 16)
check('waking the body republishes the whole table, not just a delta',
      cmds() == [16] + [36] * 10 + [35, 43, 45])
check('the preset is actually back on the keyboard',
      d.colors[424:428] == bytes([106, 9, 200, 90]))
check('the effect mode is re-armed on wake',
      d.mode[0] == 20 and d.mode[9] == 5 and d.mode[14:16] == bytes([0xAA, 0x55]))
reset()
sleeper.on_tick(0.020)
check('a settled frame goes back to sending nothing', len(d.packets) == 0)
sleeper.on_shutdown()
check('the woken session still restores the original lighting',
      (d.colors, d.mode, d.ring, d.side) == original)
# A second sleep/wake cycle must not drift the baseline either.
sleeper2 = lua.execute((ROOT / 'main.lua').read_bytes())
sleeper2.on_validate()
d.queue = lua.table()
d.asleep = False
reset()
sleeper2.on_init()
sleeper2.on_tick(0.020)
check('the second session lights up normally', set(cmds()) >= {35, 36})
d.asleep = True
d.asleep_reset()
reset()
for _ in range(500):
    sleeper2.on_tick(0.020)
check('a long sleep emits heartbeats but no lighting frames (second cycle)',
      cmds().count(16) >= 4 and set(cmds()) == {16})
d.asleep = False
reset()
sleeper2.on_tick(0.020)
sleeper2.on_tick(2.0)
check('the second wake also republishes the full table',
      cmds() == [16] + [36] * 10 + [35, 43, 45])
check('the preset survives repeated sleep cycles',
      d.colors[424:428] == bytes([106, 9, 200, 90]))
sleeper2.on_shutdown()
check('the second session restores the original lighting on exit',
      (d.colors, d.mode, d.ring, d.side) == original)
result = {'passed': True, 'controller': args.controller, 'schedules': schedules, 'checkCount': len(checks), 'checks': checks, 'matrix': {'width': 19, 'height': 6, 'samples': 101, 'keys': 87, 'ringSamples': 2, 'sideSamples': 12}, 'scope': 'Lua54 mock only; SKYdimo rendering and physical effects require live verification', 'realFpsMeasured': False, 'map': [l.MAP[i] for i in range(1, len(l.MAP) + 1)]}
text = json.dumps(result, indent=2, ensure_ascii=False)
print(text)
import tempfile, os
out = args.report or Path(tempfile.gettempdir()) / ('f87s-' + args.controller + '-plugin-test.json')
out.write_text(text, encoding='utf-8')
print('report:', out)
