#!/usr/bin/env node
// 圖表圖示: 各州的 county 簡化後平塗, 白色細邊, 相鄰的 county 不同色; 全國圖用州. 給 makechart 的 @makechart/iconset
//
//   node tool/icon.js <iconset 的 src/flat 目錄> [地圖目錄, 預設 dist/map]
//   e.g. node tool/icon.js ../../server/module/makechart/iconset/src/flat
//
// 輸出 usmap-<USPS>.svg ( 每個有州檔的州, 含屬地 ) 與 usmap-nation.svg ( 256x256, 與 iconset 其他圖示相同 ),
// 並更新同目錄的 index.json ( set: usmap ). 比照 twmapadv 的 tool/icon.js.
// 顏色用 icon-gen 的原色 ( teal / coral / gold + 兩種灰 ), iconset 的 build.ls 會換成 logo 色.
// 地圖檔已投影成平面座標 ( y 向下, 同畫面 ), 用 d3.geoIdentity fit, 不翻 y. 州與 county 共用 arc, 簡化後鄰接關係不變
const fs = require('fs');
const path = require('path');
const topojson = require('topojson-client');
const simplify = require('topojson-simplify');
const d3 = require('d3-geo');

const [out, src = path.join(__dirname, '..', 'dist', 'map')] = process.argv.slice(2);
if (!out) {
  console.error('usage: node tool/icon.js <iconset src/flat dir> [map dir]');
  process.exit(1);
}

// 尺寸與風格: 同 twmap 的圖示 ( 256 見方, 白邊圓角 )
const SIZE = 256;
const PAD = 20;
const colors = ['#158b89', '#ec6948', '#dfac28', '#c8c8c8', '#d7d7d7'];
// 每張圖留下的點數 ( 大約 ). 太多檔案變大, 太少形狀認不出來.
// county 多的州 ( 德州 254 個 ) 每個 county 至少平均 PER 點, 否則簡化後小的 county 塌成一點
const POINTS = 400;
const PER = 5;
// 範圍的門檻 ( 佔全部的比例 ), 預設 1%. 美屬薩摩亞北方的 Swains 約 1.8%, 框進來主島擠到一角;
// 全部提高到 2% 的話波多黎各的 Vieques、Culebra 會在框外
const MAIN = { AS: 0.02 };
// 平面面積 ( 地圖檔的座標 )
const planar = d3.geoPath();

// topo: 地圖檔, key: 要畫的 object ( county / state )
const icon = (topo, key, name, subject) => {
  topo = { ...topo, objects: { [key]: topo.objects[key] } };
  topo = simplify.presimplify(topo);
  // 門檻只看用到的 arc: 權重第 n 大的值
  const used = new Set();
  const walk = (a) => (Array.isArray(a) ? a.forEach(walk) : used.add(a < 0 ? ~a : a));
  topo.objects[key].geometries.forEach((g) => walk(g.arcs || []));
  const ws = [];
  for (const i of used) for (const p of topo.arcs[i]) if (isFinite(p[2])) ws.push(p[2]);
  ws.sort((a, b) => b - a);
  const n = Math.max(POINTS, PER * topo.objects[key].geometries.length);
  topo = simplify.simplify(topo, ws.length > n ? ws[n] : 0);
  const fc = topojson.feature(topo, topo.objects[key]);
  // 範圍只看夠大的區塊 ( 合併後的連通塊, 佔全部 1% 以上, 個別的見 MAIN ): 阿拉斯加的阿留申群島、屬地遠方的小島,
  // 全部框進來主體會縮成一點. 框外的小島不畫. 要先合併: county 多的州每個 county 都不到 1%
  const merged = topojson.merge(topo, topo.objects[key].geometries.filter((g) => g.type));
  const polys = merged.coordinates.map((p) => ({ type: 'Polygon', coordinates: p }));
  const sum = polys.reduce((a, p) => a + planar.area(p), 0);
  const main = { type: 'GeometryCollection', geometries: polys.filter((p) => planar.area(p) > sum * (MAIN[name] || 0.01)) };
  const proj = d3.geoIdentity().fitExtent([[PAD, PAD], [SIZE - PAD, SIZE - PAD]], main);
  const gp = d3.geoPath(proj).digits(0);
  const inside = (p) => {
    const [[x0, y0], [x1, y1]] = gp.bounds({ type: 'Polygon', coordinates: p });
    return x0 >= 0 && y0 >= 0 && x1 <= SIZE && y1 <= SIZE;
  };
  // 太小的島 ( 畫出來不到 1.5px 見方 ) 不畫
  const feats = fc.features.map((ft) => {
    const g = ft.geometry;
    if (!g) return null;
    const polys = (g.type === 'Polygon' ? [g.coordinates] : g.coordinates)
      .filter((p) => inside(p) && gp.area({ type: 'Polygon', coordinates: p }) > 2.25);
    if (!polys.length) return null;
    return { code: ft.properties.code, geometry: { type: 'MultiPolygon', coordinates: polys }, area: 0 };
  });
  // 著色: 由大到小, 避開相鄰的顏色, 其中挑用得最少的 ( 同樣少時依代碼輪替, 結果固定 )
  const nb = topojson.neighbors(topo.objects[key].geometries);
  const count = colors.map(() => 0);
  const color = [];
  feats.forEach((ft) => { if (ft) ft.area = gp.area(ft.geometry); });
  const order = feats.map((ft, i) => i).filter((i) => feats[i]).sort((a, b) => feats[b].area - feats[a].area);
  for (const i of order) {
    const ban = new Set(nb[i].map((j) => color[j]).filter((c) => c != null));
    const k = +feats[i].code.slice(-2);
    const ok = colors.map((c, ci) => ci).filter((ci) => !ban.has(ci));
    const pick = (ok.length ? ok : colors.map((c, ci) => ci))
      .sort((a, b) => (count[a] - count[b]) || (((a + k) % colors.length) - ((b + k) % colors.length)))[0];
    color[i] = pick;
    count[pick]++;
  }
  // 島又小又散的 ( 屬地 ), 填色不到畫面的 5% 時, 用同色的粗邊把島加粗, 不畫白邊. 填色越少邊越粗
  const cover = order.reduce((a, i) => a + feats[i].area, 0) / (SIZE * SIZE);
  const sparse = cover < 0.05;
  const fat = Math.min(12, 6 * Math.sqrt(0.02 / cover)).toFixed(1);
  const paths = order.map((i) => {
    const c = colors[color[i]];
    return `    <path fill="${c}"${sparse ? ` stroke="${c}"` : ''} d="${gp(feats[i].geometry)}"/>`;
  });
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${SIZE} ${SIZE}" width="${SIZE}" height="${SIZE}">\n` +
    `  <g id="${key}"${sparse ? ` stroke-width="${fat}"` : ' stroke="#ffffff" stroke-width="1.5"'} stroke-linejoin="round" stroke-linecap="round">\n` +
    paths.join('\n') + '\n  </g>\n</svg>\n';
  fs.writeFileSync(path.join(out, `usmap-${name}.svg`), svg);
  console.error(`${name}: ${paths.length} ${key}${sparse ? ' ( sparse, cover ' + Math.round(cover * 100) + '% )' : ''}, ${Math.round(svg.length / 1024 * 10) / 10}KB`);
  return { name: `usmap-${name}`, subject, set: 'usmap' };
};

const read = (f) => JSON.parse(fs.readFileSync(path.join(src, f), 'utf8'));
const list = [icon(read('nation.json'), 'state', 'nation', 'map of the United States by state')];
for (const s of read('index.json').states) {
  list.push(icon(read(`state/${s.usps}.json`), 'county', s.usps, `map of ${s.name} ( ${s.usps} ) by county`));
}

const idx = path.join(out, 'index.json');
const old = fs.existsSync(idx) ? JSON.parse(fs.readFileSync(idx, 'utf8')) : [];
const names = new Set(list.map((d) => d.name));
fs.writeFileSync(idx, JSON.stringify(old.filter((d) => !names.has(d.name)).concat(list), null, 1) + '\n');
