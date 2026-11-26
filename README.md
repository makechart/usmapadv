# @makechart/usmapadv

美國全國 ( 州 / county ) 與各州 ( county ) 的地圖。由 `@makechart/twmapadv` 移植, 畫法、設定與 twmapadv 相同,
只有地圖的來源與名稱比對不同 ( `src/index.ls` 的 `load-geo` ).

block data `level` 決定畫哪一張 ( 程式、維度與設定裡上層一律叫 `town`、下層 `village`, 與 twmapadv 相同 ):

| level | 上層 / 下層 | 地圖檔 |
| --- | --- | --- |
| `nation` ( 預設 ) | 州 / county | `map/nation.json`: 50 州 + DC + PR, Albers USA, 阿拉斯加、夏威夷、波多黎各在左下 |
| `state/<州>` | county ( 只有一層 ) | `map/state/<USPS>.json`: 該州自己的等積圓錐投影. 州可以是縮寫 ( `CA` )、州名 ( `new york` ) 或 FIPS ( `06` ) |

GU、VI、AS、MP 只有州圖, 不在全國圖裡.


## 資料

| 維度 | 型別 | 說明 |
| --- | --- | --- |
| `town` | N | 全國: 州名、縮寫或 FIPS; 州圖: county. 也可以是 5 碼 county FIPS ( 數字也行, `6037` ) 或 `Los Angeles County, California` |
| `village` | N | 全國才有: county 名或 FIPS. 空白或 `total` / `all` / `statewide` 的那一列就是州的值 |
| `value` / `size` / `cat` / `parts` | | 同 twmapadv |

county 名稱比對不分大小寫、重音與標點 ( `Dona Ana` = `Doña Ana`, `St Louis` = `St. Louis` ),
`County` / `Parish` / `Borough` / `Census Area` / `Municipio` / `Planning Region` 等字尾可省略.
同州有同名的 county 與獨立市 ( `Baltimore County` / `Baltimore city` ) 時, 不帶字尾的算 county.


## 地圖資料

    npm run data -- 2025      # 年份可省略

下載 Census Cartographic Boundary 的 county 界 ( `cb_<年>_us_county_500k`, 快取在 `.cache/` ), 產生 `src/map/`:
投影在這裡先做完 ( 平面座標, 寬 1000 ), 州界由 county 合成、與 county 共用 arc. 見 `tool/map.js`.


## 範例資料

    npm run sample -- 2025    # 人口估計的 vintage, 可省略. 要先有 src/map ( 面積取自它 )

`src/sample/nation.json`: Census Population Estimates 的 county 年齡、性別 ( `cc-est<年>-agesex-all.csv`
與波多黎各的 `-72.csv`, 不需要 API key ), 每個 county 一列, 每州一列 ( 加總 ). 州圖從同一個檔取該州的列.
county 代碼與地圖對不上時會停下來.


## 測試

    npm run build && npm test
    npm run test:dev:serve    # 連本地的 base / @plotdb/chart, UI 與 /playground

州名標縮寫; `label.fit` ( 預設開 ) 時放不下名稱的區塊不標.
