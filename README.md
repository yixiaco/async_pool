# async_pool [![pub package](https://img.shields.io/badge/pub-v0.1.1-blue.svg)](https://pub.dev/packages/async_pool)

A future and async thread pool project.has a syntax similar to CompletableFuture in java

## CompletableFuture
```dart
List<CompletableFuture> fs = List.generate(1000, (index) => index).map((e) => CompletableFuture.runAsync(() async{
    await Future.delayed(Duration(milliseconds: 100));
    print('$e:${DateTime.now()} ');
    return e;
  })).toList();

  /// wait for the completion of all futures
  await CompletableFuture.join(fs);
  print(fs.map((e) => e.result).length);
```

## CompletableIsolate
```dart
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
```