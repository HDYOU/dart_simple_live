import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_core/simple_live_core.dart';

class UpdateRoomUtil {
  ///  更新房间
  static Future<bool> updateRoomList(List<FollowUser> roomList) async {
    // 批量更新
    var tmp = Sites.supportSites
        .where((site) => site.liveSite.isSupportBatchUpdateLiveStatus())
        .map((site) => MapEntry(site.liveSite, <FollowUser>[]))
        .toList();
    var batchUpdateSiteMap = Map.fromEntries(tmp);
    var unBatchUpdateRooms = <FollowUser>[];
    bool hasError = false;
    // 没有批量更新列表
    for (final room in roomList) {
      if (room.roomId == "") {
        continue;
      }
      var liveSite = Sites.allSites[room.siteId]!.liveSite;
      if (liveSite.isSupportBatchUpdateLiveStatus()) {
        batchUpdateSiteMap[liveSite]!.add(room);
      } else {
        unBatchUpdateRooms.add(room);
      }
    }

    // 批量更新
    List<Future<List<LiveRoomDetail>>> futures = [];
    List<List<FollowUser>> batchFollowUserList = [];
    batchUpdateSiteMap.forEach((liveSite, list) {
      batchFollowUserList.add(list);
      futures.add(liveSite.getLiveRoomDetailList(
          list: list.map((e) => e.roomId).toList()));
    });
    try {
      for (var i = 0; i < futures.length; i++) {
        final rooms = await futures[i];
        for (var j = 0; j < rooms.length; j++) {
          var room = rooms[j];
          var followUser = batchFollowUserList[i][j];
          followUser.liveStatus.value = room.status ? 2 : 1;
        }
      }
    } catch (e) {
      hasError = true;
    }

    var threadCount =
        AppSettingsController.instance.updateFollowThreadCount.value;
    List<Future> futures2 = [];
    for (final room in unBatchUpdateRooms) {
      if (room.roomId == "") {
        continue;
      }
      futures2.add(Future(() async {
        try {
          var site = Sites.allSites[room.siteId]!;
          room.liveStatus.value =
              (await site.liveSite.getLiveStatus(roomId: room.roomId)) ? 2 : 1;
        } catch (e) {
          Log.logPrint(e);
          hasError = true;
        } finally {}
      }));
    }
    List<List<Future>> groupedList = [];

    // 每次循环处理四个元素
    for (int i = 0; i < futures.length; i += threadCount) {
      // 获取当前循环开始到下一个四个元素的位置（但不超过原列表长度）
      int end = i + threadCount;
      if (end > futures.length) {
        end = futures.length;
      }
      // 截取当前四个元素的子列表
      List<Future> subList = futures.sublist(i, end);
      // 将子列表添加到结果列表中
      groupedList.add(subList);
    }
    try {
      for (var i = 0; i < groupedList.length; i++) {
        await Future.wait(groupedList[i]);
      }
    } catch (e) {
      hasError = true;
    }
    return hasError;
  }
}
