/** ONECOPY — independent zero-dependency byte-exact duplicate scanner. */
const CHUNK_BYTES = 1024 * 1024;
const SAMPLE_BYTES = 64 * 1024;
const pause = () => new Promise(resolve => setTimeout(resolve, 0));
const aborted = signal => { if (signal?.aborted) throw new DOMException('Проверка отменена', 'AbortError'); };

export function formatSize(bytes) {
  if (bytes < 1024) return `${bytes} Б`;
  const units = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];
  const i = Math.min(4, Math.floor(Math.log(bytes) / Math.log(1024)));
  return `${(bytes / 1024 ** i).toLocaleString('ru-RU', { maximumFractionDigits: 1 })} ${units[i]}`;
}

export async function sampleFingerprint(file, signal) {
  aborted(signal);
  // When Web Crypto is unavailable (e.g. some local-file viewers), never
  // guess a fingerprint: compare all same-sized candidates byte-by-byte.
  if (!globalThis.crypto?.subtle) return 'no-crypto-full-comparison';
  const s = file.size;
  const starts = [0, Math.max(0, Math.floor(s / 2) - SAMPLE_BYTES / 2), Math.max(0, s - SAMPLE_BYTES)];
  const pieces = await Promise.all(starts.map(i => file.slice(i, Math.min(s, i + SAMPLE_BYTES)).arrayBuffer()));
  aborted(signal);
  const n = pieces.reduce((sum, p) => sum + p.byteLength, 0);
  const combined = new Uint8Array(n + 8);
  const dv = new DataView(combined.buffer);
  dv.setUint32(0, Math.floor(s / (2 ** 32)), false);
  dv.setUint32(4, s >>> 0, false);
  let offset = 8;
  for (const part of pieces) { combined.set(new Uint8Array(part), offset); offset += part.byteLength; }
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', combined));
  return [...digest].map(x => x.toString(16).padStart(2, '0')).join('');
}

/** Final verification; never call duplicates on the basis of a digest alone. */
export async function identicalBytes(a, b, signal) {
  if (a.size !== b.size) return false;
  for (let pos = 0, count = 0; pos < a.size; pos += CHUNK_BYTES, count++) {
    aborted(signal);
    const end = Math.min(pos + CHUNK_BYTES, a.size);
    const [aa, bb] = await Promise.all([a.slice(pos, end).arrayBuffer(), b.slice(pos, end).arrayBuffer()]);
    const av = new Uint8Array(aa), bv = new Uint8Array(bb);
    if (av.length !== bv.length) return false;
    for (let j = 0; j < av.length; j++) if (av[j] !== bv[j]) return false;
    if (count % 4 === 3) await pause();
  }
  aborted(signal);
  return true;
}

/** @param {Array<{id: number, file: File, path: string}>} entries */
export async function detectDuplicates(entries, { signal, onProgress = () => {} } = {}) {
  const start = Date.now();
  const errors = [];
  const sizeMap = new Map();
  for (const entry of entries) {
    const list = sizeMap.get(entry.file.size) || [];
    list.push(entry);
    sizeMap.set(entry.file.size, list);
  }
  const eligible = [...sizeMap.values()].filter(x => x.length > 1).flat();
  const samples = new Map();
  let done = 0;
  for (const entry of eligible) {
    aborted(signal);
    try {
      const fingerprint = await sampleFingerprint(entry.file, signal);
      const key = `${entry.file.size}:${fingerprint}`;
      const group = samples.get(key) || [];
      group.push(entry);
      samples.set(key, group);
    } catch (err) {
      if (err.name === 'AbortError') throw err;
      errors.push({ entry, reason: 'Не удалось прочитать файл' });
    }
    onProgress({ phase: 'sample', completed: ++done, total: eligible.length });
    if (done % 5 === 0) await pause();
  }
  const probable = [...samples.values()].filter(list => list.length > 1);
  const totalComparisons = probable.reduce((n, arr) => n + arr.length, 0);
  let compared = 0;
  const groups = [];
  for (const group of probable) {
    const exactBuckets = [];
    for (const item of group) {
      aborted(signal);
      let matched = false;
      try {
        for (const bucket of exactBuckets) {
          if (await identicalBytes(bucket[0].file, item.file, signal)) {
            bucket.push(item); matched = true; break;
          }
        }
        if (!matched) exactBuckets.push([item]);
      } catch (err) {
        if (err.name === 'AbortError') throw err;
        errors.push({ entry: item, reason: 'Не удалось сравнить файл' });
      }
      onProgress({ phase: 'verify', completed: ++compared, total: totalComparisons });
    }
    for (const bucket of exactBuckets) if (bucket.length > 1) {
      groups.push({ id: bucket[0].id, entries: bucket, bytes: bucket[0].file.size });
    }
  }
  groups.sort((a, b) => b.bytes * (b.entries.length - 1) - a.bytes * (a.entries.length - 1));
  return { scanned: entries.length, groups, errors, durationMs: Date.now() - start,
    duplicates: groups.reduce((n, x) => n + x.entries.length - 1, 0),
    duplicatedBytes: groups.reduce((n, x) => n + x.bytes * (x.entries.length - 1), 0) };
}
