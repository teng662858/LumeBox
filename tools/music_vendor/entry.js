// Pinned compatibility dependencies for imported MusicFree/LX scripts.
// Build: npm ci --prefix tools/music_vendor && npm run build --prefix tools/music_vendor
import CryptoJS from 'crypto-js';
import * as cheerio from 'cheerio/slim';
import bigInt from 'big-integer';
import * as pako from 'pako';
globalThis.__lumeMusicVendors = { 'crypto-js': CryptoJS, cheerio, 'big-integer': bigInt, pako };
