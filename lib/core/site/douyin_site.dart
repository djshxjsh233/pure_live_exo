import 'dart:convert';
import 'dart:math' as math;
import 'package:pure_live/common/index.dart';
import 'package:pure_live/model/live_category.dart';
import 'package:pure_live/core/common/core_log.dart';
import 'package:pure_live/model/live_anchor_item.dart';
import 'package:pure_live/core/common/http_client.dart';
import 'package:pure_live/model/live_play_quality.dart';
import 'package:pure_live/core/scripts/douyin_sign.dart';
import 'package:pure_live/core/interface/live_site.dart';
import 'package:pure_live/core/common/convert_helper.dart';
import 'package:pure_live/core/danmaku/douyin_danmaku.dart';
import 'package:pure_live/core/interface/live_danmaku.dart';
import 'package:pure_live/core/utils/douyin/douyin_request_params.dart';

class DouyinSite implements LiveSite {
  @override
  String id = "douyin";

  @override
  String name = "抖音直播";

  @override
  LiveDanmaku getDanmaku() => DouyinDanmaku();

  /// 使用 QQBrowser User-Agent（参考 DouyinLiveRecorder）
  static const String kDefaultUserAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36";

  static const String kDefaultReferer = "https://live.douyin.com";

  static const String kDefaultAuthority = "live.douyin.com";

  static const String kDefaultCookie =
      "ttwid=1%7CB1qls3GdnZhUov9o2NxOMxxYS2ff6OSvEWbv0ytbES4%7C1680522049%7C280d802d6d478e3e78d0c807f7c487e7ffec0ae4e5fdd6a0fe74c3c6af149511";

  /// 用户设置的 cookie
  static String cookie = "";

  /// 动态获取的新鲜 cookie（模拟浏览器首次访问，置顶优先级高于内置兜底）
  static String _dynamicCookie = "";
  static DateTime? _dynamicCookieTime;

  /// 最近一次响应头下发的合法 msToken（服务端签发，风控分数低）
  static String _serverMsToken = "";

  /// web_rid → 真实房间 id_str 缓存（浏览器进房必带 room_id_str，贴近此行为可降低风控）
  static final Map<String, String> _webRidRoomIdCache = {};

  /// web_rid → 完整房间数据缓存（含 stream_url）。来源：列表接口/HTML页面/enter API
  /// 仅作元数据/流地址复用（房间号映射供弹幕与room_id_str），进房状态一律实时获取不读缓存
  static final Map<String, MapEntry<DateTime, Map>> _roomInfoCache = {};

  /// 动态 cookie 有效时长（ttwid 一般有效一年，这里保守点 30 分钟刷新一次）
  static const Duration _dynamicCookieLifetime = Duration(minutes: 30);

  Map<String, dynamic> headers = {
    "Authority": kDefaultAuthority,
    "Referer": kDefaultReferer,
    "User-Agent": kDefaultUserAgent,
  };

  /// 强制/按需刷新动态 cookie：HEAD live.douyin.com 拿 Set-Cookie（ttwid、__ac_nonce、msToken 等）
  Future<String> _refreshDynamicCookie({bool force = false}) async {
    try {
      final now = DateTime.now();
      if (!force &&
          _dynamicCookie.isNotEmpty &&
          _dynamicCookieTime != null &&
          now.difference(_dynamicCookieTime!) < _dynamicCookieLifetime) {
        return _dynamicCookie;
      }
      final headResp = await HttpClient.instance.head(
        "https://live.douyin.com/?from_nav=1",
        header: {
          "Authority": kDefaultAuthority,
          "Referer": kDefaultReferer,
          "User-Agent": kDefaultUserAgent,
          "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        },
      );
      var dyCookie = "";
      headResp.headers["set-cookie"]?.forEach((element) {
        final raw = element.trim();
        if (raw.isEmpty) return;
        final cookie = raw.split(";")[0].trim();
        if (cookie.startsWith("ttwid=") ||
            cookie.startsWith("__ac_nonce=") ||
            cookie.startsWith("msToken=")) {
          dyCookie += "$cookie;";
        }
      });
      if (dyCookie.isNotEmpty) {
        _dynamicCookie = dyCookie;
        _dynamicCookieTime = now;
        // 注意：不覆盖全局 cookie，仅作为进房失败重试时的临时会话（避免影响列表请求稳定性）
        CoreLog.i("douyin 动态cookie已刷新(${dyCookie.length}字节)");
      } else {
        CoreLog.w("douyin 动态cookie刷新无结果，沿用旧值");
      }
      return _dynamicCookie;
    } catch (e) {
      CoreLog.error("douyin 刷新动态cookie失败: $e");
      return _dynamicCookie;
    }
  }

  Future<Map<String, dynamic>> getRequestHeaders() async {
    // 注意：列表/进房请求全部保持原行为（用户cookie → 设置cookie → 内置ttwid），
    // 实测动态 cookie/msToken 拼接在部分网络下会触发风控444，仅进房失败重试时才强制刷新。
    try {
      if (cookie.isNotEmpty) {
        headers["cookie"] = cookie;
        return headers;
      } else if (SettingsService.to.cookieManager.douyinCookie.v.isNotEmpty) {
        cookie = SettingsService.to.cookieManager.douyinCookie.v;
        headers["cookie"] = cookie;
        return headers;
      }

      headers["cookie"] = kDefaultCookie;
      return headers;
    } catch (e) {
      CoreLog.error(e);
      if (!(headers["cookie"]?.toString().isNotEmpty ?? false)) {
        headers["cookie"] = kDefaultCookie;
      }
      return headers;
    }
  }

  Future<Map<String, dynamic>> getUserInfoByCookie(String cookie) async {
    try {
      final url = "https://live.douyin.com/webcast/user/me/";
      final result = await HttpClient.instance.getJson(
        url,
        queryParameters: {"aid": DouyinRequestParams.aidValue},
        header: {
          "user-agent": DouyinRequestParams.kDefaultUserAgent,
          'accept': 'application/json, text/plain, */*',
          'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8',
          "Cookie": cookie,
        },
      );
      if (result is Map<String, dynamic>) {
        final data = result["data"];
        if (data is Map<String, dynamic>) {
          return data;
        }
      }
      return {};
    } catch (e) {
      CoreLog.error(e);
    }
    return {};
  }

  String extractCategoryDataJson(String source) {
    final startPattern = r'{\"pathname\":\"/\",\"categoryData\":';
    int startIndex = source.indexOf(startPattern);
    if (startIndex == -1) return '';
    int openBraces = 0;
    bool foundFirstBrace = false;
    for (int i = startIndex; i < source.length; i++) {
      if (source[i] == '{') {
        openBraces++;
        foundFirstBrace = true;
      } else if (source[i] == '}') {
        openBraces--;
      }
      if (foundFirstBrace && openBraces == 0) {
        String rawData = source.substring(startIndex, i + 1);
        return rawData.replaceAll('\\"', '"').replaceAll(r'\\', r'\');
      }
    }
    return '';
  }

  @override
  Future<List<LiveCategory>> getCategores(int page, int pageSize) async {
    // 首页分类树偶发返回残缺/失败：重试3次（每次重新拉取首页HTML）
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        return await _fetchCategoriesOnce();
      } catch (e) {
        if (attempt >= 3) {
          CoreLog.error("douyin 分类树获取失败(3次): $e");
          return [];
        }
        CoreLog.w("douyin 分类树第${attempt}次失败，重试: $e");
        await Future.delayed(Duration(milliseconds: 500 * attempt));
      }
    }
    return [];
  }

  Future<List<LiveCategory>> _fetchCategoriesOnce() async {
    List<LiveCategory> categories = [];
    var result = await HttpClient.instance.getText(
      "https://live.douyin.com/",
      queryParameters: {"from_nav": "1"},
      header: await getRequestHeaders(),
    );

    String extracted = extractCategoryDataJson(result);
    if (extracted.isEmpty) {
      throw Exception("首页无 categoryData(可能被风控)");
    }
    var renderDataJson = json.decode(extracted);
    var data = renderDataJson["categoryData"];
    if (data is! List || data.isEmpty) {
      throw Exception("categoryData 为空");
    }

    // 递归解析：把每个 partition 及其嵌套的 sub_partition 转成 LiveArea
    LiveArea parseArea(dynamic node) {
      var partition = node["partition"];
      var id = '${partition["id_str"]},${partition["type"]}';
      var name = asT<String?>(partition["title"]) ?? '';
      var subList = node["sub_partition"] as List? ?? [];
      return LiveArea(
        areaId: id,
        typeName: name,
        areaType: id,
        areaName: name,
        areaPic: "",
        platform: Sites.douyinSite,
        children: subList.isEmpty
            ? null
            : subList.map((sub) => parseArea(sub)).toList(),
      );
    }

    for (var item in data) {
      List<LiveArea> categories_ = [];
      var subList = item["sub_partition"] as List? ?? [];
      for (var subItem in subList) {
        categories_.add(parseArea(subItem));
      }
      var pid = '${item["partition"]["id_str"]},${item["partition"]["type"]}';
      var pname = asT<String?>(item["partition"]["title"]) ?? "";
      // 在首位插入顶级分类自身：让无子分区的一级分类(如聊天/音乐/文化)也能进入直播间
      categories_.insert(
        0,
        LiveArea(
          areaId: pid,
          typeName: pname,
          areaType: pid,
          areaName: pname,
          areaPic: "",
          platform: Sites.douyinSite,
        ),
      );
      var category = LiveCategory(children: categories_, id: pid, name: pname);
      categories.add(category);
    }
    return categories;
  }

  @override
  Future<List<LiveRoom>> getCategoryRooms(LiveArea category, {int page = 1, int pageSize = 30}) async {
    var ids = category.areaId?.split(',');
    var partitionId = ids?[0];
    var partitionType = ids?[1];
    // 分区接口偶发被风控：失败自动重试（每次重新生成abogus/msToken，间隔递增）
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final items = await _fetchCategoryRoomsOnce(partitionId, partitionType, page, pageSize);
        return items;
      } catch (e) {
        if (attempt >= 3) {
          CoreLog.error("douyin 分区房间获取失败(3次): $e");
          return [];
        }
        CoreLog.w("douyin 分区房间第${attempt}次失败，重试: $e");
        await Future.delayed(Duration(milliseconds: 500 * attempt));
      }
    }
    return [];
  }

  Future<List<LiveRoom>> _fetchCategoryRoomsOnce(
      String? partitionId, String? partitionType, int page, int pageSize) async {
    String serverUrl = "https://live.douyin.com/webcast/web/partition/detail/room/v2/";
    var uri = Uri.parse(serverUrl).replace(
      scheme: "https",
      port: 443,
      queryParameters: {
        "aid": '6383',
        "app_name": "douyin_web",
        "live_id": '1',
        "device_platform": "web",
        "language": "zh-CN",
        "enter_from": "link_share",
        "cookie_enabled": "true",
        "screen_width": "1536",
        "screen_height": "864",
        "browser_language": "zh-CN",
        "browser_platform": "Win32",
        "browser_name": "Chrome",
        "browser_version": "125.0.0.0",
        "browser_online": "true",
        "count": '$pageSize',
        "offset": ((page - 1) * pageSize).toString(),
        "partition": partitionId,
        "partition_type": partitionType,
        "req_from": '2',
      },
    );
    var requestUrl = DouyinSign.getAbogusUrl(uri.toString(), kDefaultUserAgent);
    var result = await HttpClient.instance.getJson(requestUrl, header: await getRequestHeaders());
    var items = <LiveRoom>[];
    for (var item in result["data"]["data"]) {
      // 记录真实房间ID，进房时将 room_id_str 带上（贴近浏览器行为，降低风控）
      _webRidRoomIdCache[item["web_rid"].toString()] = item["room"]?["id_str"]?.toString() ?? "";
      if (item["room"] is Map && (item["room"] as Map).isNotEmpty) {
        _roomInfoCache[item["web_rid"].toString()] =
            MapEntry(DateTime.now(), item["room"] as Map);
      }
      var roomItem = LiveRoom(
        roomId: item["web_rid"],
        title: item["room"]["title"].toString(),
        cover: item["room"]["cover"]["url_list"][0].toString(),
        nick: item["room"]["owner"]["nickname"].toString(),
        liveStatus: LiveStatus.live,
        avatar: item["room"]["owner"]["avatar_thumb"]["url_list"][0].toString(),
        status: true,
        platform: Sites.douyinSite,
        area: item['tag_name'].toString(),
        watching: item["room"]?["room_view_stats"]?["display_value"].toString() ?? '',
      );
      items.add(roomItem);
    }
    return items;
  }

  @override
  Future<List<LiveRoom>> getRecommendRooms({int page = 1, int pageSize = 30}) async {
    try {
      String serverUrl = "https://live.douyin.com/webcast/web/partition/detail/room/v2/";
      var uri = Uri.parse(serverUrl).replace(
        scheme: "https",
        port: 443,
        queryParameters: {
          "aid": '6383',
          "app_name": "douyin_web",
          "live_id": '1',
          "device_platform": "web",
          "language": "zh-CN",
          "enter_from": "link_share",
          "cookie_enabled": "true",
          "screen_width": "1536",
          "screen_height": "864",
          "browser_language": "zh-CN",
          "browser_platform": "Win32",
          "browser_name": "Chrome",
          "browser_version": "125.0.0.0",
          "browser_online": "true",
          "count": '20',
          "offset": ((page - 1) * 20).toString(),
          "partition": '720',
          "partition_type": '1',
          "req_from": '2',
        },
      );
      var requestUrl = DouyinSign.getAbogusUrl(uri.toString(), kDefaultUserAgent);
      var result = await HttpClient.instance.getJson(requestUrl, header: await getRequestHeaders());
      var items = <LiveRoom>[];
      for (var item in result["data"]["data"]) {
        // 记录真实房间ID，进房时将 room_id_str 带上（贴近浏览器行为，降低风控）
        _webRidRoomIdCache[item["web_rid"].toString()] = item["room"]?["id_str"]?.toString() ?? "";
      if (item["room"] is Map && (item["room"] as Map).isNotEmpty) {
        _roomInfoCache[item["web_rid"].toString()] =
            MapEntry(DateTime.now(), item["room"] as Map);
      }
        var roomItem = LiveRoom(
          roomId: item["web_rid"],
          title: item["room"]["title"].toString(),
          cover: item["room"]["cover"]["url_list"][0].toString(),
          nick: item["room"]["owner"]["nickname"].toString(),
          platform: Sites.douyinSite,
          area: item["tag_name"] ?? '热门推荐',
          avatar: item["room"]["owner"]["avatar_thumb"]["url_list"][0].toString(),
          watching: item["room"]?["room_view_stats"]?["display_value"].toString() ?? '',
          liveStatus: LiveStatus.live,
        );
        items.add(roomItem);
      }
      return items;
    } catch (e) {
      throw Exception(e.toString());
    }
  }

  @override
  Future<LiveRoom> getRoomDetail({required String platform, required String roomId}) async {
    if (roomId.length <= 16) {
      return await getRoomDetailByWebRid(roomId);
    }
    return await getRoomDetailByRoomId(roomId);
  }

  Future<LiveRoom> getRoomDetailByRoomId(String roomId) async {
    // 读取房间信息
    var roomData = await _getRoomDataByRoomId(roomId);

    // 通过房间信息获取WebRid
    var webRid = roomData["data"]["room"]["owner"]["web_rid"].toString();

    // 读取用户唯一ID，用于弹幕连接
    // 似乎这个参数不是必须的，先随机生成一个
    //var userUniqueId = await _getUserUniqueId(webRid);
    var userUniqueId = generateRandomNumber(12).toString();

    var room = roomData["data"]["room"];
    var owner = room["owner"];

    var status = asT<int?>(room["status"]) ?? 0;

    // roomId是一次性的，用户每次重新开播都会生成一个新的roomId
    // 所以如果roomId对应的直播间状态不是直播中，就通过webRid获取直播间信息
    if (status == 4) {
      var result = await getRoomDetailByWebRid(webRid);
      return result;
    }

    var roomStatus = status == 2;
    // 主要是为了获取cookie,用于弹幕websocket连接
    var headers = await getRequestHeaders();

    return LiveRoom(
      roomId: webRid,
      title: room["title"].toString(),
      cover: roomStatus ? room["cover"]["url_list"][0].toString() : "",
      nick: owner["nickname"].toString(),
      avatar: owner["avatar_thumb"]["url_list"][0].toString(),
      watching: roomStatus ? room["room_view_stats"]["display_value"].toString() : "",
      status: roomStatus,
      link: "https://live.douyin.com/$webRid",
      platform: Sites.douyinSite,
      area: '',
      userId: owner["sec_uid"].toString(),
      liveStatus: roomStatus ? LiveStatus.live : LiveStatus.offline,
      introduction: owner["signature"].toString(),
      notice: "",
      danmakuData: DouyinDanmakuArgs(webRid: webRid, roomId: roomId, userId: userUniqueId, cookie: headers["cookie"]),
      data: room["stream_url"],
    );
  }

  /// 通过WebRid获取直播间信息
  /// - [webRid] 直播间RID
  /// - 返回直播间信息
  /// - 容错策略：API(abogus签名) → 强刷cookie重试API(防偶发风控) → HTML页面解析兜底
  Future<LiveRoom> getRoomDetailByWebRid(String webRid) async {
    // ⚡ 进房=实时获取（用户要求，浏览器式"打开网页"，不读状态缓存）
    // ① 先确保会话 cookie 新鲜：2023年写死的内置 ttwid 风控识别度高，浏览器每次访问都带新 ttwid
    await _refreshDynamicCookie(force: true);
    // ② 双通道 × 3 轮自动重试，退避间隔递增（400ms→1.5s→3s）
    //    抖音单房间风控是"短暂时间窗"(几十秒)：两轮撞同一窗口=全失败；拉开间隔等窗口过去+换随机token即可恢复
    const delays = [Duration(milliseconds: 400), Duration(milliseconds: 1500), Duration(milliseconds: 3000)];
    for (var round = 1; round <= 3; round++) {
      try {
        return await _getRoomDetailByWebRidHtml(webRid);
      } catch (e) {
        CoreLog.error("douyin HTML获取房间失败(r$round): $e");
      }
      try {
        return await _getRoomDetailByWebRidApi(webRid);
      } catch (e) {
        DouyinSign.clearMsTokenOverride();
        CoreLog.error("douyin enter API获取房间失败(r$round): $e");
      }
      if (round < 3) {
        await Future.delayed(delays[round - 1]);
        await _refreshDynamicCookie(force: true);
      }
    }
    // 双通道三轮全失败：主播未开播/获取失败（状态保持未知，绝不展示过期状态）
    return LiveRoom(
      roomId: webRid,
      platform: Sites.douyinSite,
      liveStatus: LiveStatus.unknown,
    );
  }

  /// 统一由 roomMap 构造 LiveRoom（列表/HTML/enter API 三种来源同构）
  /// [danmakuRoomId] 真实房间id(弹幕用); [fallbackNick]/[fallbackAvatar] 未开播时用user/anchor信息
  LiveRoom _buildLiveRoomFromRoomMap(String webRid, Map room,
      {String? danmakuRoomId,
      String? userUniqueId,
      String? fallbackNick,
      String? fallbackAvatar}) {
    // 防呆：误传非房间数据（如 stream_url 播放地址 map 的脏缓存）时，无法判定状态，返回 unknown
    if (!room.containsKey("status") && !room.containsKey("stream_url")) {
      return LiveRoom(roomId: webRid, platform: Sites.douyinSite, liveStatus: LiveStatus.unknown);
    }
    final status = (room["status"] as num?)?.toInt() ?? 0;
    final streamUrl = room["stream_url"];
    final hasStream = streamUrl is Map && streamUrl.isNotEmpty;
    // partition 列表接口 room.status=0 但 stream_url 有数据=在播，用双条件判定
    final isLive = status == 2 || hasStream;
    final owner = room["owner"] is Map ? room["owner"] as Map : <String, dynamic>{};
    final coverMap = room["cover"];
    String cover = "";
    if (coverMap is Map && coverMap["url_list"] is List && (coverMap["url_list"] as List).isNotEmpty) {
      cover = coverMap["url_list"][0].toString();
    }
    final avatarMap = owner["avatar_thumb"];
    String avatar = "";
    if (avatarMap is Map && avatarMap["url_list"] is List && (avatarMap["url_list"] as List).isNotEmpty) {
      avatar = avatarMap["url_list"][0].toString();
    }
    if (avatar.isEmpty && fallbackAvatar != null) avatar = fallbackAvatar;
    final viewStats = room["room_view_stats"];
    final watching = viewStats is Map ? (viewStats["display_value"]?.toString() ?? '') : '';
    final cookieVal = cookie.isNotEmpty ? cookie : kDefaultCookie;
    return LiveRoom(
      roomId: webRid,
      title: room["title"]?.toString() ?? '',
      cover: cover,
      nick: isLive ? (owner["nickname"]?.toString() ?? (fallbackNick ?? '')) : (fallbackNick ?? ''),
      avatar: avatar,
      watching: watching,
      status: isLive,
      liveStatus: isLive ? LiveStatus.live : LiveStatus.offline,
      link: "https://live.douyin.com/$webRid",
      platform: Sites.douyinSite,
      area: '',
      introduction: owner["signature"]?.toString() ?? "",
      notice: "",
      userId: owner["sec_uid"]?.toString() ?? "",
      danmakuData: DouyinDanmakuArgs(
        webRid: webRid,
        roomId: danmakuRoomId ?? (room["id_str"]?.toString() ?? ""),
        userId: userUniqueId ?? generateRandomNumber(12).toString(),
        cookie: cookieVal,
      ),
      data: streamUrl is Map ? streamUrl : <String, dynamic>{},
    );
  }

  /// 通过WebRid访问直播间API，从API中获取直播间信息
  /// - [webRid] 直播间RID
  /// - 返回直播间信息
  Future<LiveRoom> _getRoomDetailByWebRidApi(String webRid) async {
    final data = await _getRoomDataByApi(webRid);
    final list = data["data"];
    if (list is! List || list.isEmpty) {
      throw Exception("douyin enter API 返回空数据(可能被风控)");
    }
    final roomMap = list[0] is Map ? list[0] as Map : throw Exception("douyin enter API 结构异常");
    final userData = data["user"];
    String fallbackNick = "", fallbackAvatar = "";
    if (userData is Map) {
      fallbackNick = userData["nickname"]?.toString() ?? "";
      final av = userData["avatar_thumb"];
      if (av is Map && av["url_list"] is List && (av["url_list"] as List).isNotEmpty) {
        fallbackAvatar = av["url_list"][0].toString();
      }
    }
    final roomId = roomMap["id_str"]?.toString() ?? "";
    _roomInfoCache[webRid] = MapEntry(DateTime.now(), roomMap);
    _webRidRoomIdCache[webRid] = roomId;
    return _buildLiveRoomFromRoomMap(webRid, roomMap,
        danmakuRoomId: roomId, fallbackNick: fallbackNick, fallbackAvatar: fallbackAvatar);
  }

  /// 通过WebRid访问直播间网页，从网页HTML中获取直播间信息
  /// - [webRid] 直播间RID
  /// - 返回直播间信息
  Future<LiveRoom> _getRoomDetailByWebRidHtml(String webRid) async {
    final detail = await _getRoomDataByHtml(webRid);
    final roomStore = detail["roomStore"];
    final roomInfo = roomStore is Map ? roomStore["roomInfo"] : null;
    final room = roomInfo is Map ? roomInfo["room"] : null;
    if (room is! Map) {
      throw Exception("douyin 房间页缺 room 数据");
    }
    final roomMap = room;
    final realRoomId = roomMap["id_str"]?.toString() ?? "";
    String userUniqueId = "";
    try {
      userUniqueId = detail["userStore"]["odin"]["user_unique_id"].toString();
    } catch (_) {}
    final anchor = roomInfo["anchor"];
    String fallbackNick = "", fallbackAvatar = "";
    if (anchor is Map) {
      fallbackNick = anchor["nickname"]?.toString() ?? "";
      final av = anchor["avatar_thumb"];
      if (av is Map && av["url_list"] is List && (av["url_list"] as List).isNotEmpty) {
        fallbackAvatar = av["url_list"][0].toString();
      }
    }
    _roomInfoCache[webRid] = MapEntry(DateTime.now(), roomMap);
    _webRidRoomIdCache[webRid] = realRoomId;
    return _buildLiveRoomFromRoomMap(webRid, roomMap,
        danmakuRoomId: realRoomId,
        userUniqueId: userUniqueId,
        fallbackNick: fallbackNick,
        fallbackAvatar: fallbackAvatar);
  }

  /// 读取用户的唯一ID
  /// - [webRid] 直播间RID
  // ignore: unused_element
  Future<String> _getUserUniqueId(String webRid) async {
    try {
      var webInfo = await _getRoomDataByHtml(webRid);
      return webInfo["userStore"]["odin"]["user_unique_id"].toString();
    } catch (e) {
      return generateRandomNumber(12).toString();
    }
  }

  /// 进入直播间前需要先获取cookie
  /// - [webRid] 直播间RID
  Future<String> _getWebCookie(String webRid) async {
    // 优先复用全局缓存的动态 cookie（浏览器会话式，长期有效），避免每次都 HEAD 增加风控请求数
    await _refreshDynamicCookie();
    if (_dynamicCookie.isNotEmpty) {
      return _dynamicCookie;
    }
    var headResp = await HttpClient.instance.head("https://live.douyin.com/$webRid", header: headers);
    var dyCookie = "";
    headResp.headers["set-cookie"]?.forEach((element) {
      var cookie = element.split(";")[0];
      if (cookie.contains("ttwid")) {
        dyCookie += "$cookie;";
      }
      if (cookie.contains("__ac_nonce")) {
        dyCookie += "$cookie;";
      }
      if (cookie.contains("msToken")) {
        dyCookie += "$cookie;";
      }
    });
    return dyCookie;
  }

  /// 通过webRid获取直播间Web信息
  /// - [webRid] 直播间RID
  Future<Map> _getRoomDataByHtml(String webRid) async {
    // 浏览器式取网页：依次尝试 新鲜动态cookie → 内置cookie → 无cookie裸请求（浏览器首访同款）
    await _refreshDynamicCookie();
    var baseCookie = _dynamicCookie.isNotEmpty ? _dynamicCookie : kDefaultCookie;
    var cookieWithToken = baseCookie;
    final randomMs = _serverMsToken.isEmpty ? DouyinSign.generateMsToken(120) : _serverMsToken;
    if (!cookieWithToken.contains("msToken=")) {
      cookieWithToken = "$cookieWithToken; msToken=$randomMs;";
    }
    // 变体1：新鲜动态 cookie + msToken（浏览器会话同款）
    try {
      return _parseRoomState(await HttpClient.instance.getText(
        "https://live.douyin.com/$webRid",
        queryParameters: {},
        header: {
          "Authority": kDefaultAuthority,
          "Referer": kDefaultReferer,
          "Cookie": cookieWithToken,
          "User-Agent": kDefaultUserAgent,
        },
      ));
    } catch (e) {
      CoreLog.w("douyin HTML变体1(新cookie)解析失败: $e");
    }
    // 变体2：内置 cookie
    try {
      return _parseRoomState(await HttpClient.instance.getText(
        "https://live.douyin.com/$webRid",
        queryParameters: {},
        header: {
          "Authority": kDefaultAuthority,
          "Referer": kDefaultReferer,
          "Cookie": kDefaultCookie,
          "User-Agent": kDefaultUserAgent,
        },
      ));
    } catch (e) {
      CoreLog.w("douyin HTML变体2(内置cookie)解析失败: $e");
    }
    // 变体3：无 cookie 裸请求（浏览器首次访问无会话同款）
    return _parseRoomState(await HttpClient.instance.getText(
      "https://live.douyin.com/$webRid",
      queryParameters: {},
      header: {
        "Authority": kDefaultAuthority,
        "Referer": kDefaultReferer,
        "User-Agent": kDefaultUserAgent,
      },
    ));
  }

  /// 解析直播间页面 RENDER state（多种存储形态兼容）
  Map _parseRoomState(String html) {
    // 形态1：转义 JSON 的 state（当前 SSR 页面）
    var renderData = RegExp(r'\{\\"state\\":\{\\"appStore.*?\]\\n').firstMatch(html)?.group(0) ?? "";
    if (renderData.isNotEmpty) {
      try {
        var str = renderData.trim().replaceAll('\\"', '"').replaceAll(r"\\", r"\").replaceAll(']\\n', "");
        return json.decode(str)["state"] as Map;
      } catch (e) {
        CoreLog.error("douyin 页面state解析失败: $e");
      }
    }
    // 形态2：RENDER_DATA script（URL编码 JSON）
    final rdMatch = RegExp(r'<script id="RENDER_DATA" type="application\/json">(.*?)<\/script>', dotAll: true)
        .firstMatch(html);
    if (rdMatch != null) {
      try {
        final decoded = Uri.decodeComponent(rdMatch.group(1) ?? "");
        final j = json.decode(decoded);
        return j["app"] is Map ? j["app"] : j["state"] as Map;
      } catch (e) {
        CoreLog.error("douyin RENDER_DATA解析失败: $e");
      }
    }
    throw Exception("douyin 房间页缺少可解析的state数据(可能被风控)");
  }

  /// 通过webRid获取直播间Web信息
  /// - [webRid] 直播间RID
  Future<Map> _getRoomDataByApi(String webRid) async {
    String serverUrl = "https://live.douyin.com/webcast/room/web/enter/";
    var uri = Uri.parse(serverUrl).replace(
      scheme: "https",
      port: 443,
      queryParameters: {
        "aid": '6383',
        "app_name": "douyin_web",
        "live_id": '1',
        "device_platform": "web",
        "enter_from": "link_share",
        "web_rid": webRid,
        "room_id_str": _webRidRoomIdCache[webRid] ?? "",
        "enter_source": "",
        "Room-Enter-User-Login-Ab": '0',
        "is_need_double_stream": 'false',
        "cookie_enabled": 'true',
        "screen_width": "1536",
        "screen_height": "864",
        "browser_language": "zh-CN",
        "browser_platform": "Win32",
        "browser_name": "Chrome",
        "browser_version": "125.0.0.0",
      },
    );
    var requestUrl = DouyinSign.getAbogusUrl(uri.toString(), kDefaultUserAgent, useServerToken: true);
    var requestHeader = await getRequestHeaders();
    // 进房失败重试场景：已强刷出新鲜会话 cookie（ttwid），替换内置默认 cookie 以降低风控
    if (_dynamicCookie.isNotEmpty && requestHeader["cookie"] == kDefaultCookie) {
      requestHeader["cookie"] = _dynamicCookie;
    }
    final response = await HttpClient.instance.get(requestUrl, header: requestHeader);

    // 提取服务端下发的合法 msToken 并缓存：仅进房流程后续请求复用（带5分钟有效期，过期自动失效）
    final msTokenHeader = response.headers.value("x-ms-token");
    if (msTokenHeader != null && msTokenHeader.isNotEmpty) {
      _serverMsToken = msTokenHeader;
      DouyinSign.setMsTokenOverride(msTokenHeader);
    }
    final data = response.data;
    if (data is Map<String, dynamic>) {
      return data["data"];
    }
    throw Exception("douyin enter API 响应异常(可能被风控): $data");
  }

  /// 通过roomId获取直播间信息
  /// - [roomId] 直播间ID
  Future<Map> _getRoomDataByRoomId(String roomId) async {
    var result = await HttpClient.instance.getJson(
      'https://webcast.amemv.com/webcast/room/reflow/info/',
      queryParameters: {
        "type_id": 0,
        "live_id": 1,
        "room_id": roomId,
        "sec_user_id": "",
        "version_code": "99.99.99",
        "app_id": 6383,
      },
      header: await getRequestHeaders(),
    );
    return result;
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({required LiveRoom detail}) async {
    final qualities = <LivePlayQuality>[];
    final data = detail.data;
    if (data == null || data.isEmpty) return qualities;

    try {
      // ---------- 新结构：live_core_sdk_data.pull_data ----------
      final coreSdk = data["live_core_sdk_data"];
      if (coreSdk is Map) {
        final pullData = coreSdk["pull_data"];
        if (pullData is Map) {
          final qulityList = (pullData["options"] is Map
                  ? pullData["options"]["qualities"]
                  : null) as List? ??
              [];
          final streamData = pullData["stream_data"]?.toString() ?? '';

          var qualityData = <String, dynamic>{};
          var parseOk = false;
          if (streamData.startsWith('{')) {
            try {
              final decoded = json.decode(streamData);
              final dd = decoded is Map ? decoded["data"] : null;
              if (dd is Map) {
                qualityData = dd.cast<String, dynamic>();
                parseOk = true;
              }
            } catch (e) {
              CoreLog.error("douyin stream_data JSON解析失败: $e");
            }
          }

          if (parseOk) {
            for (var quality in qulityList) {
              List<String> urls = [];
              final key = quality["sdk_key"];
              if (key == null) continue;
              final entry = qualityData[key];
              if (entry is Map) {
                final main = entry["main"];
                if (main is Map) {
                  // HLS 优先（ExoPlayer 原生支持且为单音轨，规避 FLV 双音轨声音忽大忽小问题）
                  final hlsUrl = main["hls"]?.toString();
                  if (hlsUrl != null && hlsUrl.isNotEmpty) urls.add(hlsUrl);
                  final flvUrl = main["flv"]?.toString();
                  if (flvUrl != null && flvUrl.isNotEmpty) urls.add(flvUrl);
                }
              }
              if (urls.isNotEmpty) {
                qualities.add(LivePlayQuality(
                  quality: quality["name"]?.toString() ?? '',
                  sort: (quality["level"] as num?)?.toInt() ?? 0,
                  data: urls,
                ));
              }
            }
          } else if (data["flv_pull_url"] is Map) {
            // ---------- 老结构：flv_pull_url / hls_pull_url_map ----------
            final flvList = (data["flv_pull_url"] as Map).values.cast<String>().toList();
            final hlsList = (data["hls_pull_url_map"] as Map).values.cast<String>().toList();
            for (var quality in qulityList) {
              int level = (quality["level"] as num?)?.toInt() ?? 0;
              List<String> urls = [];
              var hlsIndex = hlsList.length - level;
              if (hlsIndex >= 0 && hlsIndex < hlsList.length) {
                urls.add(hlsList[hlsIndex]);
              }
              var flvIndex = flvList.length - level;
              if (flvIndex >= 0 && flvIndex < flvList.length) {
                urls.add(flvList[flvIndex]);
              }
              if (urls.isNotEmpty) {
                qualities.add(LivePlayQuality(
                  quality: quality["name"]?.toString() ?? '',
                  sort: level,
                  data: urls,
                ));
              }
            }
          }
        }
      }

      // ---------- 最终兜底：无 live_core_sdk_data 时直接读 flv_pull_url 等 ----------
      if (qualities.isEmpty && data["flv_pull_url"] is Map) {
        final flvMap = data["flv_pull_url"] as Map;
        final hlsMap = data["hls_pull_url_map"] as Map? ?? {};
        // 抖音官方清晰度中文名对照（uhd=蓝光, hd=超清, sd=高清, ld=标清）
        const nameMap = {'FULL_HD1': '蓝光', 'HD1': '超清', 'SD1': '高清', 'SD2': '标清'};
        const levelMap = {'FULL_HD1': 4, 'HD1': 3, 'SD1': 2, 'SD2': 1};
        flvMap.forEach((k, v) {
          final urls = <String>[];
          // HLS 优先
          final hls = hlsMap[k]?.toString();
          if (hls != null && hls.isNotEmpty) urls.add(hls);
          final flv = v?.toString();
          if (flv != null && flv.isNotEmpty) urls.add(flv);
          if (urls.isNotEmpty) {
            final key = k?.toString() ?? '';
            final level = levelMap[key] ?? 0;
            qualities.add(LivePlayQuality(
              quality: nameMap[key] ?? key,
              sort: level,
              data: urls,
            ));
          }
        });
      }
    } catch (e) {
      CoreLog.error("douyin getPlayQualites 解析失败: $e");
    }

    qualities.sort((a, b) => b.sort.compareTo(a.sort));
    return qualities;
  }

  @override
  Future<List<String>> getPlayUrls({required LiveRoom detail, required LivePlayQuality quality}) async {
    return quality.data;
  }

  @override
  Future<List<LiveRoom>> searchRooms(String keyword, {int page = 1, int pageSize = 30}) async {
    String serverUrl = "https://www.douyin.com/aweme/v1/web/live/search/";
    var uri = Uri.parse(serverUrl).replace(
      scheme: "https",
      port: 443,
      queryParameters: {
        "device_platform": "webapp",
        "aid": "6383",
        "channel": "channel_pc_web",
        "search_channel": "aweme_live",
        "keyword": keyword,
        "search_source": "switch_tab",
        "query_correct_type": "1",
        "is_filter_search": "0",
        "from_group_id": "",
        "offset": ((page - 1) * 10).toString(),
        "count": "10",
        "pc_client_type": "1",
        "version_code": "170400",
        "version_name": "17.4.0",
        "cookie_enabled": "true",
        "screen_width": "1536",
        "screen_height": "864",
        "browser_language": "zh-CN",
        "browser_platform": "Win32",
        "browser_name": "Chrome",
        "browser_version": "125.0.0.0",
        "browser_online": "true",
        "engine_name": "Blink",
        "engine_version": "125.0.0.0",
        "os_name": "Windows",
        "os_version": "10",
        "cpu_core_num": "12",
        "device_memory": "8",
        "platform": "PC",
        "downlink": "10",
        "effective_type": "4g",
        "round_trip_time": "100",
        "webid": "7382872326016435738",
      },
    );
    var requlestUrl = uri.toString();
    var headResp = await getRequestHeaders();
    var dyCookie = headResp['cookie'];
    var result = await HttpClient.instance.getJson(
      requlestUrl,
      queryParameters: {},
      header: {
        "Authority": 'www.douyin.com',
        'accept': 'application/json, text/plain, */*',
        'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8',
        'cookie': dyCookie,
        'priority': 'u=1, i',
        'referer': 'https://www.douyin.com/search/${Uri.encodeComponent(keyword)}?type=live',
        'sec-ch-ua': '"Microsoft Edge";v="125", "Chromium";v="125", "Not.A/Brand";v="24"',
        'sec-ch-ua-mobile': '?0',
        'sec-ch-ua-platform': '"Windows"',
        'sec-fetch-dest': 'empty',
        'sec-fetch-mode': 'cors',
        'sec-fetch-site': 'same-origin',
        'user-agent': DouyinRequestParams.kDefaultUserAgent,
      },
    );
    if (result == "" || result == 'blocked') {
      throw Exception("抖音直播搜索被限制，请稍后再试");
    }
    var items = <LiveRoom>[];
    for (var item in result["data"] ?? []) {
      var itemData = json.decode(item["lives"]["rawdata"].toString());
      var roomStatus = (asT<int?>(itemData["status"]) ?? 0) == 2;
      var roomItem = LiveRoom(
        roomId: itemData["owner"]["web_rid"].toString(),
        title: itemData["title"].toString(),
        cover: itemData["cover"]["url_list"][0].toString(),
        nick: itemData["owner"]["nickname"].toString(),
        platform: Sites.douyinSite,
        avatar: itemData["owner"]["avatar_thumb"]["url_list"][0].toString(),
        liveStatus: roomStatus ? LiveStatus.live : LiveStatus.offline,
        area: '',
        status: roomStatus,
        watching: itemData["stats"]["total_user_str"].toString(),
      );
      items.add(roomItem);
    }
    return items;
  }

  @override
  Future<List<LiveAnchorItem>> searchAnchors(String keyword, {int page = 1, int pageSize = 30}) async {
    throw Exception("抖音暂不支持搜索主播，请直接搜索直播间");
  }

  @override
  Future<bool> getLiveStatus({required String platform, required String roomId}) async {
    var result = await getRoomDetail(roomId: roomId, platform: platform);
    return result.status!;
  }

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage({required String roomId}) {
    return Future.value(<LiveSuperChatMessage>[]);
  }

  //生成指定长度的16进制随机字符串
  String generateRandomString(int length) {
    var random = math.Random.secure();
    var values = List<int>.generate(length, (i) => random.nextInt(16));
    StringBuffer stringBuffer = StringBuffer();
    for (var item in values) {
      stringBuffer.write(item.toRadixString(16));
    }
    return stringBuffer.toString();
  }

  // 生成随机的数字
  int generateRandomNumber(int length) {
    var random = math.Random.secure();
    var values = List<int>.generate(length, (i) => random.nextInt(10));
    StringBuffer stringBuffer = StringBuffer();
    for (var item in values) {
      stringBuffer.write(item);
    }
    return int.tryParse(stringBuffer.toString()) ?? math.Random().nextInt(1000000000);
  }
}