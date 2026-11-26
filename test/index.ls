# usmapadv 的 test case ( @makechart/viewer 的 mctest )
# 資料大多來自範例資料 ( dist/sample/nation.json, sample() 依 level 取全國或單一州 )
# 載不到時是空資料, 地圖照樣畫得出來, 所以要檢查
sample = (fn) -> (c) -> c.mod.sample!then (d) ->
  if d.raw.length < 5 => throw new Error("範例資料只有 #{d.raw.length} 列")
  if fn => fn d
  c.set-raw d.raw, d.binding

# 只留州 ( county 欄空白 ) / 只留 county
states-only = (d) !-> d.raw = d.raw.filter (r) -> !r.county
counties-only = (d) !-> d.raw = d.raw.filter (r) -> r.county
# 人口密度: 跨好幾個數量級
density = (d) !-> d.binding.value = {key: \density, unit: \/km²}

# 用地圖上的單位造資料 ( 名稱以外的寫法 ), 值用固定種子的亂數. 全國圖預設用 county, upper 時用州
from-geo = (key, seed = 1, upper = false) -> (c) ->
  r = mctest.random seed
  list = if c.geo.national and !upper => c.geo.villages else c.geo.towns
  raw = list.map (f) -> {key: key(f), val: Math.round(r! * 1000) / 10}
  c.set-raw raw, {town: {key: \key}, value: {key: \val, unit: \%}}

# parse 之後對到幾個單位 ( 名稱比對 )
matched = (n) -> (c) ->
  k = [k for k of c.rec].length
  if k < n => throw new Error("只對到 #k 個單位, 應有 #n 個以上")

# 點上層的單位 ( 州或 county 的 FIPS )
click = (code, shift = false) -> (c, ctx) ->
  n = c.node[code].top
  n.dispatchEvent new MouseEvent(\click, {bubbles: true, shift-key: shift})

click-village = (idx) -> (c, ctx) ->
  n = ctx.root.querySelectorAll('g.unit.village:not([style*=none]) path.top')[idx]
  n.dispatchEvent new MouseEvent(\click, {bubbles: true})

interactions-is = (want) -> (c) ->
  got = JSON.stringify c.interactions!
  if got != JSON.stringify(want) => throw new Error("interactions: #got, 應為 #{JSON.stringify want}")

mctest.suite do
  size: [600, 400]
  normalize: [[/tmap-grad-[a-z0-9]+/g, "tmap-grad-x"], [/tmap-clip-[a-z0-9]+/g, "tmap-clip-x"]]
  # 資料在 steps 裡載入 ( 範例資料 ), 一開始是空的
  data: empty: {raw: [], binding: {}}
  cases:
    # ---- 全國 ( 預設 level: nation ): 州 > county
    * name: "nation", steps: [sample!]
    * name: "nation:cat", config: {color-by: \cat}, steps: [sample!]
    * name: "nation:density-log", config: {heat: {scale: \log}}, steps: [sample(density)]
    * name: "nation:quantile-steps", config: {heat: {scale: \quantile, steps: 5}}, steps: [sample!]
    * name: "nation:states-only", steps: [sample(states-only)]
    # 沒有州的列: 由 county 匯總 ( 值是百分比, 取平均 )
    * name: "nation:aggregate", config: {village: {aggregate: \mean}}, steps: [sample(counties-only)]
    * name: "nation:counties", config: {village: {mode: \all}, border: {village: {width: 0.2}}}, steps: [sample!]
    * name: "nation:counties-quantile", config: {village: {mode: \all}, heat: {scale: \quantile}, border: {village: {width: 0}}}, steps: [sample!]
    * name: "nation:cartogram", config: {mode: \cartogram}, steps: [sample!]
    * name: "nation:extrude", config: {extrude: {enabled: true, rotate: \none}}, steps: [sample!]
    * name: "nation:bubble", config: {mode: \bubble}, steps: [sample!]
    * name: "nation:bubble-counties", config: {mode: \bubble, village: {mode: \all}, bubble: {pie: \none}}, steps: [sample!]
    * name: "nation:legend-bottom", config: {legend: {position: \bottom}}, steps: [sample!]
    * name: "nation:click", steps: [sample!, click('06')]
    * name: "nation:click-shift", steps: [sample!, click('06'), click('36', true)]
    * name: "nation:zoom", config: {village: {zoom: true}}, steps: [sample!, click('06')]
    * name: "nation:interactions", config: {filter-level: \village}, steps: [sample!, interactions-is {click: <[town village]>}]
    * name: "nation:filter-emit"
      config: {filter-level: \village}
      steps:
        sample!
        (c, ctx) ->
          c._mctest-filter = []
          c.on \filter, -> c._mctest-filter.push it
          click('06')(c, ctx)
        click-village(3)
        (c) ->
          f = c._mctest-filter[* - 1]
          if !(f and f.village and f.village.value.length == 1 and f.town and f.town.value.length) =>
            throw new Error("點 county 之後沒有發 county 的 filter")
    # 州名寫法: 縮寫 / FIPS ( 數字, 少了開頭的 0 )
    * name: "nation:usps", steps: [from-geo((-> it.abbr), 2, true), matched(52)]
    * name: "nation:fips", steps: [from-geo((-> +it.code), 3), matched(3000)]
    # 一欄 "<county>, <州>" ( ACS 的 NAME )
    * name: "nation:county-state", steps: [from-geo((-> "#{it.full}, #{it.town}"), 4), matched(3200)]

    # ---- 單一州: 只有 county 一層
    * name: "state:CA", block: {level: 'state/CA'}, steps: [sample!, matched(58)]
    * name: "state:by-name", block: {level: 'state/new york'}, steps: [sample!, matched(62)]
    * name: "state:by-fips", block: {level: 'state/48'}, config: {heat: {scale: \log}}, steps: [sample(density), matched(254)]
    # 阿拉斯加: 阿留申群島跨換日線
    * name: "state:AK", block: {level: 'state/AK'}, steps: [sample!]
    * name: "state:HI", block: {level: 'state/HI'}, config: {mode: \bubble}, steps: [sample!]
    * name: "state:PR", block: {level: 'state/PR'}, config: {mode: \cartogram}, steps: [sample!]
    # Baltimore County 與 Baltimore city 同名; 不帶字尾算 county
    * name: "state:MD-names", block: {level: 'state/MD'}
      steps:
        (c) ->
          c.set-raw [{n: \Baltimore, v: 1}, {n: "Baltimore city", v: 2}, {n: "Prince George's", v: 3}], {town: {key: \n}, value: {key: \v}}
        (c) ->
          got = Object.fromEntries [[code, r.value] for code, r of c.rec]
          want = {"24005": 1, "24510": 2, "24033": 3}
          if JSON.stringify(got) != JSON.stringify(want) => throw new Error("對到 #{JSON.stringify got}")
    # 維吉尼亞的獨立市 ( 只有 city 的不帶字尾也認得 )
    * name: "state:VA", block: {level: 'state/VA'}, steps: [sample!, matched(133)]
    * name: "state:extrude", block: {level: 'state/CA'}, config: {extrude: {enabled: true, rotate: \none}}, steps: [sample!]
    * name: "state:click", block: {level: 'state/CA'}, steps: [sample!, click('06037')]
    # 屬地: 沒有範例資料, 只畫地圖
    * name: "state:GU", block: {level: 'state/GU'}
