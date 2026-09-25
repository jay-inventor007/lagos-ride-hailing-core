// Runs every attempt in sql/004_invalid_inserts.sql, each in its own transaction that is rolled
// back, and prints the database's error. Fails if any attempt is NOT rejected.

import { writeFile } from 'node:fs/promises';
import path from 'node:path';
import { pool, readNamedBlocks, sqlDir } from './db.js';

const tests = await readNamedBlocks('004_invalid_inserts.sql', 'test');
const lines: string[] = [];
const out = (text = '') => {
  console.log(text);
  lines.push(text);
};

let accepted = 0;
const client = await pool.connect();
try {
  for (const [title, block] of tests) {
    const expected = block.match(/^-- Expected: (.*)$/m)?.[1] ?? '';
    const sql = block.replace(/^--.*$/gm, '').trim();
    out(title);
    out(`  ${expected}`);
    await client.query('begin');
    try {
      const result = await client.query(sql);
      accepted += 1;
      out(`  NOT REJECTED: ${result.rowCount} row(s) changed`);
    } catch (err) {
      const e = err as { code?: string; constraint?: string; message?: string; detail?: string };
      out(`  REJECTED  code ${e.code}, constraint ${e.constraint ?? '(none)'}`);
      out(`  ERROR:    ${e.message}`);
      if (e.detail) out(`  DETAIL:   ${e.detail}`);
    } finally {
      await client.query('rollback');
    }
    out();
  }
} finally {
  client.release();
  await pool.end();
}

await writeFile(path.join(sqlDir, '..', 'docs', 'evidence', 'invalid-inserts.txt'), lines.join('\n'));
if (accepted > 0) {
  console.error(`${accepted} invalid change(s) were accepted`);
  process.exit(1);
}
