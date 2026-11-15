import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execSync } from 'node:child_process';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const homeDir = process.env.HOME || process.env.USERPROFILE || '';
const baoyuMdDist = path.join(homeDir, '.gemini/config/skills/baoyu-post-to-wechat/scripts/node_modules/baoyu-md/dist');
const themeDir = path.join(baoyuMdDist, 'themes');
const codeThemeDir = path.join(baoyuMdDist, 'code-themes');

const themes = {};
fs.readdirSync(themeDir).forEach(f => {
  if (f.endsWith('.css')) themes[f] = fs.readFileSync(path.join(themeDir, f), 'utf-8');
});

const codeThemes = {};
fs.readdirSync(codeThemeDir).forEach(f => {
  if (f.endsWith('.css')) codeThemes[f] = fs.readFileSync(path.join(codeThemeDir, f), 'utf-8');
});

// Create temp entry with inlined CSS
const tempEntry = path.join(__dirname, 'temp_formatter_entry.mjs');
const entryCode = `
import fs from 'node:fs';
import path from 'node:path';

const EMBEDDED_THEMES = ${JSON.stringify(themes)};
const EMBEDDED_CODE_THEMES = ${JSON.stringify(codeThemes)};

// Mock fs.existsSync and fs.readFileSync for theme loading
const originalExistsSync = fs.existsSync;
fs.existsSync = function(p) {
  const base = path.basename(p);
  if (EMBEDDED_THEMES[base] !== undefined || EMBEDDED_CODE_THEMES[base] !== undefined) {
    return true;
  }
  return originalExistsSync.apply(this, arguments);
};

const originalReadFileSync = fs.readFileSync;
fs.readFileSync = function(p, enc) {
  const base = path.basename(p);
  if (EMBEDDED_THEMES[base] !== undefined) {
    return EMBEDDED_THEMES[base];
  }
  if (EMBEDDED_CODE_THEMES[base] !== undefined) {
    return EMBEDDED_CODE_THEMES[base];
  }
  return originalReadFileSync.apply(this, arguments);
};

import {
  renderMarkdownDocument,
  parseFrontmatter,
  cleanSummaryText,
  extractSummaryFromBody,
  extractTitleFromMarkdown,
  resolveColorToken,
  stripWrappingQuotes,
  replaceMarkdownImagesWithPlaceholders
} from '${baoyuMdDist}/index.cjs';

export async function formatMarkdownToWechat(markdownContent, options = {}) {
  const { frontmatter, body } = parseFrontmatter(markdownContent);
  
  let title = stripWrappingQuotes(options.title || '') ||
              stripWrappingQuotes(frontmatter.title || '') ||
              extractTitleFromMarkdown(body) ||
              '未命名文章';
              
  let author = stripWrappingQuotes(options.author || '') ||
               stripWrappingQuotes(frontmatter.author || '') ||
               '';
               
  let summary = cleanSummaryText(options.summary || '') ||
                cleanSummaryText(frontmatter.description || '') ||
                cleanSummaryText(frontmatter.summary || '') ||
                extractSummaryFromBody(body, 120);

  const theme = options.theme || 'default';
  const color = options.color || undefined;
  const citeStatus = options.citeStatus !== false;

  const { images, markdown: rewrittenBody } = replaceMarkdownImagesWithPlaceholders(
    body,
    "WECHATIMGPH_"
  );

  const { html } = await renderMarkdownDocument(rewrittenBody, {
    citeStatus,
    defaultTitle: title,
    keepTitle: false,
    primaryColor: resolveColorToken(color),
    theme,
  });

  return {
    title,
    author,
    summary,
    html,
    images,
    frontmatter
  };
}
`;

fs.writeFileSync(tempEntry, entryCode, 'utf-8');

const outPath = path.join(__dirname, '../entry/src/main/resources/rawfile/dsh_bridge/wechat-formatter.mjs');

console.log('Bundling with npx esbuild...');
const bannerJs = `
import { createRequire as __createRequire } from 'node:module';
import { fileURLToPath as __fileURLToPath } from 'node:url';
import * as __nodePath from 'node:path';
const require = __createRequire(import.meta.url);
const __filename = __fileURLToPath(import.meta.url);
const __dirname = __nodePath.dirname(__filename);
`;

execSync(`npx --yes esbuild "${tempEntry}" --bundle --platform=node --format=esm --banner:js="${bannerJs.replace(/\n/g, ' ')}" --outfile="${outPath}"`, {
  stdio: 'inherit'
});

fs.unlinkSync(tempEntry);
console.log('Successfully bundled wechat-formatter.mjs to:', outPath);
