#!/usr/bin/env node
// 產生範例資料 src/sample/nation.json ( build 時複製到 dist/sample/, 圖表執行時才載入 ):
//
//   node tool/sample.js [年]          # 人口估計的年份 ( vintage ), 預設 2025
//
// 資料來源: Census Population Estimates, county 的年齡、性別 ( 不需要 API key; ACS API 要 )
//   https://www2.census.gov/programs-surveys/popest/datasets/2020-<年>/counties/asrh/cc-est<年>-agesex-all.csv
//   波多黎各另一個檔 puerto-rico/asrh/cc-est<年>-agesex-72.csv
// 用檔案裡最新的一年 ( 7/1/<年> ). 面積取自 src/map/nation.json 的 aland ( 簡化前的陸地面積 ), 所以要先跑 tool/map.js.
//
// 每個 county 一列, 另加每個州一列 ( county 欄空白, 值是各 county 加總 ). 州圖 ( state/<州> ) 也用這個檔, 只取該州的列.
// GU、VI、AS、MP 沒有 county 的人口估計, 它們的州圖沒有範例資料
const fs = require('fs');
const path = require('path');
const { download } = require('./fetch');

const year = process.argv[2] || '2025';
const root = path.join(__dirname, '..');
const base = `https://www2.census.gov/programs-surveys/popest/datasets/2020-${year}`;
const files = {
  us: { url: `${base}/counties/asrh/cc-est${year}-agesex-all.csv`, code: (r) => r.STATE + r.COUNTY, name: (r) => r.CTYNAME },
  pr: { url: `${base}/puerto-rico/asrh/cc-est${year}-agesex-72.csv`, code: (r) => '72' + r.MUNICIPIO, name: (r) => r.NAME }
};

// 檔案是 latin-1 ( Doña Ana County )
const readCsv = (file) => {
  const [head, ...lines] = fs.readFileSync(file, 'latin1').split(/\r?\n/).filter((l) => l);
  const keys = head.split(',');
  return lines.map((l) => Object.fromEntries(l.split(',').map((v, i) => [keys[i], v])));
};

// 65 歲以上人口比例分級. 全國約 18%
const aging = (r) => r < 0.15 ? '<15%' : r < 0.2 ? '15–20%' : r < 0.25 ? '20–25%' : '≥25%';

(async () => {
  const dir = path.join(root, '.cache', 'popest', year);
  fs.mkdirSync(dir, { recursive: true });
  const map = JSON.parse(fs.readFileSync(path.join(root, 'src/map/nation.json')));
  const counties = Object.fromEntries(map.objects.county.geometries.map((g) => [g.properties.code, g.properties]));
  const states = Object.fromEntries(map.objects.state.geometries.map((g) => [g.properties.code, g.properties]));

  const stat = {};
  for (const [k, f] of Object.entries(files)) {
    const file = path.join(dir, path.basename(f.url));
    if (!fs.existsSync(file)) {
      console.log(`download ${f.url} ...`);
      await download(f.url, file + '.part');
      fs.renameSync(file + '.part', file);
    }
    const rows = readCsv(file).filter((r) => r.SUMLEV === '050');
    const last = Math.max(...rows.map((r) => +r.YEAR));
    for (const r of rows.filter((r) => +r.YEAR === last)) {
      const n = (k) => +r[k];
      const kids = n('UNDER5_TOT') + n('AGE513_TOT') + n('AGE1417_TOT');
      stat[f.code(r)] = { pop: n('POPESTIMATE'), m: n('POPEST_MALE'), f: n('POPEST_FEM'), kids, old: n('AGE65PLUS_TOT'), name: f.name(r) };
    }
  }

  const missing = Object.keys(counties).filter((c) => !stat[c]);
  const extra = Object.keys(stat).filter((c) => !counties[c]);
  if (missing.length || extra.length) {
    throw new Error(`county codes differ from the map: missing ${missing.join(' ') || '-'}, extra ${extra.join(' ') || '-'}`);
  }

  const row = (state, county, o, aland) => [
    state, county, o.pop, Math.round(o.pop / (aland / 1e6) * 10) / 10, o.m, o.f,
    o.kids, o.pop - o.kids - o.old, o.old, Math.round(o.old / o.pop * 1000) / 10, aging(o.old / o.pop)
  ];
  const sum = {};
  const rows = [];
  for (const [code, c] of Object.entries(counties)) {
    const o = stat[code];
    const s = sum[c.state] = sum[c.state] || { pop: 0, m: 0, f: 0, kids: 0, old: 0 };
    for (const k of Object.keys(s)) s[k] += o[k];
    rows.push(row(states[c.state].name, c.full, o, c.aland));
  }
  for (const [code, s] of Object.entries(states)) rows.push(row(s.name, '', sum[code], s.aland));
  rows.sort((a, b) => a[0].localeCompare(b[0]) || a[1].localeCompare(b[1]));

  const out = {
    source: `U.S. Census Bureau, Population Estimates Vintage ${year} ( July 1, ${year} )`,
    head: ['state', 'county', 'population', 'density', 'male', 'female', 'under 18', '18-64', '65+', '65+ %', '65+ share'],
    units: { population: 'people', density: '/km²', male: 'people', female: 'people', 'under 18': 'people', '18-64': 'people', '65+': 'people', '65+ %': '%' },
    rows
  };
  fs.mkdirSync(path.join(root, 'src/sample'), { recursive: true });
  const file = path.join(root, 'src/sample/nation.json');
  fs.writeFileSync(file, JSON.stringify(out));
  console.log(`${rows.length} rows ( ${Object.keys(states).length} states ), ${(fs.statSync(file).size / 1024).toFixed(0)}KB -> ${path.relative(root, file)}`);
})().catch((e) => { console.error(e.message); process.exit(1); });
