#import "LumePythonController.h"
#include <Python.h>

@interface LumePythonController ()
@property(nonatomic, strong) FlutterMethodChannel *channel;
@property(nonatomic, strong) dispatch_queue_t worker;
@property(nonatomic, strong) NSMutableSet<NSString *> *loadedSources;
@property(nonatomic, assign) PyObject *runFunction;
@end

static LumePythonController *LumePythonHost;

// Source-owned background handlers may call after the foreground call returns.
// Loaded source membership is synchronized; waiting releases the GIL.
static PyObject *LumeHostInvoke(PyObject *self, PyObject *args) {
  const char *request;
  if (!PyArg_ParseTuple(args, "s", &request)) return NULL;
  LumePythonController *host = LumePythonHost;
  NSString *json = [NSString stringWithUTF8String:request];
  NSDictionary *decoded = json ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
  NSString *source = [decoded isKindOfClass:NSDictionary.class] && [decoded[@"sourceId"] isKindOfClass:NSString.class] ? decoded[@"sourceId"] : nil;
  BOOL available = NO;
  @synchronized(host) { available = source && [host.loadedSources containsObject:source]; }
  if (!json || !available) {
    PyErr_SetString(PyExc_RuntimeError, "Python host is unavailable");
    return NULL;
  }
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
  __block NSString *response = nil;
  __block BOOL finished = NO;
  Py_BEGIN_ALLOW_THREADS
  dispatch_async(dispatch_get_main_queue(), ^{
    [host.channel invokeMethod:@"host"
                     arguments:@{@"sourceId": source, @"request": json}
                        result:^(id value) {
      @synchronized(semaphore) {
        if (!finished && [value isKindOfClass:NSString.class]) response = value;
        finished = YES;
      }
      dispatch_semaphore_signal(semaphore);
    }];
  });
  dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 31 * NSEC_PER_SEC));
  @synchronized(semaphore) { finished = YES; }
  Py_END_ALLOW_THREADS
  if (!response) {
    PyErr_SetString(PyExc_TimeoutError, "Python host request timed out");
    return NULL;
  }
  return PyUnicode_FromString(response.UTF8String);
}

static PyMethodDef LumeHostMethods[] = {
  {"invoke", LumeHostInvoke, METH_VARARGS, "Invoke a source-bound host operation."},
  {NULL, NULL, 0, NULL}
};
static struct PyModuleDef LumeHostModule = {
  PyModuleDef_HEAD_INIT, "_lume_host", NULL, -1, LumeHostMethods
};
static PyObject *PyInit_lume_host(void) { return PyModule_Create(&LumeHostModule); }

@implementation LumePythonController

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  LumePythonController *host = [[LumePythonController alloc] init];
  host.channel = [FlutterMethodChannel methodChannelWithName:@"lumebox/python_sources"
                                            binaryMessenger:registrar.messenger];
  host.worker = dispatch_queue_create("lumebox.python.sources", DISPATCH_QUEUE_SERIAL);
  host.loadedSources = [NSMutableSet set];
  LumePythonHost = host;
  [registrar addMethodCallDelegate:host channel:host.channel];
}

- (BOOL)prepareRuntime {
  if (self.runFunction) return YES;
  NSString *root = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"python"];
  NSString *standard = [root stringByAppendingPathComponent:@"lib/python3.13"];
  NSString *packages = [root stringByAppendingPathComponent:@"packages"];
  NSString *bootstrap = [root stringByAppendingPathComponent:@"lume_python.py"];
  if (![NSFileManager.defaultManager fileExistsAtPath:bootstrap]) return NO;
  if (!Py_IsInitialized()) {
    if (PyImport_AppendInittab("_lume_host", PyInit_lume_host) != 0) return NO;
    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.write_bytecode = 0;
    config.buffered_stdio = 0;
    config.install_signal_handlers = 0;
    config.module_search_paths_set = 1;
    PyStatus status = PyConfig_SetBytesString(&config, &config.home, root.UTF8String);
    for (NSString *path in @[standard, [standard stringByAppendingPathComponent:@"lib-dynload"], packages, root]) {
      if (PyStatus_Exception(status)) break;
      wchar_t *wide = Py_DecodeLocale(path.UTF8String, NULL);
      if (!wide) { PyConfig_Clear(&config); return NO; }
      status = PyWideStringList_Append(&config.module_search_paths, wide);
      PyMem_RawFree(wide);
    }
    if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) return NO;
    // Keep the interpreter alive; native modules may hold process-wide state.
    PyEval_SaveThread();
  }
  PyGILState_STATE gil = PyGILState_Ensure();
  PyObject *module = PyImport_ImportModule("lume_python");
  if (module) {
    self.runFunction = PyObject_GetAttrString(module, "run");
    Py_DECREF(module);
  }
  BOOL ready = self.runFunction && PyCallable_Check(self.runFunction);
  if (!ready) PyErr_Clear();
  PyGILState_Release(gil);
  return ready;
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  if (![call.method isEqualToString:@"execute"]) { result(FlutterMethodNotImplemented); return; }
  if (![call.arguments isKindOfClass:NSDictionary.class]) {
    result([FlutterError errorWithCode:@"arguments" message:@"Python 请求格式错误" details:nil]); return;
  }
  NSDictionary *request = call.arguments;
  if (![request[@"sourceId"] isKindOfClass:NSString.class] ||
      ![request[@"action"] isKindOfClass:NSString.class]) {
    result([FlutterError errorWithCode:@"arguments" message:@"Python 请求缺少来源标识" details:nil]); return;
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
  if (!data || data.length > 16 * 1024 * 1024) {
    result([FlutterError errorWithCode:@"arguments" message:@"Python 脚本或请求过大" details:nil]); return;
  }
  dispatch_async(self.worker, ^{
    @autoreleasepool {
      if (!self.runFunction && [request[@"action"] isEqual:@"dispose"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ result(@"{\"ok\":true,\"value\":null}"); });
        return;
      }
      if (![self prepareRuntime]) {
        dispatch_async(dispatch_get_main_queue(), ^{
          result([FlutterError errorWithCode:@"runtime" message:@"Python 运行环境初始化失败，请检查安装包资源" details:nil]);
        });
        return;
      }
      @synchronized(self) {
        if ([request[@"action"] isEqual:@"load"]) [self.loadedSources addObject:request[@"sourceId"]];
        if ([request[@"action"] isEqual:@"dispose"]) [self.loadedSources removeObject:request[@"sourceId"]];
      }
      PyGILState_STATE gil = PyGILState_Ensure();
      NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
      PyObject *argument = PyUnicode_FromString(json.UTF8String);
      PyObject *reply = argument ? PyObject_CallFunctionObjArgs(self.runFunction, argument, NULL) : NULL;
      NSString *text = nil;
      if (reply && PyUnicode_Check(reply)) {
        const char *utf8 = PyUnicode_AsUTF8(reply);
        if (utf8) text = [NSString stringWithUTF8String:utf8];
      }
      Py_XDECREF(reply);
      Py_XDECREF(argument);
      if (!text) PyErr_Clear();
      PyGILState_Release(gil);
      if ([request[@"action"] isEqual:@"load"]) {
        NSDictionary *replyData = text ? [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        if (![replyData isKindOfClass:NSDictionary.class] || ![replyData[@"ok"] boolValue]) {
          @synchronized(self) { [self.loadedSources removeObject:request[@"sourceId"]]; }
        }
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        if (text) result(text);
        else result([FlutterError errorWithCode:@"python" message:@"Python 源执行失败" details:nil]);
      });
    }
  });
}
@end
