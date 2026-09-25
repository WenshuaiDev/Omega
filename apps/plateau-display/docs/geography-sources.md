# POV-01 离线地理资产来源与精度

本目录是 2026-09-25 固定的工程样例地理快照。浏览器读取 `public/geography`，不请求地图账号或公网服务。`public/geography/manifest.json` 逐瓦片记录原始 URL、SHA-256、字节数、瓦片坐标及获取日期；`src/geography/data/route-evidence.json` 记录路线 OSM way ID、版本与 11 个按里程分散的控制位置。

| 资产 | 固定来源、授权、署名 | 实际交付分辨率与边界 |
| --- | --- | --- |
| 青藏/青康道路 | [Geofabrik Qinghai/Tibet OSM 提取包](https://download.geofabrik.de/asia/china.html)，2026-09-25 快照；© OpenStreetMap contributors，ODbL 1.0，[署名与再分发条件](https://www.openstreetmap.org/copyright)。来源 PBF SHA-256：Qinghai `7c0f556968d70404362546e9644940789eab5cb35d01af0494f47f6c874474d9`；Tibet `ae840555e45a035a828644d087fb7750b9f4c1d39f3183d1af7c5295de1be8aa`。 | G109 格尔木附近至那曲城郊道路标记末端，823.6 km/5166 顶点；G214 共和至玉树附近 674.9 km/4987 顶点。G214 在 OSM 无 `ref` 的 trunk way `45872603` 上连续连接两个 G214 段。路线是 OSM 道路几何，不是测绘成果；G109 不把那曲市区非 G109 道路伪称为国道。 |
| 卫星影像 | [EOxCloudless 2016 Sentinel-2 WMTS](https://tiles.maps.eox.at/wmts/1.0.0/WMTSCapabilities.xml) 的 `s2cloudless_3857` 图层；[EOX 授权说明](https://cloudless.eox.at/pricing)确认 2016 数据为 CC BY 4.0。署名：EOxCloudless by EOX IT Services GmbH; Contains modified Copernicus Sentinel data 2016。 | 原始拼接影像标称 10 m；交付区域概览 z9 在 34°N 约 250 m/像素，走廊稀疏带 z10–11 约 125–63 m/像素，七处局部影像 z12–14 在 34°N 约 32–8 m/瓦片像素。z14 不能被解释为比 10 m 原始影像更细。影像为 2016 拼接，不是实时卫星。 |
| 地形 | [Mapzen/Tilezen Terrain Tiles](https://registry.opendata.aws/terrain-tiles/) Terrarium PNG；[源数据与层级说明](https://github.com/tilezen/joerd/blob/master/docs/data-sources.md)表明青藏高原陆地区域中高 zoom 主要来自 SRTM，低 zoom 来自 GMTED/ETOPO1；[署名要求](https://github.com/tilezen/joerd/blob/master/docs/attribution.md)。署名：Mapzen/Tilezen；SRTM/GMTED2010 data courtesy of the U.S. Geological Survey；global ETOPO1 terrain data U.S. National Oceanic and Atmospheric Administration。 | Mapzen 文档将 SRTM 源列为 30 m 采样、约 90 m 名义质量；本包概览 z8 在 34°N 约 500 m/像素，走廊 z9–10 约 250–125 m/像素，七处局部 z11–12 约 63–32 m/像素。Terrarium RGB 的 1/256 m 是**编码步长**，不是空间精度。该来源替代规格首选 Copernicus DEM；不宣称 Copernicus GLO-90/GLO-30 高程。 |
| 三场范围和站区 | 本工程确定性模拟布设；WGS84 GeoJSON；无第三方许可。 | 六处 Polygon 是演示范围，不是实际建设边界。花石峡站区点位也是样例定位，不是站房实测坐标。 |

影像与地形瓦片采用 EPSG:3857 Web Mercator `z/x/y`；目录中的路线/范围采用 WGS84 经度、纬度顺序（EPSG:4326）。Mapzen 来源高程的原始垂直基准未由本工程转换为 Cesium 椭球高；地形仅用于可视表达，设施标记以贴地方式渲染，不能据此推算真实海拔或埋深。离线超出瓦片覆盖及 10 m 有效影像细节的区域应维持较低级别底图并提示进入工程样例模型，不可将插值或纹理放大称作新增地理细节。

## 重建与核验

1. 用上述 Geofabrik 2026-09-25 PBF 固定文件及 SHA-256 核对输入；`python tools/build_routes.py qinghai.osm.pbf tibet.osm.pbf` 可重建道路、范围及控制点（准备环境需 `osmium networkx pyproj`）。其结果可再分发时仍须遵守 ODbL。
2. `python tools/fetch_geography.py` 获取 88–104°E、29–39°N 概览影像与地形；`python tools/fetch_detail.py` 获取沿两廊及七处局部的稀疏高层级瓦片。二者是**构建准备工具**，播放时不用执行。
3. 运行 `python tools/verify_geography.py` 检查 manifest 中每个瓦片的存在、字节数、SHA-256、PNG/JPEG 文件头、路线连续性及 Polygon 有效性。初次运行/清空浏览器存储后，本地静态服务即可供应全部已打包资源。

当前覆盖没有高分辨率影像与地形的连续全廊带，也没有逐景 Sentinel-2 COG 的 10 m 原始影像/日期/云量核验；局部 z14 是 EOxCloudless 2016 拼接产品。地图近景只应进入已覆盖的七处局部，其他位置应保持较低层级或引导工程模型。AC-02/03/21 的最终浏览器验收仍须按完整应用、断网与原尺寸画面验证，不能仅由本资产清单宣布通过。
