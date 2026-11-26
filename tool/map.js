#!/usr/bin/env node
// 由 Census 的 county 界 ( tool/fetch.js 下載, 已有就不重抓 ) 產生地圖檔 ( topojson, 已投影成平面座標 ):
//
//   node tool/map.js [年]            # 預設 2025
//
//   src/map/nation.json        全國: objects.state / objects.county, Albers USA, 阿拉斯加、夏威夷、波多黎各移到左下
//   src/map/state/<USPS>.json  各州: 同上兩個 objects ( state 只有一塊 ), 用該州自己的等積圓錐投影
//   src/map/index.json         州清單 ( 代碼、縮寫、名稱 ), 圖表用它解析 level
//
// 州界不用 Census 的州界檔, 由 county 合成 ( topojson mergeArcs ): 兩份檔各自簡化, 界線會錯開 ( 見 twmapadv ).
// 投影在這裡先做完, 圖表直接用平面座標; 這樣簡化的門檻是畫面上的大小, 不是經緯度.
// 全國圖不含波多黎各以外的屬地 ( 60 / 66 / 69 / 78 ), 它們只有各自的州檔.
const fs = require('fs');
const path = require('path');
const shapefile = require('shapefile');
const { topology } = require('topojson-server');
const { mergeArcs, quantize } = require('topojson-client');
const fetch = require('./fetch');
const { presimplify, simplify, filter, filterAttachedWeight } = require('topojson-simplify');

const year = process.argv[2] || '2025';
const out = path.join(__dirname, '..', 'src', 'map');
// 簡化門檻: 寬 1000 的畫面上, 小於這個面積 ( 平方單位 ) 的轉折點拿掉. 州檔用同一個門檻, 小州因此保留較多細節
const MIN_AREA = 0.05;
const QUANT = 1e5;
const TERRITORIES = ['60', '66', '69', '78'];

// 只投影頂點, 不重新取樣、不裁切: 每塊都在自己投影的中心附近, 不跨越投影的邊界
const projectGeom = (g, p) => {
  const ring = (r) => r.map((c) => p(c));
  if (g.type === 'Polygon') return { type: 'Polygon', coordinates: g.coordinates.map(ring) };
  if (g.type === 'MultiPolygon') return { type: 'MultiPolygon', coordinates: g.coordinates.map((s) => s.map(ring)) };
  throw new Error(`unexpected geometry ${g.type}`);
};

const eachCoord = (g, cb) => {
  const polys = g.type === 'Polygon' ? [g.coordinates] : g.coordinates;
  for (const poly of polys) for (const r of poly) for (const c of r) cb(c);
};

// 阿留申群島跨過換日線: 東經的點改成 -360 的那一側, 範圍才連續
const lon = (x) => (x > 0 ? x - 360 : x);

const build = (features, proj, file) => {
  const fc = { type: 'FeatureCollection', features: features.map((f) => ({ ...f, properties: { ...f.properties }, geometry: projectGeom(f.geometry, proj) })) };
  // 平面座標已經是畫面比例; 縮放成寬 1000 再算門檻
  let [x0, y0, x1, y1] = [Infinity, Infinity, -Infinity, -Infinity];
  for (const f of fc.features) eachCoord(f.geometry, ([x, y]) => { x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x); y1 = Math.max(y1, y); });
  const k = 1000 / (x1 - x0);
  for (const f of fc.features) eachCoord(f.geometry, (c) => { c[0] = (c[0] - x0) * k; c[1] = (c[1] - y0) * k; });

  let topo = topology({ county: fc });
  topo = presimplify(topo);
  topo = simplify(topo, MIN_AREA);
  // 很小又沒跟別塊相接的島拿掉 ( 簡化後只剩幾個點 ); 跟 county 相接的照留
  topo = filter(topo, filterAttachedWeight(topo, MIN_AREA * 4));
  topo = quantize(topo, QUANT);
  const geoms = topo.objects.county.geometries;
  const lost = geoms.filter((g) => !g.type || !g.arcs || !g.arcs.length).map((g) => g.properties.code);
  if (lost.length) throw new Error(`${file}: counties lost in simplification: ${lost.join(' ')}`);

  // 州由 county 合成, 與 county 共用 arc
  const by = {};
  for (const g of geoms) (by[g.properties.state] = by[g.properties.state] || []).push(g);
  topo.objects.state = {
    type: 'GeometryCollection',
    geometries: Object.entries(by).map(([code, gs]) => {
      const p = gs[0].properties;
      return {
        ...mergeArcs(topo, gs),
        properties: { code, name: p.state_name, usps: p.usps, aland: gs.reduce((a, g) => a + g.properties.aland, 0) }
      };
    })
  };
  // county 上不必重複州名
  for (const g of geoms) { delete g.properties.state_name; delete g.properties.usps; }
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(topo));
  return fs.statSync(file).size;
};

(async () => {
  const d3 = await import('d3-geo');
  const shp = await fetch(year);
  const features = [];
  const src = await shapefile.open(shp, undefined, { encoding: 'utf-8' });
  for (let r = await src.read(); !r.done; r = await src.read()) {
    const p = r.value.properties;
    features.push({
      type: 'Feature',
      geometry: r.value.geometry,
      properties: {
        code: p.GEOID, name: p.NAME, full: p.NAMELSAD, state: p.STATEFP,
        state_name: p.STATE_NAME, usps: p.STUSPS, aland: p.ALAND
      }
    });
  }
  features.sort((a, b) => a.properties.code.localeCompare(b.properties.code));

  // 全國: 同 d3.geoAlbersUsa 的參數, 另加波多黎各 ( 參數取自 d3-composite-projections 的 geoAlbersUsaTerritories ).
  // 每塊屬於哪一張小圖依州碼決定, 不依座標
  const K = 1070, X = 480, Y = 250;
  const insets = {
    lower48: d3.geoAlbers().scale(K).translate([X, Y]),
    '02': d3.geoConicEqualArea().rotate([154, 0]).center([-2, 58.5]).parallels([55, 65]).scale(K * 0.35).translate([X - 0.307 * K, Y + 0.201 * K]),
    '15': d3.geoConicEqualArea().rotate([157, 0]).center([-3, 19.9]).parallels([8, 18]).scale(K).translate([X - 0.205 * K, Y + 0.212 * K]),
    '72': d3.geoConicEqualArea().rotate([66, 0]).center([0, 18]).parallels([8, 18]).scale(K).translate([X + 0.350 * K, Y + 0.224 * K])
  };
  const nation = features.filter((f) => !TERRITORIES.includes(f.properties.state));
  const parts = {};
  for (const f of nation) {
    const key = insets[f.properties.state] ? f.properties.state : 'lower48';
    (parts[key] = parts[key] || []).push(f);
  }
  // 各州座標各自投影後合併成一張
  const projected = [];
  for (const [key, fs_] of Object.entries(parts)) for (const f of fs_) projected.push({ ...f, geometry: projectGeom(f.geometry, insets[key]) });
  const sizes = { nation: build(projected, (c) => c, path.join(out, 'nation.json')) };

  // 各州: 等積圓錐, 標準緯線取範圍的 1/6 與 5/6
  const states = {};
  for (const f of features) (states[f.properties.state] = states[f.properties.state] || []).push(f);
  const index = [];
  for (const [code, fs_] of Object.entries(states)) {
    let [a0, b0, a1, b1] = [Infinity, Infinity, -Infinity, -Infinity];
    for (const f of fs_) eachCoord(f.geometry, ([x, y]) => { x = lon(x); a0 = Math.min(a0, x); a1 = Math.max(a1, x); b0 = Math.min(b0, y); b1 = Math.max(b1, y); });
    const lc = (a0 + a1) / 2, pc = (b0 + b1) / 2, d = b1 - b0;
    const p = d3.geoConicEqualArea().rotate([-lc, 0]).center([0, pc]).parallels([b0 + d / 6, b1 - d / 6]).scale(1000).translate([0, 0]);
    const usps = fs_[0].properties.usps;
    sizes[usps] = build(fs_, (c) => p([lon(c[0]), c[1]]), path.join(out, 'state', `${usps}.json`));
    index.push({ code, usps, name: fs_[0].properties.state_name, nation: !TERRITORIES.includes(code) });
  }
  index.sort((a, b) => a.code.localeCompare(b.code));
  fs.writeFileSync(path.join(out, 'index.json'), JSON.stringify({ year, states: index }));

  const kb = (n) => `${(n / 1024).toFixed(0)}KB`;
  const total = Object.values(sizes).reduce((a, b) => a + b, 0);
  const top = Object.entries(sizes).filter(([k]) => k !== 'nation').sort((a, b) => b[1] - a[1]).slice(0, 3);
  console.log(`nation ${kb(sizes.nation)}; ${index.length} states, largest ${top.map(([k, v]) => `${k} ${kb(v)}`).join(', ')}; total ${kb(total)}`);
})().catch((e) => { console.error(e); process.exit(1); });
