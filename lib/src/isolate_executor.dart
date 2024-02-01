import 'dart:async';
import 'dart:collection';
import 'dart:developer';
import 'dart:io';
import 'dart:isolate';

typedef ComputeCallback<Q, R> = FutureOr<R> Function(Q message);
typedef ComputeCallback0<Q> = FutureOr<void> Function(Q message);
typedef VoidCallback<T> = void Function(T t);

/// 退出标识
const _exitFlag = '\$1';

/// 异步执行支持
class CompletableIsolate<T> {
  /// 运行结果
  T? result;

  /// 是否完成
  bool isComplete = false;

  /// 错误信息
  dynamic error;

  /// 错误堆栈
  StackTrace? stackTrace;

  /// 是否发生了错误
  bool isError = false;

  /// 公共线程池配置
  static final IsolateExecutor _isolateExecutor = IsolateExecutor(
    maximumPoolSize: Platform.numberOfProcessors * 2,
  );

  /// 正确执行的回调
  List<VoidCallback<T?>>? _callback;

  /// 错误执行的回调
  List<Function>? _onError;

  /// 不管是错误还是正确执行的回调
  List<Function>? _onComplete;

  /// 取消执行的回调
  List<Function>? _onCancel;

  /// 内部维护的一个异步id
  int? _asyncId;

  /// 当前线程池配置
  late IsolateExecutor _isolateExecutor0;

  /// 执行一个异步任务
  /// 该任务必须是一个全局方法或者静态方法
  static CompletableIsolate<T> runAsync<Q, T>(
    ComputeCallback<Q, T> run,
    Q message, {
    IsolateExecutor? isolateExecutor,
    String debugLabel = 'CompletableIsolate',
  }) {
    CompletableIsolate<T> completableFuture = CompletableIsolate<T>();

    ///初始化线程池
    isolateExecutor ??= _isolateExecutor;
    completableFuture._isolateExecutor0 = isolateExecutor;

    /// 时间切片
    final Flow flow = Flow.begin();
    Timeline.startSync('$debugLabel: start', flow: flow);
    final ReceivePort resultPort = ReceivePort();
    final ReceivePort errorPort = ReceivePort();
    Timeline.finishSync();
    // 提交任务
    completableFuture._asyncId =
        isolateExecutor.execute<_CompletableIsolateConfiguration<Q, T>>(
      CompletableIsolate._run,
      _CompletableIsolateConfiguration<Q, T>(
        callback: run,
        message: message,
        resultPort: resultPort.sendPort,
        errorPort: errorPort.sendPort,
        flowId: flow.id,
        debugLabel: debugLabel,
      ),
    );

    /// 监听任务回调
    resultPort.listen((result) {
      Timeline.startSync('$debugLabel: end', flow: Flow.end(flow.id));
      completableFuture.result = result;
      resultPort.close();
      errorPort.close();
      Timeline.finishSync();
      completableFuture._runCallback();
      completableFuture._completeCallback();
    });
    errorPort.listen((errorData) {
      Timeline.startSync('$debugLabel: end', flow: Flow.end(flow.id));
      completableFuture.error = errorData[0];
      completableFuture.stackTrace = errorData[1];
      resultPort.close();
      errorPort.close();
      Timeline.finishSync();
      completableFuture._errorCallback();
      completableFuture._completeCallback();
    });
    return completableFuture;
  }

  /// 正确执行回调
  void _runCallback() {
    if (_callback != null && _callback!.isNotEmpty) {
      for (var element in _callback!) {
        element(result);
      }
      _callback!.clear();
    }
  }

  /// 错误回调
  void _errorCallback() {
    isError = true;
    if (_onError != null && _onError!.isNotEmpty) {
      for (var element in _onError!) {
        try {
          element(error, stackTrace);
        } catch (e) {
          print(e);
        }
      }
      _onError!.clear();
    }
  }

  /// 完成回调
  void _completeCallback() {
    isComplete = true;
    if (_onComplete != null && _onComplete!.isNotEmpty) {
      for (var element in _onComplete!) {
        element();
      }
      _onComplete!.clear();
    }
  }

  /// 回调
  void then<R>(VoidCallback onValue, {Function? onError}) {
    if (isComplete) {
      if (isError && onError != null) {
        onError(error);
      } else {
        onValue(result);
      }
    } else {
      (_callback ??= []).add(onValue);
      if (onError != null) {
        (_onError ??= []).add(onError);
      }
    }
  }

  /// 无论是否完成，都发生回调事件
  void whenComplete(FutureOr<void> Function() action) {
    if (isComplete) {
      // 如果已经完成任务，则立即触发事件
      action();
    }
    (_onComplete ??= []).add(action);
  }

  /// 取消事件
  void onCancel(FutureOr<void> Function() action) {
    if (!isComplete) {
      (_onCancel ??= []).add(action);
    }
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

  /// 等待所有任务完成
  static Future<Iterable<CompletableIsolate<T>>> join<T>(
      Iterable<CompletableIsolate<T>> completableIsolate) async {
    Completer<Iterable<CompletableIsolate<T>>> completer = Completer();
    if (completableIsolate.isEmpty) {
      completer.complete(Iterable.empty());
    }
    int count = completableIsolate.length;
    Set<int> ids = {};
    for (var f in completableIsolate) {
      void sub() {
        if (!ids.contains(f.hashCode)) {
          ids.add(f.hashCode);
          count--;
          if (count == 0) {
            completer.complete(completableIsolate);
          }
        }
      }

      f.whenComplete(sub);
      f.onCancel(sub);
    }
    return completer.future;
  }

  /// 取消任务，无法取消正在执行中的任务
  bool cancel() {
    bool result = _isolateExecutor0.cancel(_asyncId!);
    if (result) {
      isComplete = true;
      if (_onCancel != null && _onCancel!.isNotEmpty) {
        for (var element in _onCancel!) {
          element();
        }
        _onCancel!.clear();
      }
    }
    return result;
  }

  /// 执行任务
  static void _run<T, R>(
      _CompletableIsolateConfiguration<T, R> configuration) async {
    try {
      final R result = await Timeline.timeSync(
        configuration.debugLabel,
        () async {
          final FutureOr<R> applicationResult = await configuration.apply();
          return await applicationResult;
        },
        flow: Flow.step(configuration.flowId),
      );
      Timeline.timeSync(
        '${configuration.debugLabel}: returning result',
        () => configuration.resultPort.send(result),
        flow: Flow.step(configuration.flowId),
      );
    } catch (e, s) {
      Timeline.timeSync(
        '${configuration.debugLabel}: returning result',
        () => configuration.errorPort.send([e, s]),
        flow: Flow.step(configuration.flowId),
      );
    }
  }
}

/// isolate 任务的参数
class _CompletableIsolateConfiguration<Q, R> {
  /// 需要执行的回调方法
  final ComputeCallback<Q, R> callback;

  /// 用户自定义的参数
  final Q message;

  /// 接收结果消息的通道
  final SendPort resultPort;

  /// 接收错误消息的通道
  final SendPort errorPort;

  /// 事件标签
  final String debugLabel;

  /// 事件流id标识
  final int flowId;

  /// 需要在线程中执行的任务
  FutureOr<R> apply() => callback(message);

  const _CompletableIsolateConfiguration({
    required this.callback,
    required this.message,
    required this.resultPort,
    required this.debugLabel,
    required this.flowId,
    required this.errorPort,
  });
}

/// 隔离线程池
class IsolateExecutor {
  /// 线程池的名称，该名称会作为isolate的名称前缀
  final String executorName;

  /// 最大线程数
  final int maximumPoolSize;

  /// 核心线程数
  final int corePoolSize;

  /// 最大空闲时间(秒)
  final int keepActiveTime;

  /// 保存所有待运行或者运行中的任务
  final Map<String, _Work> _works = {};

  /// 线程id
  static int _isolateId = 0;

  /// 异步id
  int _asyncId = 0;

  /// 线程池是否已经关闭
  bool _shop = false;

  /// 当前活跃的线程
  int activeThread = 0;

  final ListQueue<_IsolateConfiguration> _isolateConfiguration = ListQueue();

  IsolateExecutor({
    this.executorName = 'IsolateExecutor',
    required this.maximumPoolSize,
    this.corePoolSize = 0,
    this.keepActiveTime = 120,
  })  : assert(executorName.isNotEmpty),
        assert(corePoolSize >= 0),
        assert(maximumPoolSize > 0 && maximumPoolSize >= corePoolSize),
        assert(keepActiveTime > 0);

  /// 执行线程
  int execute<Q>(ComputeCallback0<Q> callback, Q params) {
    assert(!_shop, 'isolate executor has been closed!');
    int id = ++_asyncId;
    if (activeThread < maximumPoolSize) {
      _addIsolate(
        _IsolateConfiguration<Q>(id, callback, params),
        activeThread < corePoolSize,
      );
    } else {
      _isolateConfiguration.add(_IsolateConfiguration<Q>(
        id,
        callback,
        params,
      ));
      _notify();
    }
    return id;
  }

  /// 取消任务，无法取消正在执行的任务
  bool cancel(int asyncId) {
    if (_isolateConfiguration.any((element) => element.id == asyncId)) {
      _isolateConfiguration.removeWhere((element) => element.id == asyncId);
      return true;
    }
    return false;
  }

  /// 新增线程
  Future<void> _addIsolate<Q>(
    _IsolateConfiguration isolateConfiguration,
    bool isCore,
  ) async {
    activeThread++;
    var exitPort = ReceivePort();
    var resultPort = ReceivePort();
    _Work work = _Work(
      isCore: isCore,
      exitPort: exitPort,
      resultPort: resultPort,
    );
    String debugName = '${executorName}_${++_isolateId}';
    Isolate isolate = await Isolate.spawn(
      _spawn,
      _WorkConfiguration(
        resultPort: resultPort.sendPort,
        keepActiveTime: keepActiveTime,
        isCore: isCore,
      ),
      onExit: exitPort.sendPort,
      debugName: debugName,
    );
    exitPort.listen((message) {
      work.isExit = true;
      activeThread--;
      _works.remove(debugName);
    });
    work.isolate = isolate;
    resultPort.listen((message) {
      if (message is SendPort) {
        /// 获取通信对象
        work.receivePort = message;
        work.isRun = true;
        _works[debugName] = work;
        work.send(isolateConfiguration);
      } else if (message == _exitFlag) {
        // 退出
        _works.remove(debugName);
        work.dismiss();
        activeThread--;
      } else if (message is int) {
        // 任务执行结束
        work.isRun = false;
      }
      _notify();
    });
  }

  /// 停止线程池
  void shutdown() {
    assert(!_shop, 'isolate executor has been closed!');
    _shop = true;
    _works.forEach((key, value) {
      value.dismiss();
    });
    _works.clear();
  }

  /// 通知执行任务
  void _notify() {
    if (!_shop) {
      var idleWorks = _works.values
          .where((element) => !element.isRun && !element.isExit)
          .toList();
      // 查询空闲的线程是否满足执行所有任务
      for (var work in idleWorks) {
        if (_isolateConfiguration.isNotEmpty) {
          work.send(_isolateConfiguration.removeFirst());
        } else {
          return;
        }
      }
      // 如果空闲的线程不足执行所有任务，则新增最多线程池任务
      if (activeThread < maximumPoolSize) {
        for (int i = 0; i < maximumPoolSize - activeThread; i++) {
          if (_isolateConfiguration.isNotEmpty) {
            _addIsolate(
              _isolateConfiguration.removeFirst(),
              false,
            );
          }
        }
      }
    }
  }
}

/// 存储线程信息
class _Work {
  /// 接收线程消息的通道
  final ReceivePort resultPort;

  /// 接收退出的通道
  final ReceivePort exitPort;

  /// 是否是核心线程
  final bool isCore;

  /// 代表线程对象
  late Isolate? isolate;

  /// 发送给线程的消息通道
  late SendPort? receivePort;

  /// 是否退出
  bool isExit = false;

  /// 是否正在运行
  bool isRun = false;

  _Work({
    required this.isCore,
    required this.resultPort,
    required this.exitPort,
  });

  /// 给线程发送一个任务
  void send(_IsolateConfiguration isolateConfiguration) {
    isRun = true;
    receivePort!.send(isolateConfiguration);
  }

  /// 强制关闭该线程
  void dismiss() {
    isRun = false;
    isExit = true;
    isolate!.kill(priority: Isolate.immediate);
    resultPort.close();
    exitPort.close();
  }
}

/// 线程参数
class _WorkConfiguration {
  /// 接收线程发送的消息通道
  final SendPort resultPort;

  /// 空闲时间，只针对非核心线程
  final int keepActiveTime;

  /// 是否是核心线程
  final bool isCore;

  const _WorkConfiguration({
    required this.resultPort,
    required this.keepActiveTime,
    required this.isCore,
  });
}

/// 执行任务
class _IsolateConfiguration<Q> {
  const _IsolateConfiguration(this.id, this.callback, this.message);

  /// 任务id
  final int id;

  /// 任务体
  final ComputeCallback0<Q> callback;

  /// 任务参数
  final Q message;

  /// 执行任务体
  FutureOr apply() => callback(message);
}

/// 执行方法
Future<void> _spawn(_WorkConfiguration workConfiguration) async {
  ReceivePort receivePort = ReceivePort();
  bool isRun = false;
  int keepActiveTime = 0;
  receivePort.listen((message) async {
    if (message is _IsolateConfiguration) {
      isRun = true;
      keepActiveTime = 0;
      try {
        final FutureOr applicationResult = await message.apply();
        await applicationResult;
      } catch (e) {
        print(e);
      }
      workConfiguration.resultPort.send(message.id);
      isRun = false;
    }
  });
  workConfiguration.resultPort.send(receivePort.sendPort);
  if (!workConfiguration.isCore) {
    // 每一秒检查是否在运行，如果不在运行，超出空闲时间，且不是核心线程，则关闭该线程
    Timer.periodic(Duration(seconds: 1), (timer) {
      if (!isRun) {
        keepActiveTime++;
      }
      if (keepActiveTime > workConfiguration.keepActiveTime && !isRun) {
        timer.cancel();
        receivePort.close();
        workConfiguration.resultPort.send(_exitFlag);
      }
    });
  }
}
