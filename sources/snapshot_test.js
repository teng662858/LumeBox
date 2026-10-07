/* eslint-env node */

// Small Node-only regression tests for the checked-in HTML snapshots.
// The source itself remains QuickJS-compatible; this file is not imported by LumeBox.
var assert = require('node:assert/strict');
var fs = require('node:fs');
var path = require('node:path');
var test = require('node:test');
var vm = require('node:vm');

function loadSource(file) {
  var source = fs.readFileSync(path.join(__dirname, file), 'utf8');
  var context = {};
  vm.runInNewContext(source, context, { filename: file });
  return context.LumeSource;
}

test('daniao5 ranking snapshot parses title-before-href anchors', async function () {
  var source = loadSource('daniao5_comic.js');
  var html = fs.readFileSync(path.join(__dirname, '..', 'daniao5.html'), 'utf8');
  // The checked-in file is the homepage snapshot. Restrict it to the embedded
  // ranking section so the normal update cards cannot satisfy the first parser.
  var rankingStart = html.indexOf('<div class="rank_hom');
  assert.notEqual(rankingStart, -1);
  html = html.slice(rankingStart);
  source.http = {
    get: async function () {
      return { status: 200, body: html };
    }
  };

  var result = await source.list({ categoryId: 'rank', page: 1 });
  assert.ok(result.items.length >= 4);
  assert.equal(JSON.stringify(result.items[0]), JSON.stringify({
    id: '53357',
    title: '秘密教学',
    cover: 'https://thumb.niaopic.com/upload_s/202209/20220930012101936.webp',
    subtitle: '大鸟禁漫'
  }));
  assert.ok(result.items.some(function (item) {
    return item.id === '54285' && item.title === '借妻条约';
  }));
});
