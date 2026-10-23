#include "include/cef_app.h"
#include "include/wrapper/cef_library_loader.h"

#if defined(CEF_USE_SANDBOX)
#include "include/cef_sandbox_mac.h"
#endif

namespace {

class HelperApp : public CefApp {
 public:
  void OnBeforeCommandLineProcessing(
      const CefString& process_type,
      CefRefPtr<CefCommandLine> command_line) override {
    command_line->RemoveSwitch("remote-debugging-pipe");
  }

 private:
  IMPLEMENT_REFCOUNTING(HelperApp);
};

}

int main(int argc, char* argv[]) {
#if defined(CEF_USE_SANDBOX)
  CefScopedSandboxContext sandbox_context;
  if (!sandbox_context.Initialize(argc, argv)) {
    return 1;
  }
#endif

  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) {
    return 1;
  }

  CefMainArgs main_args(argc, argv);
  CefRefPtr<HelperApp> app(new HelperApp);
  return CefExecuteProcess(main_args, app, nullptr);
}
