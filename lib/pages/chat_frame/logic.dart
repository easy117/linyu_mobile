import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart'
    show
    BoolExtension,
    Get,
    GetNavigation,
    GetxController,
    Inst,
    RxBool,
    RxString,
    StringExtension,
    obs;
import 'package:image_picker/image_picker.dart';
import 'package:linyu_mobile/api/chat_group_member.dart';
import 'package:linyu_mobile/api/chat_list_api.dart';
import 'package:linyu_mobile/api/msg_api.dart';
import 'package:linyu_mobile/api/video_api.dart';
import 'package:linyu_mobile/components/custom_flutter_toast/index.dart';
import 'package:linyu_mobile/utils/String.dart';
import 'package:linyu_mobile/utils/cropPicture.dart';
import 'package:linyu_mobile/utils/extension.dart';
import 'package:linyu_mobile/utils/getx_config/GlobalData.dart';
import 'package:linyu_mobile/utils/getx_config/config.dart';
import 'package:linyu_mobile/utils/web_socket.dart';
import 'package:dio/dio.dart' show MultipartFile, FormData;

import 'index.dart';

// class ChatFrameLogic extends GetxController {
class ChatFrameLogic extends Logic<ChatFramePage> {
  final _msgApi = MsgApi();
  final _chatListApi = ChatListApi();
  final _wsManager = WebSocketUtil();
  final _videoApi = VideoApi();
  final _chatGroupMemberApi = ChatGroupMemberApi();
  final TextEditingController msgContentController = TextEditingController();
  final ScrollController scrollController = ScrollController();
  final FocusNode focusNode = FocusNode(skipTraversal: true);
  final RxString panelType = "none".obs;
  late Map<String, dynamic> members = {};
  late List<dynamic> msgList = [];
  late String targetId = '';
  late dynamic chatInfo = {targetId: ''};
  late RxBool isSend = false.obs;
  late RxBool isRecording = false.obs;
  late RxBool isReadOnly = false.obs;
  StreamSubscription? _subscription;
  final GlobalData _globalData = Get.find<GlobalData>();

  // 分页相关
  int num = 20;
  int index = 0;
  bool isLoading = false;
  bool hasMore = true;

  void _eventListen() {
    // 监听消息
    _subscription = _wsManager.eventStream.listen((event) {
      if (event['type'] == 'on-receive-msg') {
        final data = event['content'];
        try {
          bool isRelevantMsg =
              (data['fromId'] == targetId && data['source'] == 'user') ||
                  (data['toId'] == targetId && data['source'] == 'group') ||
                  (data['fromId'] == _globalData.currentUserId &&
                      data['toId'] == targetId);
          if (isRelevantMsg) {
            if (data['msgContent']['type'] == 'retraction') {
              msgList = msgList.replace(newValue: data);
              _onRead();
              update([const Key('chat_frame')]);
              return;
            }
            _onRead();
            msgListAddMsg(event['content']);
          }
        } catch (e) {
          CustomFlutterToast.showErrorToast('处理消息时发生错误: $e');
        }
      }
    }, onError: (error) {
      CustomFlutterToast.showErrorToast('WebSocket发生错误: $error');
    });
  }

  // 获取群成员
  void _onGetMembers() async {
    if (chatInfo['type'] == 'group') {
      await _chatGroupMemberApi.list(targetId).then((res) {
        if (res['code'] == 0) {
          members = res['data'];
          update([const Key('chat_frame')]);
        }
      });
    }
  }

  // 获取消息记录
  Future<void> _onGetMsgRecode() async {
    if (isLoading) return; // 防止重复加载
    isLoading = true;
    update([const Key('chat_frame')]);

    try {
      final res = await _msgApi.record(targetId, index, num);

      if (res['code'] == 0 && res['data'] is List) { // 确认返回的数据类型
        msgList = res['data'];
        index += msgList.length;
        hasMore = msgList.isNotEmpty; // 判断是否还有更多数据
        update([const Key('chat_frame')]);
        scrollBottom();
      } else {
        CustomFlutterToast.showErrorToast('获取消息记录失败: ${res['message'] ?? '未知错误'}');
      }
    } catch (e) {
      CustomFlutterToast.showErrorToast('获取消息记录时发生错误: $e');
    } finally {
      isLoading = false;
      update([const Key('chat_frame')]);
    }
  }


  // 加载更多
  Future<void> _loadMore() async {
    if (isLoading || !hasMore) return;
    isLoading = true;
    update([const Key('chat_frame')]);
    try {
      final res = await _msgApi.record(targetId, index, num);
      if (res['code'] == 0) {
        if (res['data'].isEmpty) {
          hasMore = false;
        } else {
          final double previousScrollOffset = scrollController.position.pixels;
          final double previousMaxScrollExtent =
              scrollController.position.maxScrollExtent;

          msgList.insertAll(0, res['data']);
          index = msgList.length;
          hasMore = res['data'].length >= 0;

          WidgetsBinding.instance.addPostFrameCallback((_) {
            final double newMaxScrollExtent =
                scrollController.position.maxScrollExtent;
            final double newOffset = previousScrollOffset +
                (newMaxScrollExtent - previousMaxScrollExtent) -
                10;
            scrollController.animateTo(
              newOffset,
              duration: const Duration(milliseconds: 200),
              curve: Curves.fastOutSlowIn,
            );
          });
        }
      }
    } finally {
      isLoading = false;
      update([const Key('chat_frame')]);
    }
  }

  // 滚动到底部
  void scrollBottom() {
    if (scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        scrollController.animateTo(
          scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 500),
          curve: Curves.fastOutSlowIn,
        );
      });
    }
  }

  // 切换面板类型
  void toDetailsPage() {
    if (chatInfo['type'] == 'group') {
      // Get.toNamed('/chat_group_info', arguments: {'chatGroupId': targetId});
      Get.offAndToNamed('/chat_group_info',
          arguments: {'chatGroupId': targetId});
    } else {
      // Get.toNamed('/friend_info', arguments: {'friendId': targetId});
      Get.offAndToNamed('/friend_info', arguments: {'friendId': targetId});
    }
  }

  // 发送文本消息
  void sendTextMsg() async {
    if (StringUtil.isNullOrEmpty(msgContentController.text)) return;

    dynamic msg = {
      'toUserId': targetId,
      'source': chatInfo['type'],
      'msgContent': {'type': "text", 'content': msgContentController.text}
    };

    try {
      final res = await _msgApi.send(msg);
      if (res['code'] == 0) {
        isSend.value = false;
        msgContentController.clear(); // 使用clear()简化设置为空字符串
        msgListAddMsg(res['data']);
        _onRead();
      } else {
        CustomFlutterToast.showErrorToast('发送失败: ${res['message'] ?? '未知错误'}');
      }
    } catch (e) {
      CustomFlutterToast.showErrorToast('发送消息时发生错误: $e');
    }
  }

  void msgListAddMsg(msg) {
    if (kDebugMode) {
      print('msgListAddMsg: $msg');
    }
    msgList.add(msg);
    index = msgList.length;
    update([const Key('chat_frame')]);
    scrollBottom();
  }

  // 消息已读
  void _onRead() async {
    try {
      await _chatListApi.read(targetId);
      _globalData.onGetUserUnreadInfo();
    } catch (e) {
      CustomFlutterToast.showErrorToast('标记为已读时发生错误: $e');
    }
  }


  // 语音通话
  void onInviteVideoChat(isOnlyAudio) {
    _videoApi.invite(targetId, isOnlyAudio).then((res) {
      if (res['code'] == 0) {
        Get.toNamed('video_chat', arguments: {
          'userId': targetId,
          'isSender': true,
          'isOnlyAudio': isOnlyAudio,
        });
      }
    });
  }

  // 选择图片
  void selectFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles();
    final path = result?.files.single.path;
    if (path != null) {
      File file = File(path);
      onSendImgOrFileMsg(file, 'file');
    }
  }

  Future cropChatBackgroundPicture(ImageSource? type) async =>
      cropPicture(type, onUploadImg, isVariable: true);

  Future<void> onUploadImg(File file) async {
    onSendImgOrFileMsg(file, 'img');
  }

  // 发送图片或文件消息
  void onSendImgOrFileMsg(File file, type) async {
    if (StringUtil.isNullOrEmpty(file.path)) {
      return;
    }
    String fileName = file.path.split('/').last;
    final fileData =
    await MultipartFile.fromFile(file.path, filename: fileName);
    dynamic msg = {
      'toUserId': targetId,
      'source': chatInfo['type'],
      'msgContent': {
        'type': type,
        'content': jsonEncode({
          'name': fileName,
          'size': fileData.length,
        })
      }
    };
    _msgApi.send(msg).then((res) {
      if (res['code'] == 0) {
        if (StringUtil.isNotNullOrEmpty(res['data']?['id'])) {
          Map<String, dynamic> map = {};
          map["file"] = fileData;
          map['msgId'] = res['data']['id'];
          FormData formData = FormData.fromMap(map);
          _msgApi.sendMedia(formData).then((v) {
            msgListAddMsg(res['data']);
            _onRead();
          });
        }
      }
    });
  }

  // 发送语音消息
  void onSendVoiceMsg(filePath, time) async {
    if (StringUtil.isNullOrEmpty(filePath)) {
      return;
    }
    if (time == 0) {
      CustomFlutterToast.showSuccessToast('录制时间太短~');
      return;
    }
    MultipartFile file =
    await MultipartFile.fromFile(filePath, filename: 'voice.wav');
    dynamic msg = {
      'toUserId': targetId,
      'source': chatInfo['type'],
      'msgContent': {
        'type': "voice",
        'content': jsonEncode({
          'name': 'voice.wav',
          'size': file.length,
          'time': time,
        })
      }
    };
    _msgApi.send(msg).then((res) {
      if (res['code'] == 0) {
        if (StringUtil.isNotNullOrEmpty(res['data']?['id'])) {
          Map<String, dynamic> map = {};
          map["file"] = file;
          map['msgId'] = res['data']['id'];
          FormData formData = FormData.fromMap(map);
          _msgApi.sendMedia(formData).then((v) {
            msgListAddMsg(res['data']);
            _onRead();
          });
        }
      }
    });
  }

  //点击通话消息记录
  void onTapMsg(dynamic msg) {
    widget?.hidePanel();
    final msgContent = msg['msgContent'] as Map<String, dynamic>;
    // 点击文本消息（暂不处理）
    if (msgContent['type'] == 'text') return;
    final Map<String, dynamic> content = jsonDecode(msgContent['content']);
    // 点击通话消息拨打给对方
    if (msgContent['type'] == 'call') {
      if (content['type'] == 'video') {
        onInviteVideoChat(false);
      } else {
        onInviteVideoChat(true);
      }
    }
  }

  //撤回消息
  void retractMsg(dynamic data, dynamic msg) async {
    try {
      final result = await _msgApi.retract(msg['id'], targetId);
      if (result['code'] == 0) {
        msgList = msgList.replace(oldValue: msg, newValue: result['data']);
        CustomFlutterToast.showSuccessToast('撤回成功');
      } else {
        CustomFlutterToast.showErrorToast(
            '撤回失败: ${result['message'] ?? '未知错误'}');
      }
    } catch (e) {
      CustomFlutterToast.showErrorToast('撤回失败: $e');
    } finally {
      isLoading = false;
      update([const Key('chat_frame')]);
    }
  }

  // 重新编辑消息
  void reEditMsg(dynamic msg) async {
    if (kDebugMode) print(msg);
    final result = await _msgApi.reEdit(msg['id']);
    if (result['code'] == 0) {
      if (kDebugMode) print(result['data']);
      msgContentController.text = result['data']['msgContent']['content'];
      isRecording.value = false;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => focusNode.requestFocus());
      update([const Key('chat_frame')]);
    }
  }

  @override
  void onInit() {
    chatInfo = Get.arguments?['chatInfo'] ?? {};
    targetId = chatInfo['fromId'] ?? '';
    super.onInit();
    _onGetMembers();
    _onGetMsgRecode();
    _eventListen();
    _onRead();
    // 添加滚动监听
    scrollController.addListener(() {
      if (scrollController.hasClients) {
        if (scrollController.position.pixels ==
            scrollController.position.minScrollExtent) {
          _loadMore();
        }
      }
    });
  }

  @override
  void onClose() {
    super.onClose();
    msgContentController.dispose();
    scrollController.dispose();
    _subscription?.cancel();
    focusNode.dispose();
  }
}
