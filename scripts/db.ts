import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const connectionString = process.env.DATABASE_URL;
if (!connectionString) {
  throw new Error('DATABASE_URL is not set. Copy .env.example to .env and fill it in.');
}

const isLocal = /@(localhost|127\.0\.0\.1)[:/]/.test(connectionString);

export const pool = new pg.Pool({
  connectionString,
  ssl: isLocal ? false : { rejectUnauthorized: false },
  max: 2,
});

// Every connection works inside the "ride" schema.
pool.on('connect', (client) => {
  client.query('set search_path to ride, public');
});

export const sqlDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'sql');

export const readSql = (file: string) => readFile(path.join(sqlDir, file), 'utf8');

// Splits a .sql file into named blocks. A block starts with a line "-- name: <name>" and runs
// until the next such line. Anything before the first marker is ignored.
export async function readNamedBlocks(file: string, marker: string): Promise<Map<string, string>> {
  const text = await readSql(file);
  const blocks = new Map<string, string>();
  const parts = text.split(new RegExp(`^-- ${marker}: `, 'm')).slice(1);
  for (const part of parts) {
    const newline = part.indexOf('\n');
    blocks.set(part.slice(0, newline).trim(), part.slice(newline + 1).trim());
  }
  return blocks;
}
