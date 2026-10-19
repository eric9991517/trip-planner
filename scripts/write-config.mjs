import { copyFile, mkdir, writeFile } from 'node:fs/promises';
const supabaseUrl = process.env.SUPABASE_URL;
const supabaseAnonKey = process.env.SUPABASE_ANON_KEY;
if (!supabaseUrl || !supabaseAnonKey) throw new Error('Set SUPABASE_URL and SUPABASE_ANON_KEY before building.');
if (!supabaseUrl.startsWith('https://')) throw new Error('SUPABASE_URL must use HTTPS.');
if (/service_role|sb_secret_/i.test(supabaseAnonKey)) throw new Error('Never publish a Supabase secret or service role key in frontend config.');
const outputDir = new URL('../dist/', import.meta.url);
await mkdir(outputDir, { recursive: true });
for (const file of ['index.html', 'main.js', 'style.css']) {
  await copyFile(new URL(`../${file}`, import.meta.url), new URL(file, outputDir));
}
await writeFile(new URL('config.js', outputDir), `window.TRIP_APP_CONFIG = ${JSON.stringify({ supabaseUrl, supabaseAnonKey })};\n`);
