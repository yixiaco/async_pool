import 'dart:io';

import 'package:async_pool/async_pool.dart';

void main() async {
  /*
  List<CompletableFuture> fs = List.generate(1000, (index) => index).map((e) => CompletableFuture.runAsync(() async{
    // await Future.delayed(Duration(milliseconds: 100));
    print('$e:${DateTime.now()} ');
    return e;
  })).toList();
  await CompletableFuture.join(fs);
  print(fs.map((e) => e.result).length);*/
  IsolateExecutor isolateExecutor = IsolateExecutor(
      maximumPoolSize: Platform.numberOfProcessors, keepActiveTime: 1);
  List<CompletableIsolate> list = List.generate(100, (index) => index)
      .map((index) => CompletableIsolate.runAsync(test, index,
          isolateExecutor: isolateExecutor))
      .toList();
  for (var value in list) {
    value.then((t) {
      print(t);
    });
    // value.cancel();
  }
  await CompletableIsolate.join(list);
  print(list.map((e) => e.result).where((element) => element != null).length);
}

Future<String> test(int index) async {
  await Future.delayed(Duration(milliseconds: 200));
  String p = '$index ${DateTime.now()}';
  // print(p);
  return p;
}
