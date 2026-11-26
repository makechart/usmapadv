#!/usr/bin/env node
// 下載 Census Cartographic Boundary 的 county 界 ( 1:500k ), 解壓到 .cache/<年>/
//
//   node tool/fetch.js [年]          # 預設 2025
//
// 來源: https://www.census.gov/geographies/mapping-files/time-series/geo/cartographic-boundary.html
// 只下載 county: 州界由 county 合成 ( tool/map.js ), 兩層共用 arc, 界線才對得上.
// 檔案已存在就不重抓. tool/map.js 會先呼叫它
const fs = require('fs');
const path = require('path');
const https = require('https');
const { execFileSync } = require('child_process');

const download = (url, out) => new Promise((res, rej) => {
  https.get(url, (r) => {
    if (r.statusCode !== 200) return rej(new Error(`${r.statusCode} ${url}`));
    const f = fs.createWriteStream(out);
    r.pipe(f);
    f.on('finish', () => f.close(res));
  }).on('error', rej);
});

const fetch = async (year) => {
  const name = `cb_${year}_us_county_500k`;
  const dir = path.join(__dirname, '..', '.cache', year);
  const zip = path.join(dir, `${name}.zip`);
  const url = `https://www2.census.gov/geo/tiger/GENZ${year}/shp/${name}.zip`;
  fs.mkdirSync(dir, { recursive: true });
  if (!fs.existsSync(path.join(dir, `${name}.shp`))) {
    if (!fs.existsSync(zip)) {
      console.log(`download ${url} ...`);
      await download(url, zip + '.part');
      fs.renameSync(zip + '.part', zip);
    }
    execFileSync('unzip', ['-o', '-q', zip, '-d', dir]);
  }
  return path.join(dir, `${name}.shp`);
};

module.exports = fetch;
module.exports.download = download;
if (require.main === module) {
  fetch(process.argv[2] || '2025')
    .then((f) => console.log(`ok: ${f}`))
    .catch((e) => { console.error(e.message); process.exit(1); });
}
