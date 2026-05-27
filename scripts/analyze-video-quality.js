#!/usr/bin/env node
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const inputPaths = process.argv.slice(2);
const files = inputPaths.length > 0 ? inputPaths : defaultProfilerFiles();

if (files.length === 0) {
  console.error('usage: scripts/analyze-video-quality.js profiler/*.jsonl');
  process.exit(1);
}

const runs = new Map();
for (const file of files) {
  if (!existsSync(file)) {
    console.error(`warning: skipping missing file ${file}`);
    continue;
  }
  for (const line of readFileSync(file, 'utf8').split(/\r?\n/)) {
    if (!line.trim()) continue;
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      continue;
    }
    if (!event.run_id || !event.side || !event.source) continue;
    const key = `${event.run_id}:${event.side}`;
    if (!runs.has(key)) {
      runs.set(key, {
        runID: event.run_id,
        side: event.side,
        source: event.source,
        incomplete: false,
        windows: [],
      });
    }
    const run = runs.get(key);
    if (event.event === 'run_stop') run.incomplete = Boolean(event.incomplete);
    if (event.event === 'profile_window') run.windows.push(event.metrics ?? {});
  }
}

const summaries = [...runs.values()].map(summarizeRun);
const bySourceSide = new Map();
for (const summary of summaries) {
  const key = `${summary.source}:${summary.side}`;
  if (!bySourceSide.has(key)) bySourceSide.set(key, []);
  bySourceSide.get(key).push(summary);
}

console.log('source       side     runs  sent_fps  bitrate_mbps  recv_fps  lost_pkts  dropped  freezes  max_freeze_ms  stalls  incomplete');
for (const [key, group] of [...bySourceSide.entries()].sort()) {
  const [source, side] = key.split(':');
  console.log([
    source.padEnd(12),
    side.padEnd(8),
    String(group.length).padStart(4),
    fmt(median(group.map((r) => r.sentFps))).padStart(8),
    fmt(median(group.map((r) => r.bitrateMbps))).padStart(13),
    fmt(median(group.map((r) => r.recvFps))).padStart(8),
    fmt(sum(group.map((r) => r.lostPackets))).padStart(9),
    fmt(sum(group.map((r) => r.droppedFrames))).padStart(8),
    fmt(sum(group.map((r) => r.freezeEvents))).padStart(8),
    fmt(max(group.map((r) => r.maxFreezeMs))).padStart(13),
    fmt(sum(group.map((r) => r.stallWindows))).padStart(7),
    String(group.filter((r) => r.incomplete).length).padStart(10),
  ].join('  '));
}

function defaultProfilerFiles() {
  try {
    return readdirSync('profiler')
      .filter((name) => name.endsWith('.jsonl'))
      .map((name) => join('profiler', name));
  } catch {
    return [];
  }
}

function summarizeRun(run) {
  return {
    ...run,
    sentFps: median(run.windows.map((m) => m.outbound_fps)),
    bitrateMbps: median(run.windows.map((m) => m.bitrate_bps).map((v) => v == null ? null : v / 1_000_000)),
    recvFps: median(run.windows.map((m) => m.inbound_fps)),
    lostPackets: sum(run.windows.map((m) => m.packets_lost_delta ?? m.remote_packets_lost_delta)),
    droppedFrames: sum(run.windows.map((m) => m.frames_dropped_delta ?? m.playout_dropped_frames_delta)),
    freezeEvents: sum(run.windows.map((m) => m.freeze_events_delta)),
    maxFreezeMs: max(run.windows.map((m) => m.freeze_max_gap_ms)),
    stallWindows: run.windows.filter((m) => m.frames_encoded_delta === 0).length,
  };
}

function clean(values) {
  return values.filter((v) => typeof v === 'number' && Number.isFinite(v));
}

function median(values) {
  const nums = clean(values).sort((a, b) => a - b);
  if (nums.length === 0) return null;
  const mid = Math.floor(nums.length / 2);
  return nums.length % 2 === 0 ? (nums[mid - 1] + nums[mid]) / 2 : nums[mid];
}

function sum(values) {
  const nums = clean(values);
  return nums.length === 0 ? null : nums.reduce((total, value) => total + value, 0);
}

function max(values) {
  const nums = clean(values);
  return nums.length === 0 ? null : Math.max(...nums);
}

function fmt(value) {
  if (value == null) return '-';
  if (Number.isInteger(value)) return String(value);
  return value.toFixed(2);
}
