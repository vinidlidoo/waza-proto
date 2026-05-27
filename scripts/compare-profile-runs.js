#!/usr/bin/env node
// Aggregate paired profiler runs into a side-by-side markdown comparison
// report matching the §3a publisher / §3b viewer tables in
// plans/features/glasses-stream-jitter-analysis.md, plus a §3c smoothing-
// buffer table when any run had the buffer active.
//
// Runs are auto-grouped by `run_id`, paired iOS+viewer events go together,
// and columns are labeled from the iOS `run_start` event's
// `smoothing_buffer_depth` metadata (falls back to source name).
//
// usage:
//   node scripts/compare-profile-runs.js profiler/ios-A.jsonl profiler/A-viewer.jsonl profiler/ios-B.jsonl ...
//   node scripts/compare-profile-runs.js profiler/        # scans directory
import { existsSync, lstatSync, readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const args = process.argv.slice(2);
const files = [];
for (const arg of args) {
  if (!existsSync(arg)) {
    console.error(`warning: skipping missing path ${arg}`);
    continue;
  }
  if (lstatSync(arg).isDirectory()) {
    for (const name of readdirSync(arg)) {
      if (name.endsWith('.jsonl')) files.push(join(arg, name));
    }
  } else {
    files.push(arg);
  }
}

if (files.length === 0) {
  console.error('usage: scripts/compare-profile-runs.js <jsonl files or directory>');
  process.exit(1);
}

const runs = new Map();
for (const file of files) {
  for (const line of readFileSync(file, 'utf8').split(/\r?\n/)) {
    if (!line.trim()) continue;
    let ev;
    try { ev = JSON.parse(line); } catch { continue; }
    if (!ev.run_id || !ev.side) continue;
    if (!runs.has(ev.run_id)) {
      runs.set(ev.run_id, {
        runID: ev.run_id,
        source: null,
        depth: null,
        iosFile: null,
        viewerFile: null,
        iosWindows: [],
        viewerWindows: [],
        iosIncomplete: false,
        viewerIncomplete: false,
      });
    }
    const run = runs.get(ev.run_id);
    if (run.source == null && ev.source) run.source = ev.source;
    if (ev.side === 'ios') run.iosFile = run.iosFile ?? file;
    else if (ev.side === 'viewer') run.viewerFile = run.viewerFile ?? file;
    if (ev.event === 'run_start') {
      if (ev.side === 'ios' && typeof ev.smoothing_buffer_depth === 'number') {
        run.depth = ev.smoothing_buffer_depth;
      }
    } else if (ev.event === 'run_stop') {
      if (ev.side === 'ios') run.iosIncomplete = !!ev.incomplete;
      else if (ev.side === 'viewer') run.viewerIncomplete = !!ev.incomplete;
    } else if (ev.event === 'profile_window') {
      if (ev.side === 'ios') run.iosWindows.push(ev.metrics ?? {});
      else if (ev.side === 'viewer') run.viewerWindows.push(ev.metrics ?? {});
    }
  }
}

const runList = [...runs.values()]
  .filter((r) => r.iosWindows.length > 0 || r.viewerWindows.length > 0)
  .sort((a, b) => {
    // front camera reference column first; then glasses by depth ascending;
    // unknown depth at the end.
    if (a.source !== b.source) return a.source === 'frontCamera' ? -1 : 1;
    const ad = a.depth ?? Number.POSITIVE_INFINITY;
    const bd = b.depth ?? Number.POSITIVE_INFINITY;
    if (ad !== bd) return ad - bd;
    return a.runID.localeCompare(b.runID);
  });

if (runList.length === 0) {
  console.error('error: no usable runs in inputs');
  process.exit(1);
}

const summaries = runList.map(summarize);

// ---- Output --------------------------------------------------------------

const now = new Date().toISOString();
const out = [];

out.push('# Profile comparison report');
out.push('');
out.push(`Generated ${now} from ${runList.length} run${runList.length === 1 ? '' : 's'}:`);
out.push('');
for (const r of runList) {
  const label = labelOf(r);
  const incomplete = r.iosIncomplete || r.viewerIncomplete ? ' _(incomplete)_' : '';
  out.push(`- **${label}** — \`${r.runID}\`${incomplete}`);
  if (r.iosFile) out.push(`  - iOS: \`${r.iosFile}\``);
  if (r.viewerFile) out.push(`  - viewer: \`${r.viewerFile}\``);
}
out.push('');
out.push('All values are per-window medians unless suffixed `(total)` (run sum) or `(worst)` (run maximum). Empty cells (`—`) mean the metric does not apply.');
out.push('');

// §3a publisher table
out.push('## 3a. iPhone publisher side');
out.push('');
out.push(headerRow(summaries));
out.push(alignRow(summaries));
emitRows(out, summaries, [
  ['**1. DAT delivery**', 'callback fps', (s) => s.source === 'glasses' ? fmt(s.datCallbackFps) : '—'],
  ['', 'callbacks (total)', (s) => s.source === 'glasses' ? fmtInt(s.datCallbacksTotal) : '—'],
  ['', 'inter-frame gap p50 ms', (s) => s.source === 'glasses' ? fmt(s.datGapP50) : '—'],
  ['', 'inter-frame gap p95 ms', (s) => s.source === 'glasses' ? fmt(s.datGapP95) : '—'],
  ['', 'inter-frame gap max ms (worst)', (s) => s.source === 'glasses' ? fmt(s.datGapMaxWorst) : '—'],
  ['**2. In-app decode**', 'decoder rebuilds (total)', (s) => s.source === 'glasses' ? fmtInt(s.decoderRebuilds) : '—'],
  ['', 'decode errors (total)', (s) => s.source === 'glasses' ? fmtInt(s.decodeErrors) : '—'],
  ['', 'decoded frames (total)', (s) => s.source === 'glasses' ? fmtInt(s.decodedFrames) : '—'],
  ['**3. Capturer hand-off**', 'capturer frames (total)', (s) => fmtInt(s.capturerFrames)],
  ['', 'unique frame % (1 − underruns/pulls)', (s) => s.uniqueFramePct == null ? '—' : `${pct(s.uniqueFramePct)}`],
  ['**4. LiveKit encode**', 'outbound fps', (s) => fmt(s.outboundFps)],
  ['', 'frames encoded (total)', (s) => fmtInt(s.framesEncoded)],
  ['', 'encoder-drop rate (raw)', (s) => s.encoderDropRateRaw == null ? '—' : pct(s.encoderDropRateRaw)],
  ['', 'encoder-drop rate (excl underruns)', (s) => s.encoderDropRateUnique == null ? '—' : pct(s.encoderDropRateUnique)],
  ['', 'bitrate (median, Mbps)', (s) => fmt(s.bitrateMbpsMed)],
  ['', 'resolution', (s) => s.resolution ?? '—'],
  ['', 'quality_limitation reason', (s) => s.qualityLimitationReason ?? '—'],
  ['**5. Network (RTCP)**', 'remote jitter ms', (s) => fmt(s.remoteJitterMed)],
  ['', 'round-trip time ms', (s) => fmt(s.remoteRttMed)],
]);
out.push('');

// §3b viewer table
out.push('## 3b. Browser viewer side');
out.push('');
out.push(headerRow(summaries));
out.push(alignRow(summaries));
emitRows(out, summaries, [
  ['**6. WebRTC ingress**', 'inbound fps', (s) => fmt(s.inboundFps)],
  ['', 'frames decoded (total)', (s) => fmtInt(s.framesDecodedTotal)],
  ['', 'frames dropped (total)', (s) => fmtInt(s.framesDroppedTotal)],
  ['', 'packets lost (total)', (s) => fmtInt(s.packetsLostTotal)],
  ['', 'jitter ms', (s) => fmt(s.viewerJitterMed)],
  ['', 'jitter-buffer per-frame delay ms', (s) => fmt(s.jbPerFrameMs)],
  ['**7. `<video>` playout**', 'rendered frames (total)', (s) => fmtInt(s.renderedFramesTotal)],
  ['', 'playout-dropped frames', (s) => s.playoutDroppedTotal == null ? '—' : `${fmtInt(s.playoutDroppedTotal)}${s.playoutDroppedPct != null ? ` (${pct(s.playoutDroppedPct)})` : ''}`],
  ['', 'freeze events (total)', (s) => fmtInt(s.freezeEvents)],
  ['', 'worst freeze ms', (s) => fmtInt(s.worstFreezeMs)],
]);
out.push('');

// §3c smoothing buffer (only if any run had buffer active)
const anyBuffer = summaries.some((s) => s.bufferActive);
if (anyBuffer) {
  out.push('## 3c. Smoothing buffer');
  out.push('');
  out.push(headerRow(summaries));
  out.push(alignRow(summaries));
  emitRows(out, summaries, [
    ['**8. Buffer**', 'configured depth', (s) => s.depth == null ? (s.bufferActive ? '(unknown)' : '—') : String(s.depth)],
    ['', 'pulls (total)', (s) => s.bufferActive ? fmtInt(s.bufferPulls) : '—'],
    ['', 'overruns (total)', (s) => s.bufferActive ? fmtInt(s.bufferOverruns) : '—'],
    ['', 'underruns (total)', (s) => s.bufferActive ? fmtInt(s.bufferUnderruns) : '—'],
    ['', 'underrun rate', (s) => s.bufferUnderrunRate == null ? '—' : pct(s.bufferUnderrunRate)],
    ['', 'depth p50 (frames)', (s) => s.bufferActive ? fmt(s.bufferDepthP50, 1) : '—'],
    ['', 'depth p95 (frames)', (s) => s.bufferActive ? fmt(s.bufferDepthP95, 1) : '—'],
    ['', 'priming latency added (ms)', (s) => s.bufferActive && s.depth != null ? fmt(s.depth * (1000 / 30)) : '—'],
  ]);
  out.push('');
}

process.stdout.write(out.join('\n') + '\n');

// ---- Helpers -------------------------------------------------------------

function labelOf(r) {
  if (r.source === 'glasses') {
    if (r.depth != null) return `glasses d=${r.depth}`;
    // Old runs lack run_start.smoothing_buffer_depth; infer from window data.
    const hadBuffer = r.iosWindows.some((m) => typeof m.buffer_pulls_delta === 'number' && m.buffer_pulls_delta > 0);
    return hadBuffer ? 'glasses (buffer)' : 'glasses';
  }
  if (r.source === 'frontCamera') return 'front camera';
  return r.source ?? r.runID;
}

function summarize(run) {
  const ios = run.iosWindows;
  const viewer = run.viewerWindows;

  const capturerFrames = sum(ios.map((m) => m.capturer_frames_delta));
  const framesEncoded = sum(ios.map((m) => m.frames_encoded_delta));
  const bufferPulls = sum(ios.map((m) => m.buffer_pulls_delta));
  const bufferUnderruns = sum(ios.map((m) => m.buffer_underruns_delta));
  const bufferOverruns = sum(ios.map((m) => m.buffer_overruns_delta));

  const encoderDropRateRaw = capturerFrames != null && capturerFrames > 0
    ? 1 - (framesEncoded ?? 0) / capturerFrames : null;

  // When the buffer is active, each underrun is a repeat-of-last frame; the
  // encoder typically declines to encode bit-identical repeats. The "real"
  // burst-induced drop rate excludes those: dropExcl = max(0, capturerFrames -
  // framesEncoded - underruns), denominator = unique_pulls.
  // Detect buffer activity from window data (works for old runs without
  // run_start metadata).
  const bufferActive = bufferPulls != null && bufferPulls > 0;
  let encoderDropRateUnique = null;
  let uniqueFramePct = null;
  if (bufferActive && bufferUnderruns != null) {
    const uniquePulls = bufferPulls - bufferUnderruns;
    uniqueFramePct = bufferPulls > 0 ? uniquePulls / bufferPulls : null;
    if (uniquePulls > 0) {
      const drops = (capturerFrames ?? 0) - (framesEncoded ?? 0);
      const uniqueDrops = Math.max(0, drops - bufferUnderruns);
      encoderDropRateUnique = uniqueDrops / uniquePulls;
    }
  } else if (run.source === 'glasses') {
    encoderDropRateUnique = encoderDropRateRaw;
  }

  const framesDecodedTotal = sum(viewer.map((m) => m.frames_decoded_delta));
  const playoutDroppedTotal = sum(viewer.map((m) => m.playout_dropped_frames_delta));
  const playoutDroppedPct = framesDecodedTotal && framesDecodedTotal > 0
    ? (playoutDroppedTotal ?? 0) / framesDecodedTotal : null;

  const cumulativeTargetDelay = max(viewer.map((m) => m.jitter_buffer_target_delay_ms));
  const jbPerFrameMs = cumulativeTargetDelay != null && framesDecodedTotal
    ? cumulativeTargetDelay / framesDecodedTotal : null;

  const bufferUnderrunRate = bufferPulls && bufferUnderruns != null && bufferPulls > 0
    ? bufferUnderruns / bufferPulls : null;

  return {
    runID: run.runID,
    source: run.source,
    depth: run.depth,
    label: labelOf(run),
    bufferActive,
    // DAT
    datCallbackFps: med(ios.map((m) => m.dat_callback_fps)),
    datCallbacksTotal: sum(ios.map((m) => m.dat_callbacks_delta)),
    datGapP50: med(ios.map((m) => m.dat_interframe_gap_p50_ms)),
    datGapP95: med(ios.map((m) => m.dat_interframe_gap_p95_ms)),
    datGapMaxWorst: max(ios.map((m) => m.dat_interframe_gap_max_ms)),
    // Decode
    decoderRebuilds: sum(ios.map((m) => m.decoder_rebuilds_delta)),
    decodeErrors: sum(ios.map((m) => m.decode_errors_delta)),
    decodedFrames: sum(ios.map((m) => m.decoded_frames_delta)),
    // Capturer
    capturerFrames,
    uniqueFramePct,
    // Encode
    outboundFps: med(ios.map((m) => m.outbound_fps)),
    framesEncoded,
    encoderDropRateRaw,
    encoderDropRateUnique,
    bitrateMbpsMed: nullableDiv(med(ios.map((m) => m.bitrate_bps)), 1e6),
    resolution: mode(ios.map((m) =>
      m.outbound_width && m.outbound_height ? `${m.outbound_width}×${m.outbound_height}` : null)),
    qualityLimitationReason: mode(ios.map((m) => m.quality_limitation_reason)),
    // Network
    remoteJitterMed: med(ios.map((m) => m.remote_jitter_ms)),
    remoteRttMed: med(ios.map((m) => m.remote_round_trip_time_ms)),
    // Viewer ingress
    inboundFps: med(viewer.map((m) => m.inbound_fps)),
    framesDecodedTotal,
    framesDroppedTotal: sum(viewer.map((m) => m.frames_dropped_delta)),
    packetsLostTotal: sum(viewer.map((m) => m.packets_lost_delta)),
    viewerJitterMed: med(viewer.map((m) => m.jitter_ms)),
    jbPerFrameMs,
    // Viewer playout
    renderedFramesTotal: sum(viewer.map((m) => m.rendered_frames_delta)),
    playoutDroppedTotal,
    playoutDroppedPct,
    freezeEvents: sum(viewer.map((m) => m.freeze_events_delta)),
    worstFreezeMs: max(viewer.map((m) => m.freeze_max_gap_ms)),
    // Buffer
    bufferPulls,
    bufferUnderruns,
    bufferOverruns,
    bufferUnderrunRate,
    bufferDepthP50: med(ios.map((m) => m.buffer_depth_p50_frames)),
    bufferDepthP95: med(ios.map((m) => m.buffer_depth_p95_frames)),
  };
}

function headerRow(summaries) {
  return `| Stage | Metric | ${summaries.map((s) => s.label).join(' | ')} |`;
}

function alignRow(summaries) {
  return `|---|---|${summaries.map(() => '---:').join('|')}|`;
}

function emitRows(out, summaries, rows) {
  for (const [stage, metric, fn] of rows) {
    const cells = summaries.map(fn).map((v) => v ?? '—');
    out.push(`| ${stage} | ${metric} | ${cells.join(' | ')} |`);
  }
}

function fmt(v, precision = 2) {
  if (v == null || !Number.isFinite(v)) return '—';
  if (Number.isInteger(v)) return v.toLocaleString('en-US');
  return Number(v.toFixed(precision)).toLocaleString('en-US', {
    minimumFractionDigits: precision <= 2 ? Math.min(precision, 2) : 2,
    maximumFractionDigits: precision,
  });
}

function fmtInt(v) {
  if (v == null || !Number.isFinite(v)) return '—';
  return Math.round(v).toLocaleString('en-US');
}

function pct(fraction) {
  if (fraction == null || !Number.isFinite(fraction)) return '—';
  return `${(fraction * 100).toFixed(1)}%`;
}

function nullableDiv(n, d) {
  return n == null ? null : n / d;
}

function clean(values) {
  return values.filter((v) => typeof v === 'number' && Number.isFinite(v));
}

function med(values) {
  const ns = clean(values).sort((a, b) => a - b);
  if (!ns.length) return null;
  const mid = Math.floor(ns.length / 2);
  return ns.length % 2 ? ns[mid] : (ns[mid - 1] + ns[mid]) / 2;
}

function sum(values) {
  const ns = clean(values);
  return ns.length ? ns.reduce((a, b) => a + b, 0) : null;
}

function max(values) {
  const ns = clean(values);
  return ns.length ? Math.max(...ns) : null;
}

function mode(values) {
  const counts = new Map();
  for (const v of values) {
    if (v == null) continue;
    counts.set(v, (counts.get(v) ?? 0) + 1);
  }
  let best = null;
  let bestCount = 0;
  for (const [v, c] of counts) {
    if (c > bestCount) { best = v; bestCount = c; }
  }
  return best;
}
