import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/services/bulk_data_import_service.dart';
import 'package:simple_live_app/services/current_room_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/live_notification_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class FollowService extends GetxService {
  static const Duration updateStatusCooldown = Duration(seconds: 30);
  static const Duration refreshProgressCompletionHold = Duration(seconds: 2);
  static const int kDouyinLimitedAutoResumeMaxAttempts = 2;
  static const Duration kDouyinLimitedAutoResumeBaseDelay = Duration(
    seconds: 45,
  );
  static const int kFollowProgressUiBurstThreshold = 500;
  static const String _refreshTaskStateStorageKey =
      LocalStorageService.kFollowRefreshTaskState;
  static const String _refreshTaskTargetsStorageKey =
      LocalStorageService.kFollowRefreshTaskTargets;
  StreamSubscription<dynamic>? subscription;
  static FollowService get instance => Get.find<FollowService>();
  Timer? _eventReloadTimer;

  final StreamController _updatedListController = StreamController.broadcast();
  Stream get updatedListStream => _updatedListController.stream;

  /// 关注用户列表
  RxList<FollowUser> followList = RxList<FollowUser>();

  /// 直播中的用户列表
  RxList<FollowUser> liveList = RxList<FollowUser>();

  /// 未直播的用户列表
  RxList<FollowUser> notLiveList = RxList<FollowUser>();

  /// 用户自定义的tag
  RxList<FollowUserTag> followTagList = RxList<FollowUserTag>();

  /// 当前tag的用户列表
  RxList<FollowUser> curTagFollowList = RxList<FollowUser>();

  /// 是否正在更新
  var updating = false.obs;
  var refreshProgress = const FollowRefreshProgress.idle().obs;

  Timer? updateTimer;
  Timer? _refreshProgressResetTimer;
  final Set<String> _liveNotifySentIds = <String>{};
  final Set<String> _liveNotifyReadyIds = <String>{};
  int _updateGeneration = 0;
  DateTime? _lastUpdateStatusStartedAt;

  @override
  void onInit() {
    subscription = EventBus.instance.listen(Constant.kUpdateFollow, (p0) {
      _eventReloadTimer?.cancel();
      _eventReloadTimer = Timer(const Duration(milliseconds: 150), () {
        loadData(updateStatus: false);
      });
    });
    initTimer();
    super.onInit();
  }

  // 添加标签
  Future<void> addFollowUserTag(String tag) async {
    // 判断待添加tag是否已存在，存在则return
    if (followTagList.any((item) => item.tag == tag)) {
      SmartDialog.showToast("标签名重复，修改失败");
      return;
    }
    FollowUserTag item = await DBService.instance.addFollowTag(tag);
    followTagList.add(item);
  }

  // 删除标签
  Future<void> delFollowUserTag(FollowUserTag tag) async {
    followTagList.remove(tag);
    await DBService.instance.deleteFollowTag(tag.id);
  }

  // 获取用户自定义标签列表
  void getAllTagList() {
    var list = DBService.instance.getFollowTagList();
    followTagList.assignAll(list);
  }

  // 修改标签
  void updateFollowUserTag(FollowUserTag tag) {
    DBService.instance.updateFollowTag(tag);
    // 查找并修改
    var index = followTagList.indexWhere((oTag) => oTag.id == tag.id);
    followTagList[index] = tag;
  }

  // 根据标签筛选数据
  void filterDataByTag(FollowUserTag tag) {
    curTagFollowList.clear();
    // 用一个新的列表来存储需要删除的 userId
    List<String> toRemove = [];
    for (var id in tag.userId) {
      if (followList.any((x) => x.id == id)) {
        // 找到对应的 followUser 添加到 curTagFollowList
        curTagFollowList.add(followList.firstWhere((x) => x.id == id));
      } else {
        // 标记要删除的 id
        toRemove.add(id);
      }
    }
    // 双向确认用户取消关注后标签内是否还有该用户
    // 在遍历结束后统一移除不在 followList 中的 id
    tag.userId.removeWhere((id) => toRemove.contains(id));
    // 更新数据库
    if (toRemove.isNotEmpty) {
      DBService.instance.updateFollowTag(tag);
    }
    curTagFollowList.assignAll(sortFollowUsers(curTagFollowList));
  }

  // 添加关注
  Future<void> addFollow(FollowUser follow) async {
    await DBService.instance.addFollow(follow);
  }

  Future<void> updateSpecialFollow(FollowUser follow, bool value) async {
    follow.isSpecialFollow = value;
    if (value) {
      await LiveNotificationService.requestPermissionIfNeeded();
      if (follow.liveStatus.value != 0) {
        _liveNotifyReadyIds.add(follow.id);
      }
      if (follow.liveStatus.value == 2) {
        _liveNotifySentIds.add(follow.id);
      }
    } else {
      _liveNotifySentIds.remove(follow.id);
    }
    await DBService.instance.addFollow(follow);
    filterData();
  }

  void initTimer() {
    if (AppSettingsController.instance.autoUpdateFollowEnable.value) {
      updateTimer?.cancel();
      updateTimer = Timer.periodic(
        Duration(
            minutes:
                AppSettingsController.instance.autoUpdateFollowDuration.value),
        (timer) {
          Log.logPrint("Update Follow Timer");
          loadData();
        },
      );
    } else {
      updateTimer?.cancel();
    }
  }

  Future<void> loadData({
    bool updateStatus = true,
    bool forceUpdateStatus = false,
  }) async {
    var list = DBService.instance.getFollowList();
    getAllTagList();
    if (list.isEmpty) {
      updating.value = false;
      _resetRefreshProgress();
      followList.assignAll(list);
      return;
    }
    followList.assignAll(list);
    if (updateStatus) {
      unawaited(startUpdateStatus(force: forceUpdateStatus));
    }
  }

  /// 获取最优并发数。
  /// 后台按关注规模自动控制，不再读取用户配置，避免超大关注列表刷崩。
  int getOptimalConcurrency({int? totalCount}) {
    final count = totalCount ?? followList.length;
    final currentSiteId = CurrentRoomService.instance.siteId.value;
    final maxWhenPlayingDouyin = currentSiteId == Constant.kDouyin ? 4 : null;
    if (count <= 0) {
      return 1;
    }
    int cap(int value) {
      if (maxWhenPlayingDouyin == null) {
        return value;
      }
      return value.clamp(1, maxWhenPlayingDouyin).toInt();
    }

    if (count <= 300) {
      return cap(count < 48 ? count : 48);
    }
    if (count <= 1000) {
      return cap(32);
    }
    if (count <= 3000) {
      return cap(20);
    }
    if (count <= 5000) {
      return cap(12);
    }
    return cap(8);
  }

  /// 按平台交错排列，避免单一平台阻塞
  List<FollowUser> interleaveByPlatform(List<FollowUser> list) {
    // 按平台分组
    var grouped = <String, Queue<FollowUser>>{};
    for (var item in list) {
      grouped.putIfAbsent(item.siteId, () => Queue<FollowUser>()).add(item);
    }

    // 交错处理
    var result = <FollowUser>[];
    while (grouped.values.any((queue) => queue.isNotEmpty)) {
      for (var queue in grouped.values) {
        if (queue.isNotEmpty) {
          result.add(queue.removeFirst());
        }
      }
    }

    return result;
  }

  List<FollowUser> deprioritizeCurrentRoom(List<FollowUser> items) {
    final currentKey = CurrentRoomService.instance.currentKey;
    if (currentKey.isEmpty) {
      return items;
    }
    final currentItems = <FollowUser>[];
    final others = <FollowUser>[];
    for (final item in items) {
      final itemKey = "${item.siteId}_${item.roomId}";
      if (itemKey == currentKey) {
        currentItems.add(item);
      } else {
        others.add(item);
      }
    }
    return [...others, ...currentItems];
  }

  List<String> _orderedRefreshSiteIds(Iterable<String> siteIds) {
    const preferredOrder = <String>[
      Constant.kBiliBili,
      Constant.kHuya,
      Constant.kDouyu,
      Constant.kDouyin,
      Constant.kKuaishou,
    ];
    final seen = <String>{};
    final result = <String>[];
    for (final siteId in preferredOrder) {
      if (siteIds.contains(siteId) && seen.add(siteId)) {
        result.add(siteId);
      }
    }
    final remaining = siteIds.where((siteId) => seen.add(siteId)).toList()
      ..sort();
    result.addAll(remaining);
    return result;
  }

  List<FollowUser> _orderRefreshBucketBySite(
    List<FollowUser> items, {
    bool moveCurrentRoomToEnd = false,
  }) {
    final grouped = <String, List<FollowUser>>{};
    for (final item in items) {
      grouped.putIfAbsent(item.siteId, () => <FollowUser>[]).add(item);
    }
    final ordered = <FollowUser>[];
    for (final siteId in _orderedRefreshSiteIds(grouped.keys)) {
      var bucket = sortFollowUsers(grouped[siteId] ?? const <FollowUser>[]);
      if (moveCurrentRoomToEnd) {
        bucket = deprioritizeCurrentRoom(bucket);
      }
      ordered.addAll(bucket);
    }
    return ordered;
  }

  List<FollowUser> _buildOrderedRefreshTargets(Iterable<FollowUser> items) {
    final uniqueItems = _distinctFollowUsers(items);
    final specials = uniqueItems.where((item) => item.isSpecialFollow).toList();
    final normals = uniqueItems.where((item) => !item.isSpecialFollow).toList();
    final orderedSpecials = _orderRefreshBucketBySite(specials);
    final orderedNormals = _orderRefreshBucketBySite(
      normals,
      moveCurrentRoomToEnd: true,
    );
    return [...orderedSpecials, ...orderedNormals];
  }

  Duration _douyinLimitedAutoResumeDelay(int attempt) {
    return Duration(
      seconds: kDouyinLimitedAutoResumeBaseDelay.inSeconds * attempt,
    );
  }

  List<FollowUser> _specialFirstTargets(List<FollowUser> items) {
    final specials = _orderRefreshBucketBySite(
      items.where((item) => item.isSpecialFollow).toList(),
    );
    final normals = _orderRefreshBucketBySite(
      items.where((item) => !item.isSpecialFollow).toList(),
      moveCurrentRoomToEnd: true,
    );
    return [...specials, ...normals];
  }

  Future<void> startUpdateStatus({bool force = false}) async {
    final now = DateTime.now();
    final lastStartedAt = _lastUpdateStatusStartedAt;
    if (!force &&
        lastStartedAt != null &&
        now.difference(lastStartedAt) < updateStatusCooldown) {
      Log.logPrint("关注状态刷新过于频繁，已跳过本次网络刷新");
      updating.value = false;
      _resetRefreshProgress();
      filterData();
      return;
    }
    _lastUpdateStatusStartedAt = now;
    final generation = ++_updateGeneration;
    final automatic = !force;
    _cancelRefreshProgressReset();
    if (updating.value) {
      Log.logPrint("已有关注状态刷新任务，取消旧任务并启动新任务");
    }
    updating.value = true;
    _setRefreshProgress(
      active: true,
      automatic: automatic,
      scopeKey: "all",
      stage: "正在刷新关注状态",
      current: 0,
      total: followList.length,
    );

    var concurrency = getOptimalConcurrency(totalCount: followList.length);
    final policy = BulkDataImportService.policyForCount(followList.length);

    Log.logPrint(
      "开始更新关注状态，并发数: $concurrency，总数: ${followList.length}，规模: ${policy.label}",
    );

    try {
      // 特别关注先刷，普通关注再按平台交错；普通关注里仍保留当前房间靠后。
      var interleavedList = _specialFirstTargets(followList);

      // 创建任务队列
      var taskQueue = Queue<FollowUser>.from(interleavedList);
      final douyinTargetCount = interleavedList
          .where((item) => item.siteId == Constant.kDouyin)
          .length;
      final douyinLimiter = douyinTargetCount > 0
          ? DouyinFollowRefreshLimiter.forTargetCount(douyinTargetCount)
          : null;

      // 工作函数 - 持续从队列中取任务执行
      var completed = 0;

      Future<void> worker(int workerId) async {
        while (taskQueue.isNotEmpty) {
          if (generation != _updateGeneration) {
            return;
          }
          var item = taskQueue.removeFirst();
          await _updateLiveStatus(
            item,
            generation: generation,
            douyinLimiter: douyinLimiter,
            workerIndex: workerId,
            pauseRemainingOnLimited: false,
          );
          if (generation != _updateGeneration) {
            return;
          }
          completed++;
          _setRefreshProgress(
            active: true,
            automatic: automatic,
            scopeKey: "all",
            stage: "正在刷新关注状态",
            current: completed,
            total: interleavedList.length,
          );
        }
      }

      // 启动固定数量的并发 worker
      var workers = <Future>[];
      for (var i = 0; i < concurrency; i++) {
        workers.add(worker(i));
      }

      await Future.wait(workers);

      if (generation != _updateGeneration) {
        return;
      }
      if (douyinLimiter != null) {
        final summary = douyinLimiter.finish(douyinTargetCount);
        Log.logPrint(
          "抖音关注刷新总结 scope=all target=${summary.targetCount} "
          "startConcurrency=${summary.initialConcurrency} "
          "startInterval=${summary.initialInterval.inMilliseconds}ms "
          "finalInterval=${summary.finalInterval.inMilliseconds}ms "
          "success=${summary.successCount} limited=${summary.limitedCount} "
          "cooldown=${summary.cooledDown} elapsed=${summary.elapsed.inMilliseconds}ms",
        );
      }
      filterData();
      Log.logPrint("关注状态更新完成");
    } finally {
      if (generation == _updateGeneration) {
        updating.value = false;
        _finishRefreshProgressLifecycle(generation);
      }
    }
  }

  Future<_FollowRefreshItemResult> _updateLiveStatus(
    FollowUser item, {
    int? generation,
    DouyinFollowRefreshLimiter? douyinLimiter,
    int workerIndex = 0,
    bool pauseRemainingOnLimited = false,
  }) async {
    final previousStatus = item.liveStatus.value;
    final notifyReady = _liveNotifyReadyIds.contains(item.id);
    try {
      if (item.siteId == Constant.kDouyin && douyinLimiter != null) {
        await douyinLimiter.beforeRequest(workerIndex);
      }
      var site = Sites.allSites[item.siteId]!;
      // 手动/自动关注刷新统一走状态优先，不在主链路同步补详情。
      var isLiving = await site.liveSite.getLiveStatus(roomId: item.roomId);
      if (generation != null && generation != _updateGeneration) {
        return const _FollowRefreshItemResult(_FollowRefreshItemOutcome.deferred);
      }
      if (item.siteId == Constant.kDouyin && douyinLimiter != null) {
        douyinLimiter.onSuccess();
      }
      item.liveStatus.value = isLiving ? 2 : 1;
      if (item.siteId == Constant.kDouyin) {
        await _reconcileDouyinFollowIdentity(
          item,
          site.liveSite,
          isLiving: isLiving,
          generation: generation,
        );
      } else if (item.liveStatus.value == 2) {
        final detail = await site.liveSite.getRoomDetail(roomId: item.roomId);
        if (generation != null && generation != _updateGeneration) {
          return const _FollowRefreshItemResult(_FollowRefreshItemOutcome.deferred);
        }
        item.liveStartTime = detail.showTime;
      } else {
        item.liveStartTime = null;
        _liveNotifySentIds.remove(item.id);
      }
      if (item.isSpecialFollow &&
          notifyReady &&
          previousStatus != 2 &&
          item.liveStatus.value == 2 &&
          !_liveNotifySentIds.contains(item.id)) {
        _liveNotifySentIds.add(item.id);
        unawaited(LiveNotificationService.showLiveStart(item));
      }
      _liveNotifyReadyIds.add(item.id);
      return const _FollowRefreshItemResult(_FollowRefreshItemOutcome.success);
    } catch (e) {
      if (generation != null && generation != _updateGeneration) {
        return const _FollowRefreshItemResult(_FollowRefreshItemOutcome.deferred);
      }
      var limited = false;
      if (_isDouyinLimited(item, e)) {
        limited = true;
        if (douyinLimiter != null) {
          douyinLimiter.onLimited();
          _handleDouyinLimited(
            pauseRemainingOnLimited: pauseRemainingOnLimited,
          );
        } else {
          _handleDouyinLimited(
            pauseRemainingOnLimited: pauseRemainingOnLimited,
          );
        }
      }
      Log.logPrint(e);
      if (limited) {
        if (pauseRemainingOnLimited) {
          return const _FollowRefreshItemResult(
            _FollowRefreshItemOutcome.deferred,
            limited: true,
            keepPending: true,
            pauseRemaining: true,
          );
        }
        return const _FollowRefreshItemResult(
          _FollowRefreshItemOutcome.failed,
          limited: true,
        );
      }
      item.liveStatus.value = 0;
      item.liveStartTime = null;
      return _FollowRefreshItemResult(
        _FollowRefreshItemOutcome.failed,
        limited: limited,
      );
    }
  }

  Future<void> _reconcileDouyinFollowIdentity(
    FollowUser item,
    dynamic liveSite, {
    required bool isLiving,
    required int? generation,
  }) async {
    final detail = await liveSite.getRoomDetail(roomId: item.roomId);
    if (generation != null && generation != _updateGeneration) {
      return;
    }
    final resolvedRoomId = detail.roomId.trim();
    if (resolvedRoomId.isNotEmpty && resolvedRoomId != item.roomId) {
      final oldId = item.id;
      final newId = "${item.siteId}_$resolvedRoomId";
      await DBService.instance.deleteFollow(oldId);
      item.id = newId;
      item.roomId = resolvedRoomId;
      await DBService.instance.addFollow(item);
      await _migrateFollowTagReferences(oldId, newId);
    }
    item.liveStatus.value = detail.status ? 2 : 1;
    item.liveStartTime = detail.status && isLiving ? detail.showTime : null;
    if (item.liveStatus.value != 2) {
      _liveNotifySentIds.remove(item.id);
    }
  }

  Future<void> _migrateFollowTagReferences(String oldId, String newId) async {
    if (oldId == newId) {
      return;
    }
    for (final tag in followTagList) {
      final index = tag.userId.indexOf(oldId);
      if (index < 0) {
        continue;
      }
      tag.userId[index] = newId;
      final deduplicated = <String>{};
      tag.userId.removeWhere((id) => !deduplicated.add(id));
      await DBService.instance.updateFollowTag(tag);
    }
  }

  bool _isDouyinLimited(FollowUser item, Object error) {
    return item.siteId == Constant.kDouyin &&
        error is CoreError &&
        error.statusCode == 444;
  }


  void _handleDouyinLimited({required bool pauseRemainingOnLimited}) {
    if (pauseRemainingOnLimited) {
      Log.w("抖音访问受限，已自动降速并保留剩余任务供后续继续");
      return;
    }
    Log.w("抖音访问受限，已自动降速并继续处理剩余任务");
  }

  int compareFollowUsers(FollowUser a, FollowUser b) {
    final aBucket = _sortBucket(a);
    final bBucket = _sortBucket(b);
    final liveCompare = aBucket.compareTo(bBucket);
    if (liveCompare != 0) {
      return liveCompare;
    }
    return b.addTime.compareTo(a.addTime);
  }

  int _sortBucket(FollowUser item) {
    final isLiving = item.liveStatus.value == 2;
    if (item.isSpecialFollow) {
      return isLiving ? 0 : 1;
    }
    return isLiving ? 2 : 3;
  }

  List<FollowUser> sortFollowUsers(Iterable<FollowUser> items) {
    return items.toList()..sort(compareFollowUsers);
  }

  List<FollowUser> _distinctFollowUsers(Iterable<FollowUser> items) {
    final result = <FollowUser>[];
    final seenIds = <String>{};
    for (final item in items) {
      final uniqueId = item.id.trim().isNotEmpty
          ? item.id.trim()
          : "${item.siteId}_${item.roomId}";
      if (seenIds.add(uniqueId)) {
        result.add(item);
      }
    }
    return result;
  }

  List<FollowUser> _buildRefreshTargets(
    Iterable<FollowUser> normalTargets, {
    bool includeAllNormals = false,
  }) {
    final specials = followList.where((item) => item.isSpecialFollow).toList();
    final normals = includeAllNormals
        ? followList.where((item) => !item.isSpecialFollow).toList()
        : normalTargets.where((item) => !item.isSpecialFollow).toList();
    return _distinctFollowUsers([
      ...sortFollowUsers(specials),
      ...sortFollowUsers(normals),
    ]);
  }

  List<FollowUser> buildPageFrontTargets(Iterable<FollowUser> pageItems) {
    return _distinctFollowUsers(sortFollowUsers(pageItems));
  }

  String buildPageRefreshScopeKey(String pageKey) => "page:$pageKey";

  String _refreshTargetKey(FollowUser item) {
    final uniqueId = item.id.trim().isNotEmpty
        ? item.id.trim()
        : "${item.siteId}_${item.roomId}";
    return "${item.siteId}|${item.roomId}|$uniqueId";
  }

  bool _sameStringList(List<String> a, List<String> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  _PersistedFollowRefreshTaskState? _loadPersistedRefreshTask(String scopeKey) {
    try {
      final rawState = LocalStorageService.instance.getValue(
        _refreshTaskStateStorageKey,
        "",
      );
      final rawTargets = LocalStorageService.instance.getValue(
        _refreshTaskTargetsStorageKey,
        "",
      );
      if (rawState.isEmpty || rawTargets.isEmpty) {
        return null;
      }
      final stateMap = jsonDecode(rawState);
      final targetsMap = jsonDecode(rawTargets);
      if (stateMap is! Map || targetsMap is! Map) {
        return null;
      }
      final state = _PersistedFollowRefreshTaskState.fromMaps(
        stateMap.cast<String, dynamic>(),
        targetsMap.cast<String, dynamic>(),
      );
      if (state.scopeKey != scopeKey) {
        return null;
      }
      return state;
    } catch (e) {
      Log.w("读取关注刷新续跑状态失败: $e");
      return null;
    }
  }

  Future<void> _persistRefreshTask({
    required FollowRefreshScope scope,
    required int total,
    required List<String> orderedKeys,
    required List<String> pendingKeys,
    required int successCount,
    required int failedCount,
    required int deferredCount,
  }) async {
    if (!scope.includeAllNormals) {
      return;
    }
    final statePayload = {
      "scopeKey": scope.scopeKey,
      "total": total,
      "successCount": successCount,
      "failedCount": failedCount,
      "deferredCount": deferredCount,
      "updatedAt": DateTime.now().toIso8601String(),
    };
    final targetPayload = {
      "orderedKeys": orderedKeys,
      "pendingKeys": pendingKeys,
    };
    await LocalStorageService.instance.setValue(
      _refreshTaskStateStorageKey,
      jsonEncode(statePayload),
    );
    await LocalStorageService.instance.setValue(
      _refreshTaskTargetsStorageKey,
      jsonEncode(targetPayload),
    );
    // Fix Windows crash on exit: 频繁写入导致localstorage.hive膨胀到2GB，
    // 应用退出时写入LastLiveRoom触发STATUS_STACK_BUFFER_OVERRUN(0xC0000409)
    // 每次persist后尝试compact，失败则忽略，不阻塞刷新流程
    try {
      await LocalStorageService.instance.settingsBox.compact();
    } catch (e) {
      // compact失败不影响刷新，静默忽略
    }
  }

  Future<void> _clearPersistedRefreshTask() async {
    await LocalStorageService.instance.removeValue(_refreshTaskStateStorageKey);
    await LocalStorageService.instance.removeValue(_refreshTaskTargetsStorageKey);
  }

  _RefreshTargetPolicyResult _applyDouyinRefreshPolicy(
    List<FollowUser> orderedTargets, {
    required FollowRefreshScope scope,
    required bool hasFullDouyinCookie,
  }) {
    return _RefreshTargetPolicyResult(
      allowedTargets: orderedTargets,
      deferredTargets: const [],
      toastMessage: hasFullDouyinCookie
          ? ""
          : "抖音未登录时将自动降速刷新；若出现 444，会暂停并保留剩余任务供后续继续。",
    );
  }
  Future<void> refreshSelectedStatus(
    Iterable<FollowUser> normalTargets, {
    bool includeAllNormals = false,
    bool force = true,
    FollowRefreshScope? scope,
  }) {
    final resolvedScope = scope ??
        FollowRefreshScope.all(
          automatic: !force,
        );
    final targets = resolvedScope.includeAllNormals
        ? _buildRefreshTargets(
            normalTargets,
            includeAllNormals: includeAllNormals,
          )
        : buildPageFrontTargets(normalTargets);
    return _refreshStatusTargets(
      targets,
      force: force,
      scope: resolvedScope,
    );
  }

  Future<void> _refreshStatusTargets(
    List<FollowUser> targets, {
    bool force = false,
    required FollowRefreshScope scope,
  }) async {
    final now = DateTime.now();
    final lastStartedAt = _lastUpdateStatusStartedAt;
    if (!force &&
        lastStartedAt != null &&
        now.difference(lastStartedAt) < updateStatusCooldown) {
      Log.logPrint("关注状态刷新仍在冷却中，跳过本次自动刷新");
      updating.value = false;
      _resetRefreshProgress();
      filterData();
      return;
    }
    if (updating.value &&
        refreshProgress.value.active &&
        refreshProgress.value.scopeKey == scope.scopeKey &&
        !refreshProgress.value.completed) {
      Log.logPrint("同一刷新任务仍在进行，复用当前进度: ${scope.scopeKey}");
      return;
    }
    _lastUpdateStatusStartedAt = now;
    final generation = ++_updateGeneration;
    final automatic = scope.automatic;
    _cancelRefreshProgressReset();
    if (updating.value) {
      Log.logPrint("新的关注刷新任务已启动，旧任务将按 generation 自动退出: ${scope.scopeKey}");
    }
    updating.value = true;
    _setRefreshProgress(
      active: true,
      automatic: automatic,
      scopeKey: scope.scopeKey,
      stage: scope.stage,
      current: 0,
      total: targets.length,
    );

    if (targets.isEmpty) {
      updating.value = false;
      _resetRefreshProgress();
      filterData();
      return;
    }

    try {
      var concurrency = getOptimalConcurrency(totalCount: targets.length);
      final policy = BulkDataImportService.policyForCount(targets.length);
      final hasFullDouyinCookie = DouyinCookieHelper.hasFullCookie(
        (Sites.allSites[Constant.kDouyin]?.liveSite as DouyinSite?)?.cookie ?? "",
      );

      Log.logPrint(
        "关注刷新开始，并发数: $concurrency，目标数: ${targets.length}，策略: ${policy.label}，"
        "scope=${scope.scopeKey} fullDouyinCookie=$hasFullDouyinCookie",
      );

      final orderedTargets = _buildOrderedRefreshTargets(targets);
      final filteredTargets = _applyDouyinRefreshPolicy(
        orderedTargets,
        scope: scope,
        hasFullDouyinCookie: hasFullDouyinCookie,
      );
      final allowedTargets = filteredTargets.allowedTargets;
      final orderedAllowedKeys = allowedTargets.map(_refreshTargetKey).toList();
      final targetByKey = <String, FollowUser>{
        for (final item in allowedTargets) _refreshTargetKey(item): item,
      };
      final persistedTask = _loadPersistedRefreshTask(scope.scopeKey);
      final resumeTask = scope.includeAllNormals &&
          persistedTask != null &&
          _sameStringList(persistedTask.orderedKeys, orderedAllowedKeys) &&
          persistedTask.pendingKeys.isNotEmpty;
      final pendingKeys = resumeTask
          ? persistedTask.pendingKeys
              .where(targetByKey.containsKey)
              .toList(growable: true)
          : orderedAllowedKeys.toList(growable: true);
      final isHugeTask = targets.length >= kFollowProgressUiBurstThreshold;
      final douyinTargetCount = filteredTargets.allowedTargets
          .where((item) => item.siteId == Constant.kDouyin)
          .length;
      final douyinLimiter = douyinTargetCount > 0
          ? DouyinFollowRefreshLimiter.forTargetCount(douyinTargetCount)
          : null;

      final resumedSuccessCount = persistedTask?.successCount ?? 0;
      final resumedFailedCount = persistedTask?.failedCount ?? 0;
      var completed = resumeTask ? resumedSuccessCount + resumedFailedCount : 0;
      var successCount = resumeTask ? resumedSuccessCount : 0;
      var failedCount = resumeTask ? resumedFailedCount : 0;
      var deferredCount = filteredTargets.deferredTargets.length;
      var limitedCount = 0;
      var pausedForResume = false;
      var autoResumeAttempt = 0;

      if (scope.includeAllNormals) {
        unawaited(
          _persistRefreshTask(
            scope: scope,
            total: targets.length,
            orderedKeys: orderedAllowedKeys,
            pendingKeys: pendingKeys,
            successCount: successCount,
            failedCount: failedCount,
            deferredCount: deferredCount,
          ),
        );
      }

      if (filteredTargets.deferredTargets.isNotEmpty) {
        Log.w(
          "抖音全量刷新受限：scope=${scope.scopeKey} deferred=$deferredCount "
          "allowedDouyin=$douyinTargetCount requiresFullCookie=true",
        );
        if (filteredTargets.toastMessage.isNotEmpty) {
          SmartDialog.showToast(filteredTargets.toastMessage);
        }
      }
      if (resumeTask) {
        Log.logPrint(
          "继续上次未完成的全量关注刷新：scope=${scope.scopeKey} remaining=$pendingKeys.length",
        );
      }

      void updateProgress({required bool active, required bool done}) {
        final detail = [
          "成功 $successCount",
          if (failedCount > 0) "失败 $failedCount",
          if (deferredCount > 0) "待续跑 $deferredCount",
        ].join("  ");
        _setRefreshProgress(
          active: active,
          automatic: automatic,
          scopeKey: scope.scopeKey,
          stage: scope.stage,
          current: completed,
          total: targets.length,
          successCount: successCount,
          failedCount: failedCount,
          deferredCount: deferredCount,
          detail: detail,
          completed: done,
        );
      }

      updateProgress(active: true, done: false);

      while (pendingKeys.isNotEmpty) {
        final taskQueue = Queue<FollowUser>.from(
          pendingKeys
              .map((key) => targetByKey[key])
              .whereType<FollowUser>(),
        );
        pausedForResume = false;

        Future<void> worker(int workerId) async {
          while (taskQueue.isNotEmpty) {
            if (generation != _updateGeneration || pausedForResume) {
              return;
            }
            var item = taskQueue.removeFirst();
            final result = await _updateLiveStatus(
              item,
              generation: generation,
              douyinLimiter: douyinLimiter,
              workerIndex: workerId,
              pauseRemainingOnLimited: scope.includeAllNormals,
            );
            if (generation != _updateGeneration) {
              return;
            }
            if (result.limited) {
              limitedCount++;
            }
            final targetKey = _refreshTargetKey(item);
            if (!result.keepPending) {
              pendingKeys.remove(targetKey);
            }

            switch (result.outcome) {
              case _FollowRefreshItemOutcome.success:
                successCount++;
                completed++;
                break;
              case _FollowRefreshItemOutcome.failed:
                failedCount++;
                completed++;
                break;
              case _FollowRefreshItemOutcome.deferred:
              case _FollowRefreshItemOutcome.skipped:
                break;
            }
      if (result.pauseRemaining) {
        pausedForResume = true;
        deferredCount =
            filteredTargets.deferredTargets.length + pendingKeys.length;
      }
            if (scope.includeAllNormals && !isHugeTask) {
              unawaited(
                _persistRefreshTask(
                  scope: scope,
                  total: targets.length,
                  orderedKeys: orderedAllowedKeys,
                  pendingKeys: pendingKeys,
                  successCount: successCount,
                  failedCount: failedCount,
                  deferredCount: deferredCount,
                ),
              );
            }
            if (!isHugeTask || completed % 20 == 0 || pendingKeys.isEmpty) {
              updateProgress(active: true, done: false);
            }
          }
        }

        var workers = <Future>[];
        for (var i = 0; i < concurrency; i++) {
          workers.add(worker(i));
        }
        await Future.wait(workers);

        if (generation != _updateGeneration) {
          return;
        }
        if (!pausedForResume || pendingKeys.isEmpty) {
          break;
        }
        if (!scope.includeAllNormals ||
            autoResumeAttempt >= kDouyinLimitedAutoResumeMaxAttempts) {
          break;
        }
        autoResumeAttempt++;
        final resumeDelay = _douyinLimitedAutoResumeDelay(autoResumeAttempt);
        Log.w(
          "抖音刷新触发限流，${resumeDelay.inSeconds}s后自动续刷剩余${pendingKeys.length}项 "
          "scope=${scope.scopeKey} attempt=$autoResumeAttempt",
        );
        updateProgress(active: true, done: false);
        await Future.delayed(resumeDelay);
        if (generation != _updateGeneration) {
          return;
        }
        deferredCount = filteredTargets.deferredTargets.length;
      }

      if (generation != _updateGeneration) {
        return;
      }
      if (douyinLimiter != null) {
        final summary = douyinLimiter.finish(douyinTargetCount);
        Log.logPrint(
          "抖音关注刷新总结 scope=${scope.scopeKey} target=${summary.targetCount} "
          "startConcurrency=${summary.initialConcurrency} "
          "startInterval=${summary.initialInterval.inMilliseconds}ms "
          "finalInterval=${summary.finalInterval.inMilliseconds}ms "
          "success=${summary.successCount} limited=${summary.limitedCount} "
          "cooldown=${summary.cooledDown} elapsed=${summary.elapsed.inMilliseconds}ms "
          "failed=$failedCount deferred=$deferredCount limitedObserved=$limitedCount",
        );
      }
      if (pendingKeys.isNotEmpty) {
        if (scope.includeAllNormals) {
          deferredCount =
              filteredTargets.deferredTargets.length + pendingKeys.length;
        } else {
          failedCount += pendingKeys.length;
          completed += pendingKeys.length;
          pendingKeys.clear();
          deferredCount = filteredTargets.deferredTargets.length;
        }
      }
      updateProgress(active: false, done: true);
      if (scope.includeAllNormals) {
        if (pendingKeys.isEmpty) {
          await _clearPersistedRefreshTask();
        } else {
          await _persistRefreshTask(
            scope: scope,
            total: targets.length,
            orderedKeys: orderedAllowedKeys,
            pendingKeys: pendingKeys,
            successCount: successCount,
            failedCount: failedCount,
            deferredCount: deferredCount,
          );
        }
      }
      filterData();

      Log.logPrint("关注状态刷新完成");
    } finally {
      if (generation == _updateGeneration) {
        updating.value = false;
        _finishRefreshProgressLifecycle(generation);
      }
    }
  }

  void _setRefreshProgress({
    required bool active,
    required bool automatic,
    required String scopeKey,
    required String stage,
    required int current,
    required int total,
    int successCount = 0,
    int failedCount = 0,
    int deferredCount = 0,
    int skippedCount = 0,
    bool completed = false,
    bool background = false,
    String detail = "",
  }) {
    refreshProgress.value = FollowRefreshProgress(
      active: active,
      automatic: automatic,
      scopeKey: scopeKey,
      stage: stage,
      current: current.clamp(0, total).toInt(),
      total: total,
      successCount: successCount,
      failedCount: failedCount,
      deferredCount: deferredCount,
      skippedCount: skippedCount,
      completed: completed,
      background: background,
      detail: detail,
    );
  }

  void _resetRefreshProgress() {
    _cancelRefreshProgressReset();
    refreshProgress.value = const FollowRefreshProgress.idle();
  }

  void _cancelRefreshProgressReset() {
    _refreshProgressResetTimer?.cancel();
    _refreshProgressResetTimer = null;
  }

  void _finishRefreshProgressLifecycle(int generation) {
    if (refreshProgress.value.completed) {
      _scheduleRefreshProgressReset(generation);
      return;
    }
    _resetRefreshProgress();
  }

  void _scheduleRefreshProgressReset(int generation) {
    _cancelRefreshProgressReset();
    _refreshProgressResetTimer = Timer(
      refreshProgressCompletionHold,
      () {
        if (generation != _updateGeneration) {
          return;
        }
        if (updating.value || !refreshProgress.value.completed) {
          return;
        }
        _resetRefreshProgress();
      },
    );
  }

  void filterData() {
    followList.assignAll(sortFollowUsers(followList));
    liveList.assignAll(
      sortFollowUsers(followList.where((x) => x.liveStatus.value == 2)),
    );
    notLiveList.assignAll(
      sortFollowUsers(followList.where((x) => x.liveStatus.value != 2)),
    );
    _updatedListController.add(0);
  }

  void exportFile() async {
    if (followList.isEmpty) {
      SmartDialog.showToast("列表为空");
      return;
    }

    try {
      var status = await Utils.checkStorgePermission();
      if (!status) {
        SmartDialog.showToast("无权限");
        return;
      }

      var dir = "";
      if (Platform.isIOS) {
        dir = (await getApplicationDocumentsDirectory()).path;
      } else {
        dir = await FilePicker.platform.getDirectoryPath() ?? "";
      }

      if (dir.isEmpty) {
        return;
      }
      var jsonFile = File(
          '$dir/SimpleLive_${DateTime.now().millisecondsSinceEpoch ~/ 1000}.json');
      var jsonText = generateJson();
      await jsonFile.writeAsString(jsonText);
      SmartDialog.showToast("已导出关注列表");
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导出失败：$e");
    }
  }

  void inputFile() async {
    try {
      var status = await Utils.checkStorgePermission();
      if (!status) {
        SmartDialog.showToast("无权限");
        return;
      }
      var file = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (file == null) {
        return;
      }
      var jsonFile = File(file.files.single.path!);
      await inputJson(await jsonFile.readAsString());
      SmartDialog.showToast("导入成功");
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导入失败:$e");
    } finally {
      loadData(updateStatus: false);
    }
  }

  void exportText() {
    if (followList.isEmpty) {
      SmartDialog.showToast("列表为空");
      return;
    }
    var content = generateJson();
    Get.dialog(
      AlertDialog(
        title: const Text("导出为文本"),
        content: TextField(
          controller: TextEditingController(text: content),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
          ),
          minLines: 5,
          maxLines: 8,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
            },
            child: const Text("关闭"),
          ),
          TextButton(
            onPressed: () {
              Utils.copyToClipboard(content);
              Get.back();
            },
            child: const Text("复制"),
          ),
        ],
      ),
    );
  }

  void inputText() async {
    final TextEditingController textController = TextEditingController();
    await Get.dialog(
      AlertDialog(
        title: const Text("从文本导入"),
        content: TextField(
          controller: textController,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: "请输入内容",
          ),
          minLines: 5,
          maxLines: 8,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
            },
            child: const Text("关闭"),
          ),
          TextButton(
            onPressed: () async {
              var content = await Utils.getClipboard();
              if (content != null) {
                textController.text = content;
              }
            },
            child: const Text("粘贴"),
          ),
          TextButton(
            onPressed: () async {
              if (textController.text.isEmpty) {
                SmartDialog.showToast("内容为空");
                return;
              }
              try {
                await inputJson(textController.text);
                SmartDialog.showToast("导入成功");
                Get.back();
                loadData(updateStatus: false);
              } catch (e) {
                SmartDialog.showToast("导入失败，请检查内容是否正确");
              }
            },
            child: const Text("导入"),
          ),
        ],
      ),
    );
  }

  String generateJson() {
    var data = followList
        .map(
          (item) => {
            "siteId": item.siteId,
            "id": item.id,
            "roomId": item.roomId,
            "userName": item.userName,
            "face": item.face,
            "addTime": item.addTime.toString(),
            "tag": item.tag,
            "isSpecialFollow": item.isSpecialFollow
          },
        )
        .toList();
    return jsonEncode(data);
  }

  Future inputJson(String content) async {
    var data = jsonDecode(content);
    if (data is! List) {
      throw const FormatException("关注列表格式不是数组");
    }
    final stopwatch = Stopwatch()..start();
    final result = await BulkDataImportService.importFollowUsers(
      data,
      syncTagsFromUserField: true,
    );
    stopwatch.stop();
    Log.i(
      "文本/文件关注导入完成：${result.logSummary} elapsed=${stopwatch.elapsedMilliseconds}ms",
    );
  }

  @override
  void onClose() {
    _updateGeneration++;
    updating.value = false;
    _cancelRefreshProgressReset();
    _resetRefreshProgress();
    updateTimer?.cancel();
    _eventReloadTimer?.cancel();
    subscription?.cancel();
    super.onClose();
  }
}

enum _FollowRefreshItemOutcome {
  success,
  failed,
  deferred,
  skipped,
}

class _FollowRefreshItemResult {
  final _FollowRefreshItemOutcome outcome;
  final bool limited;
  final bool keepPending;
  final bool pauseRemaining;

  const _FollowRefreshItemResult(
    this.outcome, {
    this.limited = false,
    this.keepPending = false,
    this.pauseRemaining = false,
  });
}

class _RefreshTargetPolicyResult {
  final List<FollowUser> allowedTargets;
  final List<FollowUser> deferredTargets;
  final String toastMessage;

  const _RefreshTargetPolicyResult({
    required this.allowedTargets,
    required this.deferredTargets,
    this.toastMessage = "",
  });
}

class _PersistedFollowRefreshTaskState {
  final String scopeKey;
  final int total;
  final int successCount;
  final int failedCount;
  final int deferredCount;
  final List<String> orderedKeys;
  final List<String> pendingKeys;

  const _PersistedFollowRefreshTaskState({
    required this.scopeKey,
    required this.total,
    required this.successCount,
    required this.failedCount,
    required this.deferredCount,
    required this.orderedKeys,
    required this.pendingKeys,
  });

  factory _PersistedFollowRefreshTaskState.fromMaps(
    Map<String, dynamic> state,
    Map<String, dynamic> targets,
  ) {
    List<String> readList(dynamic value) {
      if (value is! List) {
        return const [];
      }
      return value.map((item) => item.toString()).toList();
    }

    return _PersistedFollowRefreshTaskState(
      scopeKey: state["scopeKey"]?.toString() ?? "",
      total: (state["total"] as num?)?.toInt() ?? 0,
      successCount: (state["successCount"] as num?)?.toInt() ?? 0,
      failedCount: (state["failedCount"] as num?)?.toInt() ?? 0,
      deferredCount: (state["deferredCount"] as num?)?.toInt() ?? 0,
      orderedKeys: readList(targets["orderedKeys"]),
      pendingKeys: readList(targets["pendingKeys"]),
    );
  }
}

