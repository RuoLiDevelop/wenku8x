import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wenku8x/http/api.dart';
import 'package:wenku8x/modals/chapter.dart';
import 'package:wenku8x/utils/log.dart';

import 'page_string.dart';

enum Menu { none, wrapper, catalog, theme, reader, style }

class ReaderView extends StatefulHookConsumerWidget {
  final String aid;
  final String name;
  const ReaderView({required this.aid, required this.name, Key? key}) : super(key: key);

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _ReaderViewState();
}

class _ReaderViewState extends ConsumerState<ReaderView> with TickerProviderStateMixin {
  late Directory docDir;
  late double statusBarHeight;
  late double bottomBarHeight;
  // 页面宽度
  late dynamic pageWidth;
  // 手指滑动判定
  final distance = 24;
  // 按下座标
  double tapDownPos = 0.0;
  // 抬起座标
  double tapUpPos = 0.0;
  // 位移比例
  double extraRate = 1.0;
  // 总页数
  int totalPage = 0;
  // 当前章节
  int chapterIndex = 0;
  // 是否在获取章节
  bool fetchingNext = false;
  bool fetchingPrevious = false;

  // 工具栏状态
  // Menu menuStatus = Menu.none;

  final _regExpBody = r'<body[^>]*>([\s\S]*)<\/body>';
  @override
  Widget build(BuildContext context) {
    final loading = useState(true);
    final currentPage = useState(0);
    final mediaQuery = MediaQuery.of(context);
    final screenWidth = mediaQuery.size.width;
    final screenHeight = mediaQuery.size.height;
    final chapters = useState<List<Chapter>>([]);
    final fileUri = useState<String?>(null);
    final webViewController = useState<InAppWebViewController?>(null);
    final enableGestureListener = useState(true);
    final menuStatus = useState<Menu>(Menu.none);

    // 获取目录
    fetchCatalog(String aid) async {
      docDir = await getApplicationDocumentsDirectory();
      final dir = Directory("${docDir.path}/books/$aid");
      if (!dir.existsSync()) dir.createSync(recursive: true);
      List<Chapter> cpts = [];
      var res = await API.getNovelIndex(aid);
      if (res != null) {
        for (var element in res.children[2].children) {
          if (element.toString().length > 2) {
            int i = 0;
            for (var node in element.children) {
              if (node.toString().length > 2) {
                if (i != 0) {
                  cpts.add(Chapter(node.getAttribute("cid").toString(), node.innerText));
                }
              }
              i++;
            }
          }
        }
        chapters.value = cpts;
      }
    }

    // 获取内容
    Future fetchContent(String aid, String cid, String chapterName) async {
      var res = await API.getNovelContent(aid, cid);
      List<String> arr = res.split(RegExp(r"\n\s*|\s{2,}"));
      arr.removeRange(0, 2);
      String content = arr.map((e) => """<p>$e</p>""").join("\n");
      String html = getPageString(widget.name, chapterName, content, statusBarHeight, bottomBarHeight);
      final file = File("${docDir.path}/books/$aid/$cid.html");
      file.writeAsStringSync(html);
      fileUri.value = "file://${file.path}";
    }

    onPointerDown(PointerDownEvent event) {
      tapDownPos = event.position.dx;
    }

    onPointerMove(PointerMoveEvent event) {
      if (enableGestureListener.value) {
        webViewController.value!.scrollBy(x: (-event.delta.dx * extraRate).round(), y: 0);
      }
    }

    onPointerUp(
      PointerUpEvent event,
    ) {
      if (!enableGestureListener.value) return;
      tapUpPos = event.position.dx;
      double res = (tapUpPos - tapDownPos);
      double resAbs = res.abs();
      if (resAbs > distance) {
        if (res < 0) {
          currentPage.value++;
        } else {
          currentPage.value--;
        }
      } else {
        // 视为点击事件
        double tapUpPosY = event.position.dy;
        if ((tapUpPos > screenWidth / 3 && tapUpPos < 2 * screenWidth / 3) &&
            (tapUpPosY > screenHeight / 3 && tapUpPosY < 2 * screenHeight / 3)) {
          if (menuStatus.value == Menu.none) {
            menuStatus.value = Menu.wrapper;
          } else {
            menuStatus.value = Menu.none;
          }
        }
      }
      webViewController.value!.scrollTo(x: (pageWidth * currentPage.value).round(), y: 0, animated: true);
    }

    fetchExtraChapter(String uri, String title) async {
      File file = File(uri.replaceAll("file://", ""));
      String htmlSrc = file.readAsStringSync();
      var bodySrc = RegExp(_regExpBody).firstMatch(htmlSrc)!.group(0);
      var a = await webViewController.value!.evaluateJavascript(source: """
ReaderJs.appendChapter(`$bodySrc`,`$title`)
""");
      Log.d(a, "aaa");
    }

    useEffect(() {
      if (Platform.isAndroid) {
        extraRate = mediaQuery.devicePixelRatio;
      }
      statusBarHeight = mediaQuery.padding.top;
      bottomBarHeight = mediaQuery.padding.bottom;
      fetchCatalog(widget.aid);
      return () {};
    }, []);

    useEffect(() {
      var cv = chapters.value;
      if (cv.isNotEmpty) {
        // chapters.value.take(3).forEach((element) {
        //   Log.d(element.json);
        // });
        fetchContent(widget.aid, cv[chapterIndex].cid, cv[chapterIndex].name);
      }
      return () {};
    }, [chapters.value]);

    useEffect(() {
      Log.d(fileUri.value, "fv");
      var controller = webViewController.value;
      if (controller != null && fileUri.value != null) {
        // Log.d(fileUri.value, "fv");
        if (totalPage == 0) {
          controller.addJavaScriptHandler(
              handlerName: "notifySize",
              callback: (params) {
                pageWidth = params[0] * extraRate;
              });
          controller.addJavaScriptHandler(
              handlerName: "onBookReady",
              callback: (params) {
                loading.value = false;
              });
          controller.addJavaScriptHandler(
              handlerName: "onPagingSetup",
              callback: (params) {
                totalPage = params[2];
                fetchingNext = false;
              });
          controller.loadUrl(urlRequest: URLRequest(url: WebUri(fileUri.value!)));
        } else {
          Log.d("已经加载过了");
          fetchExtraChapter(fileUri.value!, chapters.value[chapterIndex].name);
        }
      }
      return () {};
    }, [fileUri.value, webViewController.value]);

    useEffect(() {
      if (currentPage.value == totalPage - 3 && !fetchingNext) {
        Log.d("要加载下一章了");
        fetchingNext = true;
        var cpts = chapters.value;
        chapterIndex++;
        fetchContent(widget.aid, cpts[chapterIndex].cid, cpts[chapterIndex].name);
      }
      return () {};
    }, [currentPage.value]);

    // 工具条状态监听
    useEffect(() {
      if (menuStatus.value != Menu.none) {
        Log.d("显示最外层菜单");
      } else {
        Log.d("收起菜单");
      }
      return () {};
    }, [menuStatus.value]);

    return Material(
        child: Stack(
      children: [
        Listener(
            onPointerMove: onPointerMove,
            onPointerUp: (event) => onPointerUp(
                  event,
                ),
            onPointerDown: onPointerDown,
            behavior: HitTestBehavior.translucent,
            child: InAppWebView(
              onWebViewCreated: (controller) {
                webViewController.value = controller;
              },
              gestureRecognizers: {
                Factory<OneSequenceGestureRecognizer>(
                  () => LongPressGestureRecognizer(),
                )
              },
              initialSettings: InAppWebViewSettings(
                  pageZoom: 1,
                  userAgent: "ReaderJs/Client",
                  verticalScrollBarEnabled: false,
                  horizontalScrollBarEnabled: false,
                  disableHorizontalScroll: true,
                  disableVerticalScroll: true),
            )),
        Positioned(
            top: 0,
            left: 0,
            child: AnimatedContainer(
                width: screenWidth,
                height: menuStatus.value == Menu.wrapper ? mediaQuery.padding.top + 48 : 0,
                duration: const Duration(milliseconds: 100),
                padding: EdgeInsets.only(top: MediaQuery.of(context).viewPadding.top),
                color: const Color(0xff66ccff),
                child: Row(children: [
                  Flexible(
                    child: IconButton(
                        onPressed: () {
                          GoRouter.of(context).pop();
                        },
                        icon: const Icon(
                          Icons.arrow_back,
                          color: Colors.black,
                        )),
                  ),
                  Expanded(
                      child: Text(
                    widget.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ))
                ]))),
        loading.value
            ? Container(
                color: const Color(0xfff7f1e8),
                alignment: Alignment.center,
                child: const SizedBox(
                  width: 42,
                  height: 42,
                  child: CircularProgressIndicator(),
                ))
            : const SizedBox.shrink()
      ],
    ));
  }
}
