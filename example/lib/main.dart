import 'dart:async';
import 'dart:io';

import 'package:isolate_pool/isolate_pool.dart';

void main() async {
  print('future线程池测试');
  await futureTest();
  print('future线程池测试结束');
  print('isolate线程池测试');
  await isolateTest();
  print('isolate线程池测试结束');
}

/// future pool test
Future<void> futureTest() async {
  List<CompletableFuture> fs = List.generate(1000, (index) => index).map((e) => CompletableFuture.runAsync(() async{
    await Future.delayed(Duration(milliseconds: 100));
    print('$e:${DateTime.now()} ');
    return e;
  })).toList();
  await CompletableFuture.join(fs);
  print(fs.map((e) => e.result).length);
}

/// isolate pool test
Future<void> isolateTest() async {
  IsolateExecutor isolateExecutor = IsolateExecutor(maximumPoolSize: Platform.numberOfProcessors, keepActiveTime: 1);
  List<CompletableIsolate> list =
  List.generate(1000, (index) => index).map((index) => CompletableIsolate.runAsync(test, index, isolateExecutor: isolateExecutor)).toList();
  // for (var value in list) {
  //   value.cancel();
  // }
  await CompletableIsolate.join(list);
  print(list.map((e) => e.result).where((element) => element != null).length);
}

Future<String> test(int index) async {
  await Future.delayed(Duration(milliseconds: 100));
  String p = '$index ${DateTime.now()}';
  print(p);
  return p;
}
