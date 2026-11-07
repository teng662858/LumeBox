// Minimal simulator app: verifies the packaged interpreter and extension loader.
// No LumeBox IPA is built or uploaded by this check.
#import <UIKit/UIKit.h>
#include <Python.h>

static PyObject *NoNetwork(PyObject *self, PyObject *args) {
  PyErr_SetString(PyExc_RuntimeError, "Smoke test forbids network");
  return NULL;
}
static PyMethodDef Methods[] = {{"invoke", NoNetwork, METH_VARARGS, NULL}, {NULL, NULL, 0, NULL}};
static struct PyModuleDef Module = {PyModuleDef_HEAD_INIT, "_lume_host", NULL, -1, Methods};
static PyObject *InitHost(void) { return PyModule_Create(&Module); }

static void WriteStatus(NSString *phase, NSString *detail) {
  NSURL *directory = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
  [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
  NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"phase":phase, @"detail":detail ?: @""} options:0 error:nil];
  [data writeToURL:[directory URLByAppendingPathComponent:@"python-smoke-status.json"] options:NSDataWritingAtomic error:nil];
}

@interface SmokeDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation SmokeDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.window.rootViewController = [[UIViewController alloc] init];
  [self.window makeKeyAndVisible];
  WriteStatus(@"started", @"");
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSString *root = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"python"];
    NSString *standard = [root stringByAppendingPathComponent:@"lib/python3.13"];
    PyImport_AppendInittab("_lume_host", InitHost);
    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.write_bytecode = 0;
    config.install_signal_handlers = 0;
    config.module_search_paths_set = 1;
    PyStatus status = PyConfig_SetBytesString(&config, &config.home, root.UTF8String);
    for (NSString *path in @[standard, [standard stringByAppendingPathComponent:@"lib-dynload"], [root stringByAppendingPathComponent:@"packages"], root]) {
      wchar_t *wide = Py_DecodeLocale(path.UTF8String, NULL);
      status = PyWideStringList_Append(&config.module_search_paths, wide);
      PyMem_RawFree(wide);
      if (PyStatus_Exception(status)) break;
    }
    if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
      WriteStatus(@"failed", status.err_msg ? [NSString stringWithUTF8String:status.err_msg] : @"Python initialization failed");
      fprintf(stderr, "LUME_PYTHON_SMOKE_FAILED init\n"); exit(1);
    }
    const char *test =
      "import io, sys\n"
      "if sys.stdout is None: sys.stdout = io.StringIO()\n"
      "if sys.stderr is None: sys.stderr = io.StringIO()\n"
      "import json, ssl, ctypes, hashlib, lzma, bs4, requests, lume_python\n"
      "assert ssl.OPENSSL_VERSION and hashlib.sha256(b'smoke').hexdigest()\n"
      "assert lzma.decompress(lzma.compress(b'source-payload')) == b'source-payload'\n"
      "from cryptography.hazmat.primitives.ciphers.aead import AESGCM\n"
      "import cffi\n"
      "assert cffi.FFI().sizeof('int') == 4\n"
      "aes = AESGCM(bytes(16)); nonce = bytes(12)\n"
      "assert aes.encrypt(nonce, b'', None).hex() == '58e2fccefa7e3061367f1d57a4e7455a'\n"
      "script = '''from base.spider import Spider\n"
      "class Spider(Spider):\n"
      " def init(self, extend): pass\n"
      " def homeContent(self, filter): return {'class':[{'type_id':'1','type_name':'Movie'}]}\n"
      " def categoryContent(self, *args): return {'list':[]}\n"
      " def detailContent(self, ids): return {'list':[]}\n"
      " def playerContent(self, *args): return {}\n'''\n"
      "loaded = json.loads(lume_python.run(json.dumps({'sourceId':'smoke','action':'load','script':script})))\n"
      "assert loaded['ok'], loaded\n"
      "called = json.loads(lume_python.run(json.dumps({'sourceId':'smoke','action':'call','method':'categories'})))\n"
      "assert called['ok'] and called['value'][0]['title'] == 'Movie', called\n"
      "import unittest, test_python_sources\n"
      "suite = unittest.defaultTestLoader.loadTestsFromTestCase(test_python_sources.HostTests)\n"
      "smoke_output = io.StringIO()\n"
      "result = unittest.TextTestRunner(stream=smoke_output, verbosity=2).run(suite)\n"
      "assert result.wasSuccessful(), 'Embedded Spider compatibility tests failed\\n' + smoke_output.getvalue()\n";
    PyObject *mainModule = PyImport_AddModule("__main__");
    PyObject *globals = PyModule_GetDict(mainModule);
    PyObject *executed = PyRun_String(test, Py_file_input, globals, globals);
    int code = executed ? 0 : 1;
    if (!executed) {
      // Embedded iOS sys.stderr may not reach simctl's console. Preserve the
      // actual exception in the app's data container rather than hiding it.
      PyObject *type = NULL, *value = NULL, *trace = NULL;
      PyErr_Fetch(&type, &value, &trace);
      PyErr_NormalizeException(&type, &value, &trace);
      PyObject *traceback = PyImport_ImportModule("traceback");
      PyObject *lines = traceback ? PyObject_CallMethod(traceback, "format_exception", "OOO",
        type ?: Py_None, value ?: Py_None, trace ?: Py_None) : NULL;
      PyObject *separator = PyUnicode_FromString("");
      PyObject *description = lines ? PyUnicode_Join(separator, lines) : PyObject_Str(value ?: Py_None);
      const char *text = description ? PyUnicode_AsUTF8(description) : NULL;
      NSString *detail = text ? [NSString stringWithUTF8String:text] : @"Unable to format Python exception";
      WriteStatus(@"failed", detail);
      fprintf(stderr, "%s\n", detail.UTF8String);
      Py_XDECREF(description); Py_XDECREF(separator); Py_XDECREF(lines); Py_XDECREF(traceback);
      Py_XDECREF(type); Py_XDECREF(value); Py_XDECREF(trace);
    } else {
      Py_DECREF(executed);
      WriteStatus(@"passed", @"Interpreter, native extensions and Spider compatibility tests passed");
    }
    fprintf(stderr, code == 0 ? "LUME_PYTHON_SMOKE_OK\n" : "LUME_PYTHON_SMOKE_FAILED script\n");
    fflush(stderr);
    exit(code == 0 ? 0 : 1);
  });
  return YES;
}
@end

int main(int argc, char **argv) {
  @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(SmokeDelegate.class)); }
}
