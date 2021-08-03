import 'dart:async';
import 'dart:collection';

import 'isolate_executor.dart';

typedef AsyncRun = Future Function();

/// 提供最大并发执行数的Future队列，防止并发突破内存溢出
class CompletableFuture<T> {
  T? result;
  bool isComplete = false;
  dynamic error;
  StackTrace? stackTrace;
  bool isError = false;
  static FutureExecutor _futureExecutor = FutureExecutor();
  List<VoidCallback>? _callback;
  List<Function>? _onError;
  List<Function>? _onComplete;
  List<Function>? _onCancel;
  bool _isRun = false;
  bool _isCancel = false;

  static CompletableFuture<T> runAsync<T>(AsyncRun run,
      {FutureExecutor? futureExecutor}) {
    CompletableFuture<T> completableFuture = CompletableFuture<T>();
    if (futureExecutor == null) {
      futureExecutor = _futureExecutor;
    }
    futureExecutor.execute(() async {
      try {
        if (!completableFuture._isCancel) {
          completableFuture._isRun = true;
          completableFuture.result = await run();
          completableFuture._isRun = false;
          completableFuture._runCallback();
        }
      } catch (a, s) {
        completableFuture.error = a;
        completableFuture.stackTrace = s;
        completableFuture._errorCallback();
      } finally {
        completableFuture._completeCallback();
      }
    });
    return completableFuture;
  }

  /// 正确执行回调
  void _runCallback() {
    if (_callback != null && _callback!.isNotEmpty) {
      _callback!.forEach((element) {
        element(result);
      });
      _callback!.clear();
    }
  }

  /// 错误回调
  void _errorCallback() {
    isError = true;
    if (_onError != null && _onError!.isNotEmpty) {
      _onError!.forEach((element) {
        try {
          element(error, stackTrace);
        } catch (e) {
          print(e);
        }
      });
      _onError!.clear();
    }
  }

  /// 完成回调
  void _completeCallback() {
    isComplete = true;
    if (_onComplete != null && _onComplete!.isNotEmpty) {
      _onComplete!.forEach((element) => element());
      _onComplete!.clear();
    }
  }

  /// 回调
  void then<R>(VoidCallback onValue, {Function? onError}) {
    if (isComplete) {
      if (isError && onError != null) {
        onError(error);
      } else
        onValue(result);
    } else {
      if (_callback == null) {
        _callback = [];
      }
      _callback!.add(onValue);
      if (onError != null) {
        if (_onError == null) {
          _onError = [];
        }
        _onError!.add(onError);
      }
    }
  }

  /// 无论是否完成，都发生回调事件
  void whenComplete(FutureOr<void> action()) {
    if (isComplete) {
      // 如果已经完成任务，则立即触发事件
      action();
    } else if (_onComplete == null) {
      _onComplete = [];
    }
    _onComplete!.add(action);
  }

  /// 取消事件
  void onCancel(FutureOr<void> action()) {
    if (!isComplete) {
      if (_onCancel == null) {
        _onCancel = [];
      }
      _onCancel!.add(action);
    }
  }

  /// 等待所有任务完成
  static Future<List<CompletableFuture<T>>> join<T>(
      List<CompletableFuture<T>>? fs) async {
    Completer<List<CompletableFuture<T>>> completer = Completer();
    if (fs == null || fs.isEmpty) {
      completer.complete();
    }
    int count = fs!.length;
    List<int> ids = [];
    for (var f in fs) {
      void sub() {
        if (!ids.contains(f.hashCode)) {
          ids.add(f.hashCode);
          count--;
          if (count == 0) {
            completer.complete(fs);
          }
        }
      }

      f.whenComplete(sub);
      f.onCancel(sub);
    }
    return completer.future;
  }

  /// 等待结果
  Future<T> wait() {
    Completer<T> completer = Completer();
    then((result) {
      completer.complete(result);
    }, onError: (e, s) {
      completer.completeError(e, s);
    });
    return completer.future;
  }

  /// 取消任务，无法取消正在运行的任务
  bool cancel() {
    if (!_isRun) {
      _isCancel = true;
      isComplete = true;
      Future(() {
        if (_onCancel != null && _onCancel!.isNotEmpty) {
          _onCancel!.forEach((element) => element());
          _onCancel!.clear();
        }
      });
      return true;
    }
    return false;
  }
}

/// 限制Future最大执行量，提交Future，等待安排执行任务
class FutureExecutor {
  final int maxSize;

  /// 等待队列
  final ListQueue<AsyncRun> _waitQueue = ListQueue();
  int _currentRun = 0;

  FutureExecutor({
    this.maxSize = 20,
  }) : assert(maxSize > 0);

  /// 提交一个任务执行
  void execute(AsyncRun run) {
    if (_currentRun < maxSize) {
      _currentRun++;
      _run(run);
    } else {
      _waitQueue.add(run);
    }
  }

  /// 批量执行任务
  void executeList(List<AsyncRun> runs) {
    for (var run in runs) {
      execute(run);
    }
  }

  /// 任务执行
  Future _run(AsyncRun run) async {
    try {
      return await run();
    } catch (e) {
      rethrow;
    } finally {
      _currentRun--;
      if (_waitQueue.isNotEmpty) {
        execute(_waitQueue.removeFirst());
      }
    }
  }

  int getActiveFuture() => _currentRun;

  /// 清空所有等待中的任务队列
  /// 被清理的任务，永远不会被执行到
  void clearAll() {
    _waitQueue.clear();
  }
}
