#import "MBEngine.h"

#include <fcntl.h>
#include <unistd.h>
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstring>
#include <functional>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_cookie.h"
#include "include/cef_parser.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"
#include "include/cef_resource_handler.h"
#include "include/wrapper/cef_library_loader.h"

@interface MBPermissionPrompt : NSObject
- (instancetype)initWithMessage:(NSString*)message
                           done:(void (^)(BOOL allowed))done;
- (void)showForView:(NSView*)view;
- (void)answer:(BOOL)allowed;
@property(nonatomic, readonly) BOOL shown;
@property(nonatomic, readonly) BOOL answered;
@end

@interface MBWebView ()
- (void)engineAddPrompt:(MBPermissionPrompt*)prompt;
- (void)engineDidCreateBrowser:(CefRefPtr<CefBrowser>)browser;
- (void)engineWillCloseBrowser;
- (void)engineDidCloseBrowser;
- (void)engineSetMediaPlaying:(BOOL)playing;
- (void)engineSetThemeColor:(NSString*)color;
- (void)engineSetCapturing:(BOOL)capturing;
- (void)engineSetBlockedCount:(NSUInteger)count;
- (void)engineSetConsoleErrors:(NSUInteger)errors warnings:(NSUInteger)warnings;
- (void)engineDidFinishLoad:(int)status duration:(NSTimeInterval)duration;
- (void)engineDidStopPicking;
- (void)engineShowDevToolsAt:(CefPoint)at;
- (void)engineDevToolsOpened:(NSWindow*)window;
- (void)engineDevToolsClosed;
- (void)engineFrameAttached:(NSString*)frame session:(NSString*)session;
- (void)engineFrameDetached:(NSString*)session;
- (void)engineNetworkEvent:(NSString*)method params:(NSDictionary*)params;
- (void)engineDevToolsEvent:(NSString*)method params:(NSDictionary*)params;
- (void)engineDidPickNode:(int)backendNodeId;
- (void)engineInspectAt:(NSPoint)point;
@end

namespace {

CefScopedLibraryLoader* g_library_loader = nullptr;
std::map<std::string, CefRefPtr<CefRequestContext>> g_contexts;
NSMutableSet<MBWebView*>* g_views = nil;
std::vector<CefRefPtr<CefBrowser>> g_auxiliary;
int g_pipe_write = -1;
int g_pipe_read = -1;
bool g_extension_helper = false;
void (^g_pipe_handler)(NSString* message) = nil;
int g_browser_count = 0;
bool g_quitting = false;
bool g_strict_site_isolation = true;
std::string g_isolated_origins;
MBRequestFilter g_request_filter = nil;
MBPageScript g_page_script = nil;
MBEarlyScript g_early_script = nil;
MBPageReply g_page_reply = nil;
std::string g_form_script;
MBExtensionBridge g_extension_bridge = nil;
MBPageScript g_extension_script = nil;
const char kBridgeOrigin[] = "https://mbga-extension.invalid/";
bool g_reject_drops = false;

constexpr char kCosmeticPrefix[] = "__mbga_cosmetic:";
constexpr char kFormPrefix[] = "__mbga_form:";
constexpr char kFormTokenPlaceholder[] = "__MBGA_TOKEN__";

const char* RequestKind(cef_resource_type_t type) {
  switch (type) {
    case RT_MAIN_FRAME:
    case RT_NAVIGATION_PRELOAD_MAIN_FRAME: return nullptr;
    case RT_SUB_FRAME:
    case RT_NAVIGATION_PRELOAD_SUB_FRAME: return "subdocument";
    case RT_STYLESHEET: return "stylesheet";
    case RT_SCRIPT:
    case RT_WORKER:
    case RT_SHARED_WORKER:
    case RT_SERVICE_WORKER: return "script";
    case RT_IMAGE:
    case RT_FAVICON: return "image";
    case RT_FONT_RESOURCE: return "font";
    case RT_OBJECT:
    case RT_PLUGIN_RESOURCE: return "object";
    case RT_MEDIA: return "media";
    case RT_XHR: return "xmlhttprequest";
    case RT_PING: return "ping";
    case RT_CSP_REPORT: return "csp_report";
    default: return "other";
  }
}

constexpr char kMediaProbePrefix[] = "__mbga_media:";
constexpr char kThemePrefix[] = "__mbga_theme:";
constexpr char kThemeColorScript[] =
    "(function(){try{var c='';var ms=document.querySelectorAll("
    "'meta[name=\"theme-color\"]');for(var i=0;i<ms.length;i++){var m=ms[i];"
    "if(!m.media||matchMedia(m.media).matches){c=m.content;break;}}var v='';"
    "if(c){var x=document.createElement('canvas').getContext('2d');"
    "x.fillStyle='#010203';x.fillStyle=c;v=x.fillStyle;"
    "if(v==='#010203')v='';}console.debug('__mbga_theme:'+v);}catch(e){}})();";
constexpr char kMediaProbeScript[] =
    "(function(){try{var p=false;"
    "document.querySelectorAll('video,audio').forEach(function(m){"
    "if(!m.paused&&!m.muted&&m.volume>0&&m.readyState>2)p=true;});"
    "console.debug('__mbga_media:'+(p?1:0));}catch(e){}})();";

constexpr char kPauseMediaScript[] =
    "(function(){document.querySelectorAll('video,audio').forEach(function(m){"
    "if(!m.paused){m.dataset.mbgaPaused='1';m.pause();}});})();";
constexpr char kResumeMediaScript[] =
    "(function(){document.querySelectorAll('[data-mbga-paused]').forEach("
    "function(m){delete m.dataset.mbgaPaused;m.play();});})();";

enum MenuCommand {
  kOpenLinkInNewTab = MENU_ID_USER_FIRST,
  kCopyLink,
  kInspect,
  kFirstExtensionItem,
};

NSString* ToNS(const CefString& s) {
  return [NSString stringWithUTF8String:s.ToString().c_str()] ?: @"";
}

NSDictionary* MenuContext(CefRefPtr<CefContextMenuParams> params) {
  int flags = params->GetTypeFlags();
  NSMutableArray* contexts = [NSMutableArray arrayWithObject:@"all"];
  NSString* media = @"";
  switch (params->GetMediaType()) {
    case CM_MEDIATYPE_IMAGE: media = @"image"; break;
    case CM_MEDIATYPE_VIDEO: media = @"video"; break;
    case CM_MEDIATYPE_AUDIO: media = @"audio"; break;
    default: break;
  }
  if (flags & CM_TYPEFLAG_LINK) [contexts addObject:@"link"];
  if (flags & CM_TYPEFLAG_SELECTION) [contexts addObject:@"selection"];
  if (flags & CM_TYPEFLAG_EDITABLE) [contexts addObject:@"editable"];
  if (media.length) [contexts addObject:media];
  if (contexts.count == 1) [contexts addObject:@"page"];
  if ((flags & CM_TYPEFLAG_FRAME) &&
      params->GetFrameUrl() != params->GetPageUrl()) {
    [contexts addObject:@"frame"];
  }
  return @{
    @"contexts" : contexts,
    @"pageUrl" : ToNS(params->GetPageUrl()),
    @"frameUrl" : ToNS(params->GetFrameUrl()),
    @"linkUrl" : ToNS(params->GetLinkUrl()),
    @"srcUrl" : ToNS(params->GetSourceUrl()),
    @"mediaType" : media,
    @"selectionText" : ToNS(params->GetSelectionText()),
    @"editable" : @(params->IsEditable()),
  };
}

bool DebugEvents() {
  static const bool enabled = getenv("MBGA_DEBUG_EVENTS") != nullptr;
  return enabled;
}

void BrowserGone() {
  --g_browser_count;
  if (DebugEvents() && g_quitting) {
    NSLog(@"browser closed, %d left", g_browser_count);
  }
  if (g_browser_count == 0 && g_quitting) {
    CefQuitMessageLoop();
  }
}

class BridgeResourceHandler : public CefResourceHandler {
 public:
  BridgeResourceHandler(std::string profile_path,
                        std::string extension,
                        int browser_id)
      : profile_path_(std::move(profile_path)),
        extension_(std::move(extension)),
        browser_id_(browser_id) {}

  bool Open(CefRefPtr<CefRequest> request,
            bool& handle_request,
            CefRefPtr<CefCallback> callback) override {
    handle_request = false;
    std::string url = request->GetURL().ToString();
    NSString* path = @(url.substr(strlen(kBridgeOrigin)).c_str());
    std::string body;
    if (CefRefPtr<CefPostData> post = request->GetPostData()) {
      CefPostData::ElementVector elements;
      post->GetElements(elements);
      for (const auto& element : elements) {
        size_t size = element->GetBytesCount();
        std::string chunk(size, '\0');
        element->GetBytes(size, chunk.data());
        body += chunk;
      }
    }
    NSString* profile = @(profile_path_.c_str());
    NSString* extension = @(extension_.c_str());
    NSString* text = @(body.c_str()) ?: @"";
    int browser_id = browser_id_;
    CefRefPtr<BridgeResourceHandler> self(this);
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!g_extension_bridge) {
        self->data_ = "null";
        callback->Continue();
        return;
      }
      g_extension_bridge(profile, extension, browser_id, path, text,
                         ^(NSString* json) {
                           self->data_ = json.UTF8String ?: "null";
                           callback->Continue();
                         });
    });
    return true;
  }

  void GetResponseHeaders(CefRefPtr<CefResponse> response,
                          int64_t& response_length,
                          CefString& redirect_url) override {
    response->SetStatus(200);
    response->SetMimeType("application/json");
    response->SetHeaderByName("Access-Control-Allow-Origin", "*", true);
    response_length = static_cast<int64_t>(data_.size());
  }

  bool Read(void* data_out,
            int bytes_to_read,
            int& bytes_read,
            CefRefPtr<CefResourceReadCallback> callback) override {
    size_t left = data_.size() - offset_;
    bytes_read = static_cast<int>(std::min<size_t>(left, bytes_to_read));
    memcpy(data_out, data_.data() + offset_, bytes_read);
    offset_ += bytes_read;
    return bytes_read > 0;
  }

  void Cancel() override {}

 private:
  std::string profile_path_;
  std::string extension_;
  int browser_id_;
  std::string data_;
  size_t offset_ = 0;
  IMPLEMENT_REFCOUNTING(BridgeResourceHandler);
};

class BridgeRequestHandler : public CefResourceRequestHandler {
 public:
  BridgeRequestHandler(std::string profile_path, std::string extension)
      : profile_path_(std::move(profile_path)),
        extension_(std::move(extension)) {}

  CefRefPtr<CefResourceHandler> GetResourceHandler(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request) override {
    return new BridgeResourceHandler(profile_path_, extension_,
                                     browser ? browser->GetIdentifier() : 0);
  }

 private:
  std::string profile_path_;
  std::string extension_;
  IMPLEMENT_REFCOUNTING(BridgeRequestHandler);
};

CefRefPtr<CefResourceRequestHandler> BridgeHandlerFor(
    const std::string& profile_path,
    CefRefPtr<CefRequest> request,
    const CefString& initiator) {
  static const std::string kExtensionScheme = "chrome-extension://";
  std::string origin = initiator.ToString();
  if (origin.rfind(kExtensionScheme, 0) != 0 ||
      request->GetURL().ToString().rfind(kBridgeOrigin, 0) != 0) {
    return nullptr;
  }
  return new BridgeRequestHandler(profile_path,
                                  origin.substr(kExtensionScheme.size()));
}

class ContextHandler : public CefRequestContextHandler {
 public:
  explicit ContextHandler(std::string path) : path_(std::move(path)) {}

  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request,
      bool is_navigation,
      bool is_download,
      const CefString& request_initiator,
      bool& disable_default_handling) override {
    return BridgeHandlerFor(path_, request, request_initiator);
  }

 private:
  std::string path_;
  IMPLEMENT_REFCOUNTING(ContextHandler);
};

NSString* DocumentScriptFor(const std::string& url) {
  if (url.rfind("https://", 0) == 0 || url.rfind("http://", 0) == 0) {
    return g_page_script ? g_page_script(@(url.c_str())) : nil;
  }
  if (url.rfind("chrome-extension://", 0) == 0) {
    return g_extension_script ? g_extension_script(@(url.c_str())) : nil;
  }
  return nil;
}

CefRefPtr<CefRequestContext> ContextForPath(const std::string& path) {
  auto it = g_contexts.find(path);
  if (it != g_contexts.end()) {
    return it->second;
  }
  CefRequestContextSettings settings;
  CefString(&settings.cache_path) = path;
  settings.persist_session_cookies = true;
  CefRefPtr<CefRequestContext> context =
      CefRequestContext::CreateContext(settings, new ContextHandler(path));
  g_contexts[path] = context;
  return context;
}

NSString* UniqueDownloadPath(NSString* suggested) {
  NSString* dir = [NSSearchPathForDirectoriesInDomains(
                      NSDownloadsDirectory, NSUserDomainMask, YES) firstObject]
                      ?: NSTemporaryDirectory();
  NSString* name = suggested.length ? suggested.lastPathComponent : @"download";
  NSString* base = name.stringByDeletingPathExtension;
  NSString* ext = name.pathExtension;
  NSString* path = [dir stringByAppendingPathComponent:name];
  NSFileManager* fm = NSFileManager.defaultManager;
  for (int i = 1; [fm fileExistsAtPath:path]; i++) {
    NSString* candidate = [NSString stringWithFormat:@"%@ (%d)", base, i];
    if (ext.length) {
      candidate = [candidate stringByAppendingPathExtension:ext];
    }
    path = [dir stringByAppendingPathComponent:candidate];
  }
  return path;
}

void AskPermission(CefRefPtr<CefBrowser> browser,
                   const CefString& origin,
                   NSString* action,
                   void (^done)(BOOL allowed)) {
  NSString* host = [NSURL URLWithString:ToNS(origin)].host ?: ToNS(origin);
  MBPermissionPrompt* prompt = [[MBPermissionPrompt alloc]
      initWithMessage:[NSString
                          stringWithFormat:@"%@ wants to %@", host, action]
                 done:done];
  NSView* browser_view =
      (__bridge NSView*)browser->GetHost()->GetWindowHandle();
  if ([browser_view.superview isKindOfClass:[MBWebView class]]) {
    [(MBWebView*)browser_view.superview engineAddPrompt:prompt];
  } else {
    [prompt showForView:browser_view];
  }
}

NSString* DescribeMedia(uint32_t permissions) {
  NSMutableArray* parts = [NSMutableArray array];
  if (permissions & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) {
    [parts addObject:@"camera"];
  }
  if (permissions & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) {
    [parts addObject:@"microphone"];
  }
  if (permissions & (CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE |
                     CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE)) {
    [parts addObject:@"screen"];
  }
  return [NSString stringWithFormat:@"use your %@",
                                    [parts componentsJoinedByString:@" and "]];
}

std::vector<cef_content_setting_types_t> DeviceSettings(uint32_t permissions) {
  if (permissions & (CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE |
                     CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE)) {
    return {};
  }
  std::vector<cef_content_setting_types_t> settings;
  if (permissions & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE) {
    settings.push_back(CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC);
  }
  if (permissions & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) {
    settings.push_back(CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA);
  }
  return settings;
}

NSString* DescribePrompt(uint32_t permissions) {
  if (permissions & CEF_PERMISSION_TYPE_GEOLOCATION) {
    return @"know your location";
  }
  if (permissions & CEF_PERMISSION_TYPE_NOTIFICATIONS) {
    return @"show notifications";
  }
  if (permissions &
      (CEF_PERMISSION_TYPE_CAMERA_STREAM | CEF_PERMISSION_TYPE_MIC_STREAM)) {
    return @"use your camera or microphone";
  }
  if (permissions & CEF_PERMISSION_TYPE_CLIPBOARD) {
    return @"see text and images copied to the clipboard";
  }
  return @"use additional permissions";
}

bool IsExtensionsPage(const std::string& url) {
  for (const char* prefix :
       {"chrome://extensions", "https://chromewebstore.google.com/",
        "https://chrome.google.com/webstore"}) {
    if (url.rfind(prefix, 0) == 0) {
      return true;
    }
  }
  return false;
}

bool IsReservedShortcut(NSEvent* event) {
  NSEventModifierFlags flags =
      event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask &
      (NSEventModifierFlagCommand | NSEventModifierFlagControl |
       NSEventModifierFlagOption | NSEventModifierFlagShift);
  NSString* key = event.charactersIgnoringModifiers.lowercaseString;
  if (key.length != 1) {
    return false;
  }
  unichar c = [key characterAtIndex:0];
  if (c > 0x7F && c < 0xF700) {
    static const std::map<unsigned short, unichar> kAnsiKeys = {
        {17, 't'}, {13, 'w'}, {37, 'l'}, {12, 'q'}, {18, '1'},
        {19, '2'}, {20, '3'}, {21, '4'}, {23, '5'}, {22, '6'},
        {26, '7'}, {28, '8'}, {25, '9'}};
    auto it = kAnsiKeys.find(event.keyCode);
    if (it == kAnsiKeys.end()) {
      return false;
    }
    c = it->second;
  }
  if (flags == NSEventModifierFlagCommand) {
    return c == 't' || c == 'w' || c == 'l' || c == 'q' ||
           (c >= '1' && c <= '9');
  }
  if (flags == NSEventModifierFlagControl ||
      flags == (NSEventModifierFlagControl | NSEventModifierFlagShift)) {
    return c == '\t' || (c >= '1' && c <= '9');
  }
  if (flags == (NSEventModifierFlagCommand | NSEventModifierFlagOption)) {
    return c == NSUpArrowFunctionKey || c == NSDownArrowFunctionKey;
  }
  return false;
}

bool Omitted(const std::string& name) {
  static const std::set<std::string> omitted = [] {
    std::set<std::string> names;
    if (const char* env = getenv("MBGA_ENGINE_OMIT")) {
      for (NSString* token in [@(env) componentsSeparatedByString:@" "]) {
        if (token.length) {
          names.insert(token.UTF8String);
        }
      }
    }
    return names;
  }();
  return omitted.count(name) > 0;
}

void AppendToListSwitch(CefRefPtr<CefCommandLine> command_line,
                        const std::string& name,
                        const std::string& items) {
  std::string value = command_line->GetSwitchValue(name);
  for (NSString* item in [@(items.c_str()) componentsSeparatedByString:@","]) {
    NSString* feature = [item componentsSeparatedByString:@":"].firstObject;
    if (!Omitted(feature.UTF8String)) {
      value += (value.empty() ? "" : ",") + std::string(item.UTF8String);
    }
  }
  if (!value.empty()) {
    command_line->AppendSwitchWithValue(name, value);
  }
}

void AppendDefaultSwitch(CefRefPtr<CefCommandLine> command_line,
                         const std::string& name,
                         const std::string& value = "") {
  if (Omitted(name)) {
    return;
  }
  if (value.empty()) {
    command_line->AppendSwitch(name);
  } else {
    command_line->AppendSwitchWithValue(name, value);
  }
}

void AppendSwitchesFromEnvironment(CefRefPtr<CefCommandLine> command_line) {
  const char* env = getenv("MBGA_ENGINE_SWITCHES");
  if (!env) {
    return;
  }
  for (NSString* token in [@(env) componentsSeparatedByString:@" "]) {
    if (![token hasPrefix:@"--"]) {
      continue;
    }
    NSString* body = [token substringFromIndex:2];
    NSRange eq = [body rangeOfString:@"="];
    if (eq.location == NSNotFound) {
      command_line->AppendSwitch(body.UTF8String);
      continue;
    }
    std::string name = [body substringToIndex:eq.location].UTF8String;
    std::string value = [body substringFromIndex:eq.location + 1].UTF8String;
    if (name == "enable-features" || name == "disable-features" ||
        name == "load-extension") {
      AppendToListSwitch(command_line, name, value);
    } else if (name == "js-flags" && command_line->HasSwitch("js-flags")) {
      command_line->AppendSwitchWithValue(
          name, command_line->GetSwitchValue(name).ToString() + " " + value);
    } else {
      command_line->AppendSwitchWithValue(name, value);
    }
  }
}

class BrowserApp : public CefApp {
 public:
  void OnBeforeCommandLineProcessing(
      const CefString& process_type,
      CefRefPtr<CefCommandLine> command_line) override {
    if (!process_type.empty()) {
      return;
    }

    AppendDefaultSwitch(command_line, "process-per-site");
    if (!g_strict_site_isolation) {
      AppendToListSwitch(command_line, "disable-features", "SitePerProcess");
      AppendDefaultSwitch(command_line, "renderer-process-limit", "4");
      if (!g_isolated_origins.empty()) {
        AppendDefaultSwitch(command_line, "isolate-origins",
                            g_isolated_origins);
      }
    }

    AppendToListSwitch(command_line, "enable-features",
                       "MemoryPurgeInBackground:"
                       "memory_purge_background_min_delay/30s/"
                       "memory_purge_background_max_delay/60s");
    AppendToListSwitch(command_line, "enable-features", "MemoryPurgeOnFreeze");
    AppendToListSwitch(command_line, "disable-features",
                       "MemoryCacheStrongReference");
    AppendToListSwitch(command_line, "enable-features",
                       "ReclaimPrepaintTilesWhenIdle,ReclaimOldPrepaintTiles");
    AppendToListSwitch(command_line, "enable-features",
                       "NetworkServiceInProcess2");
    AppendDefaultSwitch(command_line, "disable-quic");
    AppendToListSwitch(command_line, "disable-features",
                       "SpareRendererForSitePerProcess,OptimizationHints,"
                       "AudioServiceOutOfProcess,Prerender2");
    AppendDefaultSwitch(command_line, "js-flags", "--optimize-for-size");

    if (g_pipe_write >= 0) {
      command_line->AppendSwitch("remote-debugging-pipe");
      AppendToListSwitch(command_line, "disable-features",
                         "DisableLoadExtensionCommandLineSwitch");
      if (g_extension_helper) {
        NSString* helper = [NSBundle.mainBundle.resourcePath
            stringByAppendingPathComponent:@"extension"];
        AppendToListSwitch(command_line, "load-extension", helper.UTF8String);
      }
    }
    AppendSwitchesFromEnvironment(command_line);

#if defined(MBGA_MOCK_KEYCHAIN)
    command_line->AppendSwitch("use-mock-keychain");
#endif
  }

 private:
  IMPLEMENT_REFCOUNTING(BrowserApp);
};

class BaseClient : public CefClient,
                   public CefDownloadHandler,
                   public CefPermissionHandler,
                   public CefKeyboardHandler {
 public:
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override {
    return this;
  }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }

  bool OnBeforeDownload(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefDownloadItem> download_item,
      const CefString& suggested_name,
      CefRefPtr<CefBeforeDownloadCallback> callback) override {
    callback->Continue(UniqueDownloadPath(ToNS(suggested_name)).UTF8String,
                       false);
    return true;
  }

  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefDownloadItem> download_item,
                         CefRefPtr<CefDownloadItemCallback> callback) override {
    if (download_item->IsComplete()) {
      [NSDistributedNotificationCenter.defaultCenter
          postNotificationName:@"com.apple.DownloadFileFinished"
                        object:ToNS(download_item->GetFullPath())];
    }
  }

  bool OnRequestMediaAccessPermission(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      const CefString& requesting_origin,
      uint32_t requested_permissions,
      CefRefPtr<CefMediaAccessCallback> callback) override {
    CefRefPtr<CefRequestContext> context =
        browser->GetHost()->GetRequestContext();
    std::string origin = requesting_origin;
    std::string top = browser->GetMainFrame()->GetURL();
    std::vector<cef_content_setting_types_t> settings =
        DeviceSettings(requested_permissions);
    if (!settings.empty()) {
      bool all_allowed = true;
      for (cef_content_setting_types_t setting : settings) {
        cef_content_setting_values_t value =
            context->GetContentSetting(origin, top, setting);
        if (value == CEF_CONTENT_SETTING_VALUE_BLOCK) {
          callback->Continue(CEF_MEDIA_PERMISSION_NONE);
          return true;
        }
        all_allowed &= value == CEF_CONTENT_SETTING_VALUE_ALLOW;
      }
      if (all_allowed) {
        callback->Continue(requested_permissions);
        return true;
      }
    }
    AskPermission(browser, requesting_origin,
                  DescribeMedia(requested_permissions), ^(BOOL allowed) {
                    if (allowed) {
                      for (cef_content_setting_types_t setting : settings) {
                        context->SetContentSetting(
                            origin, top, setting,
                            CEF_CONTENT_SETTING_VALUE_ALLOW);
                      }
                    }
                    callback->Continue(allowed ? requested_permissions
                                               : CEF_MEDIA_PERMISSION_NONE);
                  });
    return true;
  }

  bool OnShowPermissionPrompt(
      CefRefPtr<CefBrowser> browser,
      uint64_t prompt_id,
      const CefString& requesting_origin,
      uint32_t requested_permissions,
      CefRefPtr<CefPermissionPromptCallback> callback) override {
    AskPermission(browser, requesting_origin,
                  DescribePrompt(requested_permissions), ^(BOOL allowed) {
                    callback->Continue(allowed ? CEF_PERMISSION_RESULT_ACCEPT
                                               : CEF_PERMISSION_RESULT_DENY);
                  });
    return true;
  }

  bool OnPreKeyEvent(CefRefPtr<CefBrowser> browser,
                     const CefKeyEvent& event,
                     CefEventHandle os_event,
                     bool* is_keyboard_shortcut) override {
    if (event.type != KEYEVENT_RAWKEYDOWN || !os_event) {
      return false;
    }
    NSEvent* ns_event = (__bridge NSEvent*)os_event;
    if (ns_event.type != NSEventTypeKeyDown) {
      return false;
    }
    return IsReservedShortcut(ns_event) &&
           [NSApp.mainMenu performKeyEquivalent:ns_event];
  }
};

class AuxiliaryClient : public BaseClient, public CefLifeSpanHandler {
 public:
  static CefRefPtr<AuxiliaryClient> Get() {
    static CefRefPtr<AuxiliaryClient> instance(new AuxiliaryClient);
    return instance;
  }

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }

  bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     int popup_id,
                     const CefString& target_url,
                     const CefString& target_frame_name,
                     WindowOpenDisposition target_disposition,
                     bool user_gesture,
                     const CefPopupFeatures& popupFeatures,
                     CefWindowInfo& windowInfo,
                     CefRefPtr<CefClient>& client,
                     CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>& extra_info,
                     bool* no_javascript_access) override {
    windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    return false;
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    g_browser_count++;
    g_auxiliary.push_back(browser);
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    std::erase_if(g_auxiliary, [&](const CefRefPtr<CefBrowser>& b) {
      return b->IsSame(browser);
    });
    BrowserGone();
  }

 private:
  IMPLEMENT_REFCOUNTING(AuxiliaryClient);
};

class ExtensionsClient : public BaseClient, public CefLifeSpanHandler {
 public:
  static CefRefPtr<ExtensionsClient> Get() {
    static CefRefPtr<ExtensionsClient> instance(new ExtensionsClient);
    return instance;
  }

  static void Show(const std::string& path, const std::string& url) {
    for (const CefRefPtr<CefBrowser>& browser : g_auxiliary) {
      if (Path(browser) != path ||
          browser->GetHost()->GetRuntimeStyle() != CEF_RUNTIME_STYLE_CHROME) {
        continue;
      }
      if (!url.empty()) {
        browser->GetMainFrame()->LoadURL(url);
      }
      NSView* view = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
      [view.window makeKeyAndOrderFront:nil];
      return;
    }
    CefWindowInfo info;
    info.runtime_style = CEF_RUNTIME_STYLE_CHROME;
    CefBrowserSettings settings;
    CefBrowserHost::CreateBrowser(info, Get(),
                                  url.empty() ? "chrome://extensions/" : url,
                                  settings, nullptr, ContextForPath(path));
  }

  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override {
    return nullptr;
  }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    g_browser_count++;
    g_auxiliary.push_back(browser);
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    std::erase_if(g_auxiliary, [&](const CefRefPtr<CefBrowser>& b) {
      return b->IsSame(browser);
    });
    BrowserGone();
  }

 private:
  static std::string Path(CefRefPtr<CefBrowser> browser) {
    return browser->GetHost()->GetRequestContext()->GetCachePath().ToString();
  }

  IMPLEMENT_REFCOUNTING(ExtensionsClient);
};

double Number(CefRefPtr<CefValue> value) {
  if (!value) {
    return 0;
  }
  return value->GetType() == VTYPE_INT ? value->GetInt() : value->GetDouble();
}

void ShowDevTools(CefRefPtr<CefBrowser> browser, const CefPoint& at) {
  CefWindowInfo info;
  info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings settings;
  browser->GetHost()->ShowDevTools(info, AuxiliaryClient::Get(), settings, at);
}

class DevToolsClient : public BaseClient, public CefLifeSpanHandler {
 public:
  explicit DevToolsClient(MBWebView* view) : view_(view) {}

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    g_browser_count++;
    g_auxiliary.push_back(browser);
    ReportWindow(browser, 40);
  }

  void ReportWindow(CefRefPtr<CefBrowser> browser, int tries) {
    CefRefPtr<DevToolsClient> client(this);
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_MSEC),
        dispatch_get_main_queue(), ^{
          NSView* content =
              (__bridge NSView*)browser->GetHost()->GetWindowHandle();
          if (DebugEvents()) {
            NSLog(@"devtools window: view=%@ window=%@", content,
                  content.window);
          }
          if (content.window) {
            [client->view_ engineDevToolsOpened:content.window];
          } else if (tries > 0) {
            client->ReportWindow(browser, tries - 1);
          }
        });
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    std::erase_if(g_auxiliary, [&](const CefRefPtr<CefBrowser>& b) {
      return b->IsSame(browser);
    });
    [view_ engineDevToolsClosed];
    BrowserGone();
  }

 private:
  __weak MBWebView* view_;
  IMPLEMENT_REFCOUNTING(DevToolsClient);
};

class FaviconCallback : public CefDownloadImageCallback {
 public:
  FaviconCallback(MBWebView* view,
                  CefRefPtr<CefBrowser> browser,
                  std::vector<CefString> urls)
      : view_(view), browser_(browser), urls_(std::move(urls)) {}

  static void Start(MBWebView* view,
                    CefRefPtr<CefBrowser> browser,
                    const std::vector<CefString>& icon_urls) {
    std::vector<CefString> urls(icon_urls);
    std::stable_partition(urls.begin(), urls.end(), [](const CefString& url) {
      return url.ToString().find(".svg") == std::string::npos;
    });
    std::reverse(urls.begin(), urls.end());
    CefRefPtr<FaviconCallback>(new FaviconCallback(view, browser, urls))
        ->Next();
  }

  void OnDownloadImageFinished(const CefString& image_url,
                               int http_status_code,
                               CefRefPtr<CefImage> image) override {
    MBWebView* view = view_;
    if (!view || view.closing) {
      return;
    }
    int width = 0;
    int height = 0;
    CefRefPtr<CefBinaryValue> png =
        image && !image->IsEmpty() ? image->GetAsPNG(2.0f, true, width, height)
                                   : nullptr;
    if (!png || png->GetSize() == 0) {
      Next();
      return;
    }
    NSMutableData* data = [NSMutableData dataWithLength:png->GetSize()];
    png->GetData(data.mutableBytes, data.length, 0);
    [view.delegate webView:view didReceiveFavicon:data];
  }

 private:
  void Next() {
    if (urls_.empty()) {
      return;
    }
    CefString url = urls_.back();
    urls_.pop_back();
    browser_->GetHost()->DownloadImage(url, true, 32, false, this);
  }

  __weak MBWebView* view_;
  CefRefPtr<CefBrowser> browser_;
  std::vector<CefString> urls_;
  IMPLEMENT_REFCOUNTING(FaviconCallback);
};

class WebClient : public BaseClient,
                  public CefLifeSpanHandler,
                  public CefDisplayHandler,
                  public CefLoadHandler,
                  public CefRequestHandler,
                  public CefResourceRequestHandler,
                  public CefContextMenuHandler,
                  public CefDragHandler,
                  public CefDevToolsMessageObserver {
 public:
  using RawReply = std::function<void(bool, const std::string&)>;

  explicit WebClient(MBWebView* view)
      : view_(view), created_(CFAbsoluteTimeGetCurrent()) {}

  void DeferFirstLoad(const std::string& url) { deferred_url_ = url; }
  void CancelDeferredLoad() { deferred_url_.clear(); }

  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override {
    return this;
  }
  CefRefPtr<CefDragHandler> GetDragHandler() override { return this; }

  bool OnDragEnter(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefDragData> dragData,
                   DragOperationsMask mask) override {
    return g_reject_drops;
  }

  bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     int popup_id,
                     const CefString& target_url,
                     const CefString& target_frame_name,
                     WindowOpenDisposition target_disposition,
                     bool user_gesture,
                     const CefPopupFeatures& popupFeatures,
                     CefWindowInfo& windowInfo,
                     CefRefPtr<CefClient>& client,
                     CefBrowserSettings& settings,
                     CefRefPtr<CefDictionaryValue>& extra_info,
                     bool* no_javascript_access) override {
    switch (target_disposition) {
      case CEF_WOD_NEW_FOREGROUND_TAB:
      case CEF_WOD_NEW_BACKGROUND_TAB:
      case CEF_WOD_NEW_WINDOW:
      case CEF_WOD_SINGLETON_TAB: {
        MBWebView* view = view_;
        [view.delegate webView:view
            requestsNewTabWithURL:ToNS(target_url)
                       foreground:target_disposition !=
                                  CEF_WOD_NEW_BACKGROUND_TAB];
        return true;
      }
      default:
        windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
        client = AuxiliaryClient::Get();
        return false;
    }
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    devtools_ = browser->GetHost()->AddDevToolsMessageObserver(this);
    if (g_page_script || g_extension_script) {
      browser->GetHost()->ExecuteDevToolsMethod(0, "Page.enable", nullptr);
    }
    [view_ engineDidCreateBrowser:browser];
    if (deferred_url_.empty()) {
      return;
    }
    if (!PrepareNewDocument(browser, deferred_url_)) {
      LoadDeferred(browser);
      return;
    }
    CefRefPtr<WebClient> client(this);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
                     client->LoadDeferred(browser);
                   });
  }

  void LoadDeferred(CefRefPtr<CefBrowser> browser) {
    if (deferred_url_.empty()) {
      return;
    }
    prepared_url_ = deferred_url_;
    deferred_url_.clear();
    if (prepared_url_.rfind("chrome-extension://", 0) == 0) {
      browser->GetMainFrame()->LoadURL(prepared_url_);
      return;
    }
    NSData* json =
        [NSJSONSerialization dataWithJSONObject:@[ @(prepared_url_.c_str()) ]
                                        options:0
                                          error:nil];
    NSString* array = [[NSString alloc] initWithData:json
                                            encoding:NSUTF8StringEncoding];
    NSString* script =
        [NSString stringWithFormat:@"location.replace(%@[0])", array];
    browser->GetMainFrame()->ExecuteJavaScript(script.UTF8String, "", 0);
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    [view_ engineWillCloseBrowser];
    return true;
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    [view_ engineDidCloseBrowser];
    BrowserGone();
  }

  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString& url) override {
    if (frame->IsMain() && deferred_url_.empty()) {
      MBWebView* view = view_;
      [view.delegate webView:view didChangeURL:ToNS(url)];
    }
  }

  void OnTitleChange(CefRefPtr<CefBrowser> browser,
                     const CefString& title) override {
    if (!deferred_url_.empty()) {
      return;
    }
    MBWebView* view = view_;
    [view.delegate webView:view didChangeTitle:ToNS(title)];
  }

  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser,
                          const std::vector<CefString>& icon_urls) override {
    std::vector<std::string> urls;
    for (const auto& url : icon_urls) {
      urls.push_back(url.ToString());
    }
    if (urls == favicon_urls_) {
      return;
    }
    favicon_urls_ = urls;
    FaviconCallback::Start(view_, browser, icon_urls);
  }

  void OnFullscreenModeChange(CefRefPtr<CefBrowser> browser,
                              bool fullscreen) override {
    MBWebView* view = view_;
    [view.delegate webView:view didChangeFullscreen:fullscreen];
  }

  bool OnConsoleMessage(CefRefPtr<CefBrowser> browser,
                        cef_log_severity_t level,
                        const CefString& message,
                        const CefString& source,
                        int line) override {
    std::string text = message.ToString();
    if (text.rfind(kCosmeticPrefix, 0) == 0) {
      CefRefPtr<CefFrame> main = browser->GetMainFrame();
      NSString* reply =
          g_page_reply ? g_page_reply(ToNS(main->GetURL()),
                                      @(text.c_str() + strlen(kCosmeticPrefix)))
                       : nil;
      if (reply.length > 0) {
        main->ExecuteJavaScript(reply.UTF8String, "", 0);
      }
      return true;
    }
    if (text.rfind(kThemePrefix, 0) == 0) {
      [view_ engineSetThemeColor:@(text.c_str() + strlen(kThemePrefix))];
      return true;
    }
    if (text.rfind(kFormPrefix, 0) == 0) {
      std::string signed_prefix = kFormPrefix + form_token_ + ":";
      if (!form_token_.empty() && text.rfind(signed_prefix, 0) == 0) {
        MBWebView* view = view_;
        [view.delegate webView:view
            didReceiveFormMessage:@(text.c_str() + signed_prefix.size())
                              url:ToNS(browser->GetMainFrame()->GetURL())];
      }
      return true;
    }
    if (text.rfind(kMediaProbePrefix, 0) != 0) {
      CountConsoleMessage(level);
      NSInteger severity = level >= LOGSEVERITY_ERROR     ? 3
                           : level == LOGSEVERITY_WARNING ? 2
                           : level == LOGSEVERITY_INFO    ? 1
                                                          : 0;
      MBWebView* view = view_;
      [view.delegate webView:view
          didLogConsoleMessage:@(text.c_str())
                         level:severity
                        source:ToNS(source)
                          line:line];
      return false;
    }
    [view_ engineSetMediaPlaying:text.back() == '1'];
    return true;
  }

  void CountConsoleMessage(cef_log_severity_t level) {
    if (level == LOGSEVERITY_ERROR || level == LOGSEVERITY_FATAL) {
      console_errors_++;
    } else if (level == LOGSEVERITY_WARNING) {
      console_warnings_++;
    } else {
      return;
    }
    ReportConsole();
  }

  void ReportConsole() {
    if (console_report_pending_) {
      return;
    }
    console_report_pending_ = true;
    CefRefPtr<WebClient> client(this);
    dispatch_async(dispatch_get_main_queue(), ^{
      client->console_report_pending_ = false;
      [client->view_ engineSetConsoleErrors:client->console_errors_
                                   warnings:client->console_warnings_];
    });
  }

  void OnMediaAccessChange(CefRefPtr<CefBrowser> browser,
                           bool has_video_access,
                           bool has_audio_access) override {
    [view_ engineSetCapturing:has_video_access || has_audio_access];
  }

  void OnLoadStart(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   TransitionType transition_type) override {
    if (!frame->IsMain()) {
      return;
    }
    blocked_ = 0;
    [view_ engineSetBlockedCount:0];
    console_errors_ = 0;
    console_warnings_ = 0;
    ReportConsole();
    std::string url = frame->GetURL().ToString();
    if (DebugEvents()) {
      NSLog(@"load start %s after %.0f ms", url.c_str(),
            (CFAbsoluteTimeGetCurrent() - created_) * 1000);
    }
    NSString* script = DocumentScriptFor(url);
    if (script.length > 0) {
      frame->ExecuteJavaScript(script.UTF8String, "", 0);
    }
    bool web = url.rfind("https://", 0) == 0 || url.rfind("http://", 0) == 0;
    form_token_.clear();
    if (web && !g_form_script.empty()) {
      form_token_ = NSUUID.UUID.UUIDString.UTF8String;
      std::string form = g_form_script;
      for (size_t at = form.find(kFormTokenPlaceholder);
           at != std::string::npos; at = form.find(kFormTokenPlaceholder, at)) {
        form.replace(at, strlen(kFormTokenPlaceholder), form_token_);
      }
      frame->ExecuteJavaScript(form, "", 0);
    }
  }

  void OnLoadEnd(CefRefPtr<CefBrowser> browser,
                 CefRefPtr<CefFrame> frame,
                 int httpStatusCode) override {
    if (frame->IsMain()) {
      frame->ExecuteJavaScript(kThemeColorScript, "", 0);
      [view_
          engineDidFinishLoad:load_error_ != 0 ? load_error_ : httpStatusCode
                     duration:CFAbsoluteTimeGetCurrent() - navigation_started_];
      if (DebugEvents()) {
        NSLog(@"load end %s (%d) after %.0f ms",
              frame->GetURL().ToString().c_str(), httpStatusCode,
              (CFAbsoluteTimeGetCurrent() - created_) * 1000);
      }
    }
  }

  void OnLoadError(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   ErrorCode errorCode,
                   const CefString& errorText,
                   const CefString& failedUrl) override {
    if (frame->IsMain() && errorCode != ERR_ABORTED) {
      load_error_ = errorCode;
      [view_
          engineDidFinishLoad:errorCode
                     duration:CFAbsoluteTimeGetCurrent() - navigation_started_];
    }
  }

  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                            bool isLoading,
                            bool canGoBack,
                            bool canGoForward) override {
    MBWebView* view = view_;
    [view.delegate webView:view
          didChangeLoading:isLoading
                 canGoBack:canGoBack
              canGoForward:canGoForward];
  }

  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request,
                      bool user_gesture,
                      bool is_redirect) override {
    if (OpenExternally(browser, request->GetURL())) {
      return true;
    }
    if (frame->IsMain() && IsExtensionsPage(request->GetURL().ToString())) {
      static CFAbsoluteTime last_shown = 0;
      CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
      std::string current = frame->GetURL().ToString();
      bool fresh_tab = current.empty() || current == "about:blank";
      if ((user_gesture || is_redirect || fresh_tab) && now - last_shown > 2) {
        last_shown = now;
        MBWebView* view = view_;
        NSString* url = ToNS(request->GetURL());
        NSString* page = ToNS(frame->GetURL());
        dispatch_async(dispatch_get_main_queue(), ^{
          [view.delegate webView:view opensExtensionsPage:url fromPage:page];
        });
      }
      return true;
    }
    if (frame->IsMain()) {
      navigation_started_ = CFAbsoluteTimeGetCurrent();
      load_error_ = 0;
      std::string url = request->GetURL().ToString();
      if (url == prepared_url_) {
        prepared_url_.clear();
      } else if (deferred_url_.empty()) {
        PrepareNewDocument(browser, url);
      }
    }
    return false;
  }

  bool OpenExternally(CefRefPtr<CefBrowser> browser, const CefString& url) {
    NSURL* target = [NSURL URLWithString:ToNS(url)];
    NSString* scheme = target.scheme.lowercaseString;
    static NSSet<NSString*>* web = [NSSet setWithArray:@[
      @"http", @"https", @"file", @"about", @"data", @"blob", @"javascript",
      @"filesystem", @"ws", @"wss", @"chrome", @"chrome-extension", @"devtools",
      @"view-source"
    ]];
    if (!scheme || [web containsObject:scheme]) {
      return false;
    }
    NSURL* app =
        [NSWorkspace.sharedWorkspace URLForApplicationToOpenURL:target];
    if (!app) {
      return false;
    }
    NSString* name = [NSFileManager.defaultManager displayNameAtPath:app.path]
                         .stringByDeletingPathExtension;
    AskPermission(browser, browser->GetMainFrame()->GetURL(),
                  [NSString stringWithFormat:@"open %@", name],
                  ^(BOOL allowed) {
                    if (allowed) {
                      [NSWorkspace.sharedWorkspace openURL:target];
                    }
                  });
    return true;
  }

  bool PrepareNewDocument(CefRefPtr<CefBrowser> browser, const CefString& url) {
    CefURLParts parts;
    if (!CefParseURL(url, parts)) {
      return false;
    }
    std::string scheme = CefString(&parts.scheme).ToString();
    if (scheme != "http" && scheme != "https" && scheme != "chrome-extension") {
      return false;
    }
    CefRefPtr<CefBrowserHost> host = browser->GetHost();
    RemoveDocumentScript(host, document_script_);
    document_script_.clear();
    if (pending_add_ != 0) {
      stale_adds_.insert(pending_add_);
      pending_add_ = 0;
    }
    NSString* script = DocumentScriptFor(url.ToString());
    if (script.length == 0) {
      return false;
    }
    NSData* host_json = [NSJSONSerialization
        dataWithJSONObject:@[ ToNS(CefString(&parts.host)) ]
                   options:0
                     error:nil];
    NSString* host_array = [[NSString alloc] initWithData:host_json
                                                 encoding:NSUTF8StringEncoding];
    NSString* guarded =
        [NSString stringWithFormat:
                      @"if(window===window.top&&location.hostname===%@[0]){%@}",
                      host_array, script];
    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetString("source", guarded.UTF8String);
    pending_add_ = host->ExecuteDevToolsMethod(
        0, "Page.addScriptToEvaluateOnNewDocument", params);
    if (DebugEvents()) {
      NSLog(@"page script for %s registered as message %d (%lu bytes)",
            url.ToString().c_str(), pending_add_, (unsigned long)script.length);
    }
    return pending_add_ != 0;
  }

  void RemoveDocumentScript(CefRefPtr<CefBrowserHost> host,
                            const std::string& identifier) {
    if (identifier.empty()) {
      return;
    }
    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetString("identifier", identifier);
    host->ExecuteDevToolsMethod(0, "Page.removeScriptToEvaluateOnNewDocument",
                                params);
  }

  void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser,
                              int message_id,
                              bool success,
                              const void* result,
                              size_t result_size) override {
    auto raw = raw_replies_.find(message_id);
    if (raw != raw_replies_.end()) {
      RawReply done = std::move(raw->second);
      raw_replies_.erase(raw);
      done(success, std::string(static_cast<const char*>(result), result_size));
      return;
    }
    auto reply = replies_.find(message_id);
    if (reply != replies_.end()) {
      Reply done = std::move(reply->second);
      replies_.erase(reply);
      CefRefPtr<CefValue> value =
          success ? CefParseJSON(result, result_size, JSON_PARSER_RFC)
                  : nullptr;
      done(value && value->GetType() == VTYPE_DICTIONARY
               ? value->GetDictionary()
               : nullptr);
      return;
    }
    bool stale = stale_adds_.erase(message_id) > 0;
    if (DebugEvents()) {
      NSLog(@"devtools result %d success=%d: %.*s", message_id, success,
            (int)result_size, (const char*)result);
    }
    if (!stale && message_id == pending_add_ && !success) {
      pending_add_ = 0;
      LoadDeferred(browser);
      return;
    }
    if (!success || (!stale && message_id != pending_add_)) {
      return;
    }
    CefRefPtr<CefValue> value =
        CefParseJSON(result, result_size, JSON_PARSER_RFC);
    std::string identifier =
        value && value->GetType() == VTYPE_DICTIONARY
            ? value->GetDictionary()->GetString("identifier").ToString()
            : "";
    if (stale) {
      RemoveDocumentScript(browser->GetHost(), identifier);
    } else {
      pending_add_ = 0;
      document_script_ = identifier;
      LoadDeferred(browser);
    }
  }

  bool OnDevToolsMessage(CefRefPtr<CefBrowser> browser,
                         const void* message,
                         size_t message_size) override {
    if (session_replies_.empty() && !following_frames_) {
      return false;
    }
    NSData* data = [NSData dataWithBytesNoCopy:const_cast<void*>(message)
                                        length:message_size
                                  freeWhenDone:NO];
    NSDictionary* object = [NSJSONSerialization JSONObjectWithData:data
                                                           options:0
                                                             error:nil];
    if (![object isKindOfClass:NSDictionary.class]) {
      return false;
    }
    if (NSNumber* number = object[@"id"]) {
      auto reply = session_replies_.find(number.intValue);
      if (reply == session_replies_.end()) {
        return false;
      }
      RawReply done = std::move(reply->second);
      session_replies_.erase(reply);
      id payload = object[@"error"] ?: object[@"result"] ?: @{};
      NSData* json = [NSJSONSerialization dataWithJSONObject:payload
                                                     options:0
                                                       error:nil];
      done(object[@"error"] == nil,
           std::string(static_cast<const char*>(json.bytes), json.length));
      return true;
    }
    NSString* session = object[@"sessionId"];
    NSString* method = object[@"method"];
    if (session && method) {
      HandleEvent(browser, method, object[@"params"]);
      return true;
    }
    return false;
  }

  void HandleEvent(CefRefPtr<CefBrowser> browser,
                   NSString* method,
                   NSDictionary* params) {
    if (![params isKindOfClass:NSDictionary.class]) {
      return;
    }
    if ([method isEqualToString:@"Target.attachedToTarget"]) {
      NSDictionary* info = params[@"targetInfo"];
      NSString* session = params[@"sessionId"];
      if (![info[@"type"] isEqualToString:@"iframe"] || !session) {
        return;
      }
      [view_ engineFrameAttached:info[@"targetId"] session:session];
      CallInSession(browser, "Target.setAutoAttach",
                    "{\"autoAttach\":true,\"waitForDebuggerOnStart\":false,"
                    "\"flatten\":true}",
                    session.UTF8String, [](bool, const std::string&) {});
      if ([params[@"waitingForDebugger"] boolValue]) {
        CallInSession(browser, "Runtime.runIfWaitingForDebugger", "",
                      session.UTF8String, [](bool, const std::string&) {});
      }
    } else if ([method isEqualToString:@"Target.detachedFromTarget"]) {
      if (NSString* session = params[@"sessionId"]) {
        [view_ engineFrameDetached:session];
      }
    } else if (recording_network_ && [method hasPrefix:@"Network."]) {
      [view_ engineNetworkEvent:method params:params];
    }
  }

  void FollowFrames(CefRefPtr<CefBrowser> browser) {
    if (following_frames_) {
      return;
    }
    following_frames_ = true;
    CallRaw(browser, "Target.setAutoAttach",
            "{\"autoAttach\":true,\"waitForDebuggerOnStart\":false,\"flatten\":"
            "true}",
            [](bool, const std::string&) {});
  }

  void CallInSession(CefRefPtr<CefBrowser> browser,
                     const std::string& method,
                     const std::string& params,
                     const std::string& session,
                     RawReply done) {
    int message_id = next_session_message_++;
    NSMutableDictionary* message = [@{
      @"id" : @(message_id),
      @"method" : @(method.c_str()),
      @"sessionId" : @(session.c_str())
    } mutableCopy];
    if (!params.empty()) {
      NSData* data = [NSData dataWithBytes:params.data() length:params.size()];
      id object = [NSJSONSerialization JSONObjectWithData:data
                                                  options:0
                                                    error:nil];
      if (![object isKindOfClass:NSDictionary.class]) {
        done(false, "{\"message\":\"params must be a JSON object\"}");
        return;
      }
      message[@"params"] = object;
    }
    NSData* json = [NSJSONSerialization dataWithJSONObject:message
                                                   options:0
                                                     error:nil];
    session_replies_[message_id] = std::move(done);
    if (!browser->GetHost()->SendDevToolsMessage(json.bytes, json.length)) {
      RawReply failed = std::move(session_replies_[message_id]);
      session_replies_.erase(message_id);
      failed(false, "{\"message\":\"the command could not be sent\"}");
    }
  }

  void SetRecordingNetwork(bool recording) { recording_network_ = recording; }
  void SetForwardingEvents(bool forwarding) { forwarding_ = forwarding; }
  void SetPicksForInspector(bool picks) { inspector_picks_ = picks; }

  void OnDevToolsEvent(CefRefPtr<CefBrowser> browser,
                       const CefString& method,
                       const void* params,
                       size_t params_size) override {
    std::string name = method.ToString();
    if (forwarding_) {
      NSData* data = [NSData dataWithBytesNoCopy:const_cast<void*>(params)
                                          length:params_size
                                    freeWhenDone:NO];
      id object = [NSJSONSerialization JSONObjectWithData:data
                                                  options:0
                                                    error:nil];
      [view_
          engineDevToolsEvent:@(name.c_str())
                       params:[object isKindOfClass:NSDictionary.class] ? object
                                                                        : @{}];
    }
    if (name.rfind("Target.", 0) == 0 ||
        (recording_network_ && name.rfind("Network.", 0) == 0)) {
      NSData* data = [NSData dataWithBytesNoCopy:const_cast<void*>(params)
                                          length:params_size
                                    freeWhenDone:NO];
      HandleEvent(browser, @(name.c_str()),
                  [NSJSONSerialization JSONObjectWithData:data
                                                  options:0
                                                    error:nil]);
      return;
    }
    if (name == "Overlay.inspectNodeRequested" && picking_) {
      CefRefPtr<CefValue> value =
          CefParseJSON(params, params_size, JSON_PARSER_RFC);
      if (!value || value->GetType() != VTYPE_DICTIONARY) {
        return;
      }
      CefRefPtr<CefDictionaryValue> args = CefDictionaryValue::Create();
      args->SetInt(
          "backendNodeId",
          int(Number(value->GetDictionary()->GetValue("backendNodeId"))));
      SetPicking(browser, false);
      if (inspector_picks_) {
        [view_ engineDidPickNode:args->GetInt("backendNodeId")];
        return;
      }
      __weak MBWebView* weak_view = view_;
      Call(browser, "DOM.getBoxModel", args,
           [browser, weak_view](CefRefPtr<CefDictionaryValue> result) {
             CefPoint at;
             CefRefPtr<CefListValue> quad =
                 result && result->GetDictionary("model")
                     ? result->GetDictionary("model")->GetList("border")
                     : nullptr;
             if (quad && quad->GetSize() == 8) {
               double zoom = pow(1.2, browser->GetHost()->GetZoomLevel());
               auto corner = [&](size_t i) {
                 return Number(quad->GetValue(i));
               };
               at = CefPoint(int((corner(0) + corner(4)) / 2 * zoom),
                             int((corner(1) + corner(5)) / 2 * zoom));
             }
             [weak_view engineShowDevToolsAt:at];
           });
    } else if (name == "Overlay.inspectModeCanceled" && picking_) {
      SetPicking(browser, false);
    }
  }

  using Reply = std::function<void(CefRefPtr<CefDictionaryValue>)>;

  void Call(CefRefPtr<CefBrowser> browser,
            const std::string& method,
            CefRefPtr<CefDictionaryValue> params,
            Reply done = nullptr) {
    int id = browser->GetHost()->ExecuteDevToolsMethod(0, method, params);
    if (id == 0) {
      if (done) {
        done(nullptr);
      }
    } else if (done) {
      replies_[id] = std::move(done);
    }
  }

  void CallRaw(CefRefPtr<CefBrowser> browser,
               const std::string& method,
               const std::string& params,
               RawReply done) {
    CefRefPtr<CefDictionaryValue> args;
    if (!params.empty()) {
      CefRefPtr<CefValue> value = CefParseJSON(params, JSON_PARSER_RFC);
      if (!value || value->GetType() != VTYPE_DICTIONARY) {
        done(false, "{\"message\":\"params must be a JSON object\"}");
        return;
      }
      args = value->GetDictionary();
    }
    int id = browser->GetHost()->ExecuteDevToolsMethod(0, method, args);
    if (id == 0) {
      done(false, "{\"message\":\"the command could not be sent\"}");
    } else {
      raw_replies_[id] = std::move(done);
    }
  }

  void SetPicking(CefRefPtr<CefBrowser> browser, bool picking) {
    if (picking == picking_) {
      return;
    }
    picking_ = picking;
    if (picking) {
      Call(browser, "DOM.enable", nullptr);
      Call(browser, "Overlay.enable", nullptr);
    }
    CefRefPtr<CefDictionaryValue> args = CefDictionaryValue::Create();
    args->SetString("mode", picking ? "searchForNode" : "none");
    if (picking) {
      auto rgba = [](int r, int g, int b, double a) {
        CefRefPtr<CefDictionaryValue> c = CefDictionaryValue::Create();
        c->SetInt("r", r);
        c->SetInt("g", g);
        c->SetInt("b", b);
        c->SetDouble("a", a);
        return c;
      };
      CefRefPtr<CefDictionaryValue> highlight = CefDictionaryValue::Create();
      highlight->SetBool("showInfo", true);
      highlight->SetBool("showStyles", true);
      highlight->SetBool("showAccessibilityInfo", true);
      highlight->SetDictionary("contentColor", rgba(111, 168, 220, 0.66));
      highlight->SetDictionary("paddingColor", rgba(147, 196, 125, 0.55));
      highlight->SetDictionary("borderColor", rgba(255, 229, 153, 0.66));
      highlight->SetDictionary("marginColor", rgba(246, 178, 107, 0.66));
      args->SetDictionary("highlightConfig", highlight);
    }
    Call(browser, "Overlay.setInspectMode", args);
    if (!picking) {
      if (!forwarding_) {
        Call(browser, "Overlay.disable", nullptr);
        Call(browser, "DOM.disable", nullptr);
      }
      [view_ engineDidStopPicking];
    }
  }

  void SetNetworkOverrides(CefRefPtr<CefBrowser> browser,
                           bool cache_disabled,
                           double latency,
                           double throughput) {
    bool needed = cache_disabled || latency != 0 || throughput != 0 ||
                  recording_network_ || forwarding_;
    if (needed && !network_enabled_) {
      Call(browser, "Network.enable", nullptr);
    }
    CefRefPtr<CefDictionaryValue> cache = CefDictionaryValue::Create();
    cache->SetBool("cacheDisabled", cache_disabled);
    Call(browser, "Network.setCacheDisabled", cache);
    CefRefPtr<CefDictionaryValue> conditions = CefDictionaryValue::Create();
    conditions->SetBool("offline", throughput < 0);
    conditions->SetDouble("latency", std::max(latency, 0.0));
    conditions->SetDouble("downloadThroughput",
                          throughput > 0 ? throughput : -1);
    conditions->SetDouble("uploadThroughput", throughput > 0 ? throughput : -1);
    Call(browser, "Network.emulateNetworkConditions", conditions);
    if (!needed && network_enabled_) {
      Call(browser, "Network.disable", nullptr);
    }
    network_enabled_ = needed;
  }

  void CaptureFullPage(CefRefPtr<CefBrowser> browser,
                       void (^completion)(NSData*)) {
    CefRefPtr<WebClient> client(this);
    Call(browser, "Page.getLayoutMetrics", nullptr,
         [client, browser, completion](CefRefPtr<CefDictionaryValue> metrics) {
           CefRefPtr<CefDictionaryValue> size =
               metrics ? metrics->GetDictionary("cssContentSize") : nullptr;
           if (!size) {
             completion(nil);
             return;
           }
           CefRefPtr<CefDictionaryValue> clip = CefDictionaryValue::Create();
           clip->SetDouble("x", 0);
           clip->SetDouble("y", 0);
           clip->SetDouble("width", Number(size->GetValue("width")));
           clip->SetDouble("height",
                           std::min(Number(size->GetValue("height")), 16384.0));
           clip->SetDouble("scale", 1);
           CefRefPtr<CefDictionaryValue> args = CefDictionaryValue::Create();
           args->SetString("format", "png");
           args->SetBool("captureBeyondViewport", true);
           args->SetDictionary("clip", clip);
           client->Call(browser, "Page.captureScreenshot", args,
                        [completion](CefRefPtr<CefDictionaryValue> shot) {
                          CefRefPtr<CefBinaryValue> png =
                              shot ? CefBase64Decode(shot->GetString("data"))
                                   : nullptr;
                          if (!png || png->GetSize() == 0) {
                            completion(nil);
                            return;
                          }
                          NSMutableData* data =
                              [NSMutableData dataWithLength:png->GetSize()];
                          png->GetData(data.mutableBytes, data.length, 0);
                          completion(data);
                        });
         });
  }

  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request,
      bool is_navigation,
      bool is_download,
      const CefString& request_initiator,
      bool& disable_default_handling) override {
    if (g_extension_bridge &&
        request->GetURL().ToString().rfind(kBridgeOrigin, 0) == 0) {
      return BridgeHandlerFor(
          browser->GetHost()->GetRequestContext()->GetCachePath().ToString(),
          request, request_initiator);
    }
    return g_request_filter && !is_download ? this : nullptr;
  }

  ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefFrame> frame,
                                   CefRefPtr<CefRequest> request,
                                   CefRefPtr<CefCallback> callback) override {
    const char* kind = RequestKind(request->GetResourceType());
    if (!kind || !browser) {
      return RV_CONTINUE;
    }
    NSString* page = ToNS(browser->GetMainFrame()->GetURL());
    if (!g_request_filter(ToNS(request->GetURL()), page, @(kind))) {
      return RV_CONTINUE;
    }
    blocked_++;
    if (!report_pending_.exchange(true)) {
      __weak MBWebView* view = view_;
      CefRefPtr<WebClient> client(this);
      dispatch_async(dispatch_get_main_queue(), ^{
        client->report_pending_ = false;
        [view engineSetBlockedCount:client->blocked_];
      });
    }
    return RV_CANCEL;
  }

  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                 TerminationStatus status,
                                 int error_code,
                                 const CefString& error_string) override {
    MBWebView* view = view_;
    [view.delegate webViewRendererDidTerminate:view];
  }

  void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefFrame> frame,
                           CefRefPtr<CefContextMenuParams> params,
                           CefRefPtr<CefMenuModel> model) override {
    if (!params->GetLinkUrl().empty()) {
      model->InsertItemAt(0, kOpenLinkInNewTab, "Open Link in New Tab");
      model->InsertItemAt(1, kCopyLink, "Copy Link Address");
      model->InsertSeparatorAt(2);
    }
    if (model->GetCount() > 0) {
      model->AddSeparator();
    }
    AddExtensionItems(params, model);
    model->AddItem(kInspect, "Inspect");
  }

  void AddExtensionItems(CefRefPtr<CefContextMenuParams> params,
                         CefRefPtr<CefMenuModel> model) {
    MBWebView* view = view_;
    extension_items_.clear();
    menu_context_ = nil;
    if (![view.delegate
            respondsToSelector:@selector(webView:contextMenuItemsFor:)]) {
      return;
    }
    NSDictionary* context = MenuContext(params);
    NSArray<NSDictionary*>* items = [view.delegate webView:view
                                       contextMenuItemsFor:context];
    if (items.count == 0) {
      return;
    }
    menu_context_ = context;
    AddItems(items, model);
    model->AddSeparator();
  }

  void AddItems(NSArray<NSDictionary*>* items, CefRefPtr<CefMenuModel> model) {
    int group = 0;
    NSString* last_type = nil;
    for (NSDictionary* item in items) {
      NSString* type = item[@"type"] ?: @"normal";
      if ([type isEqualToString:@"separator"]) {
        model->AddSeparator();
        last_type = type;
        continue;
      }
      int command = kFirstExtensionItem + (int)extension_items_.size();
      extension_items_.push_back([item[@"id"] UTF8String] ?: "");
      std::string title = [item[@"title"] UTF8String] ?: "";
      NSArray* children = item[@"children"];
      if (children.count) {
        AddItems(children, model->AddSubMenu(command, title));
      } else if ([type isEqualToString:@"checkbox"]) {
        model->AddCheckItem(command, title);
        model->SetChecked(command, [item[@"checked"] boolValue]);
      } else if ([type isEqualToString:@"radio"]) {
        if (![last_type isEqualToString:@"radio"]) {
          group++;
        }
        model->AddRadioItem(command, title, group);
        model->SetChecked(command, [item[@"checked"] boolValue]);
      } else {
        model->AddItem(command, title);
      }
      if (item[@"enabled"] && ![item[@"enabled"] boolValue]) {
        model->SetEnabled(command, false);
      }
      last_type = type;
    }
  }

  bool OnContextMenuCommand(CefRefPtr<CefBrowser> browser,
                            CefRefPtr<CefFrame> frame,
                            CefRefPtr<CefContextMenuParams> params,
                            int command_id,
                            EventFlags event_flags) override {
    MBWebView* view = view_;
    switch (command_id) {
      case kOpenLinkInNewTab:
        [view.delegate webView:view
            requestsNewTabWithURL:ToNS(params->GetLinkUrl())
                       foreground:NO];
        return true;
      case kCopyLink:
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:ToNS(params->GetLinkUrl())
                                          forType:NSPasteboardTypeString];
        return true;
      case kInspect:
        if (inspector_picks_) {
          double zoom = pow(1.2, browser->GetHost()->GetZoomLevel());
          [view engineInspectAt:NSMakePoint(params->GetXCoord() / zoom,
                                            params->GetYCoord() / zoom)];
          return true;
        }
        [view engineShowDevToolsAt:CefPoint(params->GetXCoord(),
                                            params->GetYCoord())];
        return true;
      default: {
        size_t index = command_id - kFirstExtensionItem;
        if (command_id < kFirstExtensionItem ||
            index >= extension_items_.size() || !menu_context_) {
          return false;
        }
        [view.delegate webView:view
            choseContextMenuItem:@(extension_items_[index].c_str())
                         context:menu_context_];
        return true;
      }
    }
  }

 private:
  __weak MBWebView* view_;
  std::vector<std::string> extension_items_;
  NSDictionary* menu_context_ = nil;
  CefRefPtr<CefRegistration> devtools_;
  std::string document_script_;
  std::string deferred_url_;
  std::vector<std::string> favicon_urls_;
  CFAbsoluteTime created_;
  std::string prepared_url_;
  int pending_add_ = 0;
  std::set<int> stale_adds_;
  std::atomic<NSUInteger> blocked_{0};
  std::atomic<bool> report_pending_{false};
  NSUInteger console_errors_ = 0;
  NSUInteger console_warnings_ = 0;
  bool console_report_pending_ = false;
  std::string form_token_;
  CFAbsoluteTime navigation_started_ = 0;
  int load_error_ = 0;
  std::map<int, Reply> replies_;
  std::map<int, RawReply> raw_replies_;
  bool picking_ = false;
  bool following_frames_ = false;
  bool recording_network_ = false;
  bool forwarding_ = false;
  bool inspector_picks_ = false;
  std::map<int, RawReply> session_replies_;
  int next_session_message_ = 1000000000;
  bool network_enabled_ = false;

  IMPLEMENT_REFCOUNTING(WebClient);
};

}

@implementation MBPermissionPrompt {
  NSString* _message;
  void (^_done)(BOOL);
  NSAlert* _alert;
  NSWindow* _window;
}

- (instancetype)initWithMessage:(NSString*)message
                           done:(void (^)(BOOL allowed))done {
  if ((self = [super init])) {
    _message = [message copy];
    _done = [done copy];
  }
  return self;
}

- (void)showForView:(NSView*)view {
  if (_answered || _shown) {
    return;
  }
  _shown = YES;
  if (DebugEvents()) {
    NSLog(@"permission prompt: %@", _message);
  }
  _alert = [[NSAlert alloc] init];
  _alert.messageText = _message;
  [_alert addButtonWithTitle:@"Allow"];
  [_alert addButtonWithTitle:@"Block"];
  _window = view.window ?: NSApp.keyWindow;
  if (!_window) {
    [self answer:[_alert runModal] == NSAlertFirstButtonReturn];
    return;
  }
  [_alert beginSheetModalForWindow:_window
                 completionHandler:^(NSModalResponse response) {
                   [self answer:response == NSAlertFirstButtonReturn];
                 }];
}

- (void)answer:(BOOL)allowed {
  if (_answered) {
    return;
  }
  _answered = YES;
  if (_alert && _window.attachedSheet == _alert.window) {
    [_window endSheet:_alert.window returnCode:NSAlertSecondButtonReturn];
  }
  void (^done)(BOOL) = _done;
  _done = nil;
  if (done) {
    done(allowed);
  }
}

@end

@interface MBApplication () <CefAppProtocol>
@end

@implementation MBApplication {
  BOOL _handlingSendEvent;
}

- (BOOL)isHandlingSendEvent {
  return _handlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  _handlingSendEvent = handlingSendEvent;
}

- (void)sendEvent:(NSEvent*)event {
  static const bool debug_events = getenv("MBGA_DEBUG_EVENTS") != nullptr;
  if (debug_events && (event.type == NSEventTypeKeyDown)) {
    NSLog(@"key %@ flags=%lx window=%@ firstResponder=%@", event.characters,
          (unsigned long)event.modifierFlags, event.window.title,
          NSStringFromClass([event.window.firstResponder class]));
  }
  NSEventModifierFlags modifiers =
      event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  NSWindow* sheet_parent = NSApp.keyWindow.sheetParent;
  if (event.type == NSEventTypeKeyDown && event.keyCode == 12 &&
      (modifiers & (NSEventModifierFlagCommand | NSEventModifierFlagControl |
                    NSEventModifierFlagOption)) == NSEventModifierFlagCommand &&
      sheet_parent) {
    if (DebugEvents()) {
      NSLog(@"Cmd+Q over a sheet: closing it, then quitting");
    }
    [sheet_parent endSheet:NSApp.keyWindow
                returnCode:NSAlertSecondButtonReturn];
    dispatch_async(dispatch_get_main_queue(), ^{
      [NSApp terminate:nil];
    });
    return;
  }
  CefScopedSendingEvent sendingEventScoper;
  [super sendEvent:event];
}

@end

namespace {

std::string CookieKey(const CefCookie& cookie) {
  return CefString(&cookie.name).ToString() + '\n' +
         CefString(&cookie.domain).ToString() + '\n' +
         CefString(&cookie.path).ToString();
}

class CompletionCallback : public CefCompletionCallback {
 public:
  explicit CompletionCallback(std::function<void()> done)
      : done_(std::move(done)) {}
  void OnComplete() override { done_(); }

 private:
  std::function<void()> done_;
  IMPLEMENT_REFCOUNTING(CompletionCallback);
};

class SetCookieCallback : public CefSetCookieCallback {
 public:
  explicit SetCookieCallback(std::function<void(bool)> done)
      : done_(std::move(done)) {}
  void OnComplete(bool success) override { done_(success); }

 private:
  std::function<void(bool)> done_;
  IMPLEMENT_REFCOUNTING(SetCookieCallback);
};

class CookieKeys : public CefCookieVisitor {
 public:
  explicit CookieKeys(std::function<void(std::set<std::string>)> done)
      : done_(std::move(done)) {}
  ~CookieKeys() override {
    auto done = std::move(done_);
    auto keys = std::move(keys_);
    dispatch_async(dispatch_get_main_queue(), ^{
      done(keys);
    });
  }
  bool Visit(const CefCookie& cookie, int, int, bool&) override {
    keys_.insert(CookieKey(cookie));
    return true;
  }

 private:
  std::function<void(std::set<std::string>)> done_;
  std::set<std::string> keys_;
  IMPLEMENT_REFCOUNTING(CookieKeys);
};

}

@implementation MBCookie
@end

@implementation MBEngine

+ (void)showExtensionsForProfilePath:(NSString*)profilePath url:(NSString*)url {
  ExtensionsClient::Show(profilePath.UTF8String, url.UTF8String);
}

+ (void)setExtensionBridge:(MBExtensionBridge)bridge
                pageScript:(nullable MBPageScript)script {
  g_extension_bridge = bridge;
  g_extension_script = script;
}

+ (void)prepareProfilePath:(NSString*)profilePath {
  ContextForPath(profilePath.UTF8String);
}

+ (BOOL)isExtensionsPage:(NSString*)url {
  return IsExtensionsPage(url.UTF8String);
}

+ (BOOL)isExtensionsWindow:(NSWindow*)window {
  for (const CefRefPtr<CefBrowser>& browser : g_auxiliary) {
    NSView* view = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
    if (view.window == window &&
        browser->GetHost()->GetRuntimeStyle() == CEF_RUNTIME_STYLE_CHROME) {
      return YES;
    }
  }
  return NO;
}

+ (BOOL)performChromeCommand:(MBChromeCommand)command {
  NSWindow* key = NSApp.keyWindow;
  if (!key) {
    return NO;
  }
  for (const CefRefPtr<CefBrowser>& browser : g_auxiliary) {
    NSView* view = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
    if (view.window != key ||
        browser->GetHost()->GetRuntimeStyle() != CEF_RUNTIME_STYLE_CHROME) {
      continue;
    }
    SEL dispatch = NSSelectorFromString(@"commandDispatch:");
    if (![key respondsToSelector:dispatch]) {
      return NO;
    }
    NSMenuItem* item = [[NSMenuItem alloc] init];
    item.tag = command;
    [NSApp sendAction:dispatch to:key from:item];
    return YES;
  }
  return NO;
}

+ (void)setRejectsDrops:(BOOL)reject {
  g_reject_drops = reject;
}

+ (void)importCookies:(NSArray<MBCookie*>*)cookies
      intoProfilePath:(NSString*)profilePath
           completion:(void (^)(NSInteger added,
                                NSInteger kept,
                                NSInteger refused))completion {
  auto list =
      std::make_shared<std::vector<std::pair<std::string, CefCookie>>>();
  for (MBCookie* c in cookies) {
    std::string domain = c.domain.UTF8String ?: "";
    bool wide = !domain.empty() && domain[0] == '.';
    std::string host = wide ? domain.substr(1) : domain;
    if (host.empty()) {
      continue;
    }
    std::string path = c.path.length ? c.path.UTF8String : "/";
    CefCookie cookie;
    CefString(&cookie.name) = std::string(c.name.UTF8String ?: "");
    CefString(&cookie.value) = std::string(c.value.UTF8String ?: "");
    if (wide) {
      CefString(&cookie.domain) = domain;
    }
    CefString(&cookie.path) = path;
    cookie.secure = c.secure;
    cookie.httponly = c.httpOnly;
    cookie.creation.val = c.created;
    cookie.last_access.val = c.lastUsed;
    cookie.has_expires = c.expires != 0;
    cookie.expires.val = c.expires;
    cookie.same_site =
        static_cast<cef_cookie_same_site_t>(std::clamp(c.sameSite + 1, 0, 3));
    cookie.priority =
        static_cast<cef_cookie_priority_t>(std::clamp(c.priority - 1, -1, 1));
    std::string url = (c.secure ? "https://" : "http://") + host + path;
    list->emplace_back(url, cookie);
  }
  CefRefPtr<CefRequestContext> context = ContextForPath(profilePath.UTF8String);
  auto finish = [completion](NSInteger added, NSInteger kept,
                             NSInteger refused) {
    dispatch_async(dispatch_get_main_queue(), ^{
      completion(added, kept, refused);
    });
  };
  context->GetCookieManager(new CompletionCallback([context, list, finish] {
    CefRefPtr<CefCookieManager> manager = context->GetCookieManager(nullptr);
    if (!manager) {
      finish(0, 0, list->size());
      return;
    }
    manager->VisitAllCookies(
        new CookieKeys([manager, list, finish](std::set<std::string> keys) {
          struct Tally {
            size_t pending = 0;
            NSInteger added = 0, kept = 0, refused = 0;
          };
          auto tally = std::make_shared<Tally>();
          std::vector<const std::pair<std::string, CefCookie>*> todo;
          for (const auto& item : *list) {
            CefCookie keyed = item.second;
            if (!CefString(&keyed.domain).length()) {
              std::string url = item.first;
              size_t start = url.find("://") + 3;
              CefString(&keyed.domain) =
                  url.substr(start, url.find('/', start) - start);
            }
            if (keys.count(CookieKey(keyed))) {
              tally->kept++;
            } else {
              todo.push_back(&item);
            }
          }
          tally->pending = todo.size();
          auto settled = [manager, tally, finish] {
            if (--tally->pending == 0) {
              manager->FlushStore(nullptr);
              finish(tally->added, tally->kept, tally->refused);
            }
          };
          if (todo.empty()) {
            finish(0, tally->kept, 0);
            return;
          }
          for (const auto* item : todo) {
            bool started = manager->SetCookie(
                item->first, item->second,
                new SetCookieCallback([tally, settled](bool success) {
                  if (success) {
                    tally->added++;
                  } else {
                    tally->refused++;
                  }
                  settled();
                }));
            if (!started) {
              tally->refused++;
              settled();
            }
          }
        }));
  }));
}

+ (void)setRequestFilter:(MBRequestFilter)filter
              pageScript:(MBPageScript)script
               pageReply:(MBPageReply)reply
             earlyScript:(MBEarlyScript)early {
  g_request_filter = filter;
  g_page_script = script;
  g_page_reply = reply;
  g_early_script = early;
}

+ (void)setFormScript:(NSString*)script {
  g_form_script = script.UTF8String;
}

+ (BOOL)usesMockKeychain {
#if defined(MBGA_MOCK_KEYCHAIN)
  return YES;
#else
  return NO;
#endif
}

+ (BOOL)claimDevToolsPipe {
  if (fcntl(3, F_GETFD) != -1 || fcntl(4, F_GETFD) != -1) {
    return NO;
  }
  int to_browser[2], from_browser[2];
  if (pipe(to_browser) != 0) {
    return NO;
  }
  if (pipe(from_browser) != 0) {
    close(to_browser[0]);
    close(to_browser[1]);
    return NO;
  }
  g_pipe_write = fcntl(to_browser[1], F_DUPFD_CLOEXEC, 10);
  g_pipe_read = fcntl(from_browser[0], F_DUPFD_CLOEXEC, 10);
  int browser_read = fcntl(to_browser[0], F_DUPFD, 10);
  int browser_write = fcntl(from_browser[1], F_DUPFD, 10);
  for (int fd :
       {to_browser[0], to_browser[1], from_browser[0], from_browser[1]}) {
    close(fd);
  }
  bool claimed = g_pipe_write >= 0 && g_pipe_read >= 0 && browser_read >= 0 &&
                 browser_write >= 0 && dup2(browser_read, 3) == 3 &&
                 dup2(browser_write, 4) == 4;
  close(browser_read);
  close(browser_write);
  if (!claimed) {
    close(g_pipe_write);
    close(g_pipe_read);
    close(3);
    close(4);
    g_pipe_write = g_pipe_read = -1;
    return NO;
  }
  int fd = g_pipe_read;
  [NSThread detachNewThreadWithBlock:^{
    std::string buffer;
    char chunk[65536];
    ssize_t n;
    while ((n = read(fd, chunk, sizeof chunk)) > 0 ||
           (n < 0 && errno == EINTR)) {
      if (n < 0) {
        continue;
      }
      buffer.append(chunk, n);
      size_t start = 0, end;
      while ((end = buffer.find('\0', start)) != std::string::npos) {
        NSString* message =
            [[NSString alloc] initWithBytes:buffer.data() + start
                                     length:end - start
                                   encoding:NSUTF8StringEncoding];
        start = end + 1;
        dispatch_async(dispatch_get_main_queue(), ^{
          if (g_pipe_handler && message) {
            g_pipe_handler(message);
          }
        });
      }
      buffer.erase(0, start);
    }
  }];
  return YES;
}

+ (void)setLoadsExtensionHelper:(BOOL)loads {
  g_extension_helper = loads;
}

+ (void)setBrowserDevToolsHandler:(void (^)(NSString*))handler {
  g_pipe_handler = handler;
}

+ (void)sendBrowserDevToolsMessage:(NSString*)json {
  if (g_pipe_write < 0) {
    return;
  }
  NSData* data = [json dataUsingEncoding:NSUTF8StringEncoding];
  NSMutableData* framed = [data mutableCopy];
  [framed appendBytes:"" length:1];
  const char* bytes = (const char*)framed.bytes;
  size_t left = framed.length;
  while (left > 0) {
    ssize_t n = write(g_pipe_write, bytes, left);
    if (n < 0 && errno == EINTR) {
      continue;
    }
    if (n <= 0) {
      return;
    }
    bytes += n;
    left -= n;
  }
}

+ (BOOL)startWithArgc:(int)argc
                   argv:(char**)argv
          rootCachePath:(NSString*)rootCachePath
    strictSiteIsolation:(BOOL)strictSiteIsolation
        isolatedOrigins:(NSArray<NSString*>*)isolatedOrigins {
  g_strict_site_isolation = strictSiteIsolation;
  g_isolated_origins =
      [isolatedOrigins componentsJoinedByString:@","].UTF8String;
  g_library_loader = new CefScopedLibraryLoader();
  if (!g_library_loader->LoadInMain()) {
    return NO;
  }
  g_views = [NSMutableSet set];

  CefMainArgs main_args(argc, argv);
  CefSettings settings;
#if !defined(CEF_USE_SANDBOX)
  settings.no_sandbox = true;
#endif
  CefString(&settings.root_cache_path) = rootCachePath.UTF8String;
  CefString(&settings.log_file) =
      [rootCachePath stringByAppendingPathComponent:@"engine.log"].UTF8String;
  settings.log_severity = LOGSEVERITY_WARNING;
  settings.persist_session_cookies = true;
  settings.background_color = 0xFFFFFFFF;

  CefRefPtr<BrowserApp> app(new BrowserApp);
  return CefInitialize(main_args, settings, app.get(), nullptr);
}

+ (void)runMessageLoop {
  CefRunMessageLoop();
}

+ (void)closeAllAndQuit {
  if (g_quitting) {
    return;
  }
  g_quitting = true;
  for (NSWindow* window in NSApp.windows) {
    if (window.attachedSheet) {
      [window endSheet:window.attachedSheet
            returnCode:NSAlertSecondButtonReturn];
    }
  }
  if (DebugEvents()) {
    NSLog(@"quitting: %d browsers, %lu tab views, %zu auxiliary",
          g_browser_count, (unsigned long)g_views.count, g_auxiliary.size());
    for (MBWebView* view in g_views) {
      NSLog(@"  tab %llu closing=%d", view.tabID, view.closing);
    }
  }
  for (MBWebView* view in g_views.allObjects) {
    [view close];
  }
  for (const CefRefPtr<CefBrowser>& browser :
       std::vector<CefRefPtr<CefBrowser>>(g_auxiliary)) {
    browser->GetHost()->CloseBrowser(true);
  }
  if (g_browser_count == 0) {
    CefQuitMessageLoop();
  }
}

+ (void)shutdown {
  g_contexts.clear();
  CefShutdown();
  delete g_library_loader;
  g_library_loader = nullptr;
}

@end

@implementation MBWebView {
  CefRefPtr<WebClient> _client;
  CefRefPtr<CefBrowser> _browser;
  NSString* _pendingURL;
  BOOL _mediaPlaying;
  BOOL _capturing;
  BOOL _frozen;
  NSMutableArray<MBPermissionPrompt*>* _prompts;
  NSMutableDictionary<NSString*, NSString*>* _mediaFeatures;
  NSMutableDictionary<NSString*, NSString*>* _frameSessions;
  BOOL _followsFrames;
  BOOL _forwardsDevToolsEvents;
  BOOL _picksForInspector;
  NSMutableArray<dispatch_block_t>* _pendingCommands;
  NSString* _mobileUserAgent;
  BOOL _scriptsDisabled;
  BOOL _cacheDisabled;
  double _latency;
  double _throughput;
}

- (instancetype)initWithURL:(NSString*)url
                profilePath:(NSString*)profilePath
                      tabID:(uint64_t)tabID {
  self = [super initWithFrame:NSMakeRect(0, 0, 800, 600)];
  if (!self) {
    return nil;
  }
  _tabID = tabID;
  self.wantsLayer = YES;
  _client = new WebClient(self);

  CefWindowInfo info;
  info.SetAsChild((__bridge CefWindowHandle)self, CefRect(0, 0, 800, 600));
  info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings settings;
  settings.background_color = 0xFFFFFFFF;

  [g_views addObject:self];
  g_browser_count++;
  std::string start = url.UTF8String;
  bool web = [url hasPrefix:@"https://"] || [url hasPrefix:@"http://"];
  bool extension = [url hasPrefix:@"chrome-extension://"];
  if ((g_page_script && web && (!g_early_script || g_early_script(url))) ||
      (g_extension_script && extension)) {
    _client->DeferFirstLoad(start);
    start = "about:blank";
  }
  if (!CefBrowserHost::CreateBrowser(info, _client, start, settings, nullptr,
                                     ContextForPath(profilePath.UTF8String))) {
    _closing = YES;
    [g_views removeObject:self];
    BrowserGone();
  }
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (void)engineAddPrompt:(MBPermissionPrompt*)prompt {
  if (_closing) {
    [prompt answer:NO];
    return;
  }
  if (!_prompts) {
    _prompts = [NSMutableArray array];
  }
  [_prompts addObject:prompt];
  if (!self.isHiddenOrHasHiddenAncestor) {
    [prompt showForView:self];
  }
}

- (void)viewDidUnhide {
  [super viewDidUnhide];
  [_prompts filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(
                                                  MBPermissionPrompt* prompt,
                                                  id bindings) {
              return !prompt.answered;
            }]];
  for (MBPermissionPrompt* prompt in [_prompts copy]) {
    [prompt showForView:self];
  }
}

- (void)didAddSubview:(NSView*)subview {
  [super didAddSubview:subview];
  subview.frame = self.bounds;
  subview.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
}

- (void)loadURL:(NSString*)url {
  if (_browser) {
    _browser->GetMainFrame()->LoadURL(url.UTF8String);
  } else {
    _pendingURL = [url copy];
  }
}

- (void)goBack {
  if (_browser) {
    _browser->GoBack();
  }
}

- (void)goForward {
  if (_browser) {
    _browser->GoForward();
  }
}

- (void)reload {
  if (_browser) {
    _browser->Reload();
  }
}

- (void)stopLoading {
  if (_browser) {
    _browser->StopLoad();
  }
}

- (void)zoomIn {
  if (_browser) {
    _browser->GetHost()->Zoom(CEF_ZOOM_COMMAND_IN);
  }
}

- (void)zoomOut {
  if (_browser) {
    _browser->GetHost()->Zoom(CEF_ZOOM_COMMAND_OUT);
  }
}

- (void)resetZoom {
  if (_browser) {
    _browser->GetHost()->Zoom(CEF_ZOOM_COMMAND_RESET);
  }
}

- (void)showDevTools {
  [self engineShowDevToolsAt:CefPoint()];
}

- (void)closeDevTools {
  if (_browser) {
    _browser->GetHost()->CloseDevTools();
  }
}

- (void)engineShowDevToolsAt:(CefPoint)at {
  if (!_browser) {
    return;
  }
  if (_browser->GetHost()->HasDevTools()) {
    ShowDevTools(_browser, at);
    [_devToolsWindow makeKeyAndOrderFront:nil];
    return;
  }
  CefWindowInfo info;
  CefBrowserSettings settings;
  _browser->GetHost()->ShowDevTools(info, new DevToolsClient(self), settings,
                                    at);
}

- (void)engineDevToolsOpened:(NSWindow*)window {
  if (!window || _devToolsWindow == window) {
    return;
  }
  _devToolsWindow = window;
  [self.delegate webViewDidChangeDevTools:self];
}

- (void)engineDevToolsClosed {
  if (!_devToolsWindow) {
    return;
  }
  _devToolsWindow = nil;
  [self.delegate webViewDidChangeDevTools:self];
}

- (void)reloadIgnoringCache {
  if (_browser) {
    _browser->ReloadIgnoreCache();
  }
}

- (void)setPicking:(BOOL)picking {
  if (_browser) {
    _client->SetPicking(_browser, picking);
  }
}

- (void)emulateMediaFeature:(NSString*)name value:(NSString*)value {
  if (!_mediaFeatures) {
    _mediaFeatures = [NSMutableDictionary dictionary];
  }
  _mediaFeatures[name] = value.length > 0 ? value : nil;
  if (!_browser) {
    return;
  }
  CefRefPtr<CefListValue> features = CefListValue::Create();
  for (NSString* feature in _mediaFeatures) {
    CefRefPtr<CefDictionaryValue> entry = CefDictionaryValue::Create();
    entry->SetString("name", feature.UTF8String);
    entry->SetString("value", _mediaFeatures[feature].UTF8String);
    features->SetDictionary(features->GetSize(), entry);
  }
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetList("features", features);
  _client->Call(_browser, "Emulation.setEmulatedMedia", params);
}

- (void)emulateMobileWithUserAgent:(NSString*)userAgent {
  _mobileUserAgent = [userAgent copy];
  if (!_browser) {
    return;
  }
  BOOL mobile = userAgent != nil;
  if (mobile) {
    CefRefPtr<CefDictionaryValue> metrics = CefDictionaryValue::Create();
    metrics->SetInt("width", 0);
    metrics->SetInt("height", 0);
    metrics->SetDouble("deviceScaleFactor", 0);
    metrics->SetBool("mobile", true);
    _client->Call(_browser, "Emulation.setDeviceMetricsOverride", metrics);
  } else {
    _client->Call(_browser, "Emulation.clearDeviceMetricsOverride", nullptr);
  }
  CefRefPtr<CefDictionaryValue> touch = CefDictionaryValue::Create();
  touch->SetBool("enabled", mobile);
  touch->SetInt("maxTouchPoints", 5);
  _client->Call(_browser, "Emulation.setTouchEmulationEnabled", touch);
  CefRefPtr<CefDictionaryValue> agent = CefDictionaryValue::Create();
  agent->SetString("userAgent", mobile ? userAgent.UTF8String : "");
  _client->Call(_browser, "Emulation.setUserAgentOverride", agent);
}

- (void)setCacheDisabled:(BOOL)disabled {
  _cacheDisabled = disabled;
  if (_browser) {
    _client->SetNetworkOverrides(_browser, _cacheDisabled, _latency,
                                 _throughput);
  }
}

- (void)setScriptsDisabled:(BOOL)disabled {
  _scriptsDisabled = disabled;
  if (!_browser) {
    return;
  }
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetBool("value", disabled);
  _client->Call(_browser, "Emulation.setScriptExecutionDisabled", params);
}

- (void)emulateNetworkWithLatency:(double)latency
                       throughput:(double)throughput {
  _latency = latency;
  _throughput = throughput;
  if (_browser) {
    _client->SetNetworkOverrides(_browser, _cacheDisabled, _latency,
                                 _throughput);
  }
}

- (void)clearSiteDataAndReload {
  if (!_browser) {
    return;
  }
  CefURLParts parts;
  if (!CefParseURL(_browser->GetMainFrame()->GetURL(), parts)) {
    return;
  }
  std::string origin = CefString(&parts.origin).ToString();
  if (!origin.empty() && origin.back() == '/') {
    origin.pop_back();
  }
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("origin", origin);
  params->SetString("storageTypes", "all");
  CefRefPtr<CefBrowser> browser = _browser;
  _client->Call(_browser, "Storage.clearDataForOrigin", params,
                [browser](CefRefPtr<CefDictionaryValue>) {
                  browser->ReloadIgnoreCache();
                });
}

- (void)captureFullPage:(void (^)(NSData* _Nullable))completion {
  if (!_browser) {
    completion(nil);
    return;
  }
  _client->CaptureFullPage(_browser, completion);
}

- (void)sendDevToolsCommand:(NSString*)method
                     params:(NSString*)params
                 completion:(void (^)(NSString*, NSString*))completion {
  if (!_browser) {
    [self waitForBrowser:^(BOOL ready) {
      if (ready) {
        [self sendDevToolsCommand:method params:params completion:completion];
      } else {
        completion(nil, @"the page isn't loaded");
      }
    }];
    return;
  }
  _client->CallRaw(
      _browser, method.UTF8String, params.UTF8String ?: "",
      [completion](bool success, const std::string& json) {
        NSString* text = @(json.c_str());
        if (success) {
          completion(text, nil);
          return;
        }
        NSDictionary* error = [NSJSONSerialization
            JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding]
                       options:0
                         error:nil];
        completion(nil,
                   [error isKindOfClass:NSDictionary.class] && error[@"message"]
                       ? error[@"message"]
                       : text);
      });
}

- (void)sendDevToolsCommand:(NSString*)method
                     params:(NSString*)params
                    session:(NSString*)session
                 completion:(void (^)(NSString*, NSString*))completion {
  if (!session) {
    [self sendDevToolsCommand:method params:params completion:completion];
    return;
  }
  if (!_browser) {
    [self waitForBrowser:^(BOOL ready) {
      if (ready) {
        [self sendDevToolsCommand:method
                           params:params
                          session:session
                       completion:completion];
      } else {
        completion(nil, @"the page isn't loaded");
      }
    }];
    return;
  }
  _client->CallInSession(
      _browser, method.UTF8String, params.UTF8String ?: "", session.UTF8String,
      [completion](bool success, const std::string& json) {
        NSString* text = @(json.c_str());
        if (success) {
          completion(text, nil);
          return;
        }
        NSDictionary* error = [NSJSONSerialization
            JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding]
                       options:0
                         error:nil];
        completion(nil,
                   [error isKindOfClass:NSDictionary.class] && error[@"message"]
                       ? error[@"message"]
                       : text);
      });
}

- (void)waitForBrowser:(void (^)(BOOL ready))then {
  if (_closing) {
    then(NO);
    return;
  }
  if (!_pendingCommands) {
    _pendingCommands = [NSMutableArray array];
  }
  [_pendingCommands addObject:^{
    then(YES);
  }];
}

- (void)attachToFrames {
  _followsFrames = YES;
  if (_browser) {
    _client->FollowFrames(_browser);
  }
}

- (NSDictionary<NSString*, NSString*>*)frameSessions {
  return [_frameSessions copy] ?: @{};
}

- (void)setRecordsNetwork:(BOOL)records {
  if (_recordsNetwork == records) {
    return;
  }
  _recordsNetwork = records;
  if (_browser) {
    _client->SetRecordingNetwork(records);
    _client->SetNetworkOverrides(_browser, _cacheDisabled, _latency,
                                 _throughput);
  }
}

- (void)engineFrameAttached:(NSString*)frame session:(NSString*)session {
  if (!_frameSessions) {
    _frameSessions = [NSMutableDictionary dictionary];
  }
  _frameSessions[frame] = session;
}

- (void)engineFrameDetached:(NSString*)session {
  [_frameSessions
      removeObjectsForKeys:[_frameSessions allKeysForObject:session]];
}

- (void)engineNetworkEvent:(NSString*)method params:(NSDictionary*)params {
  [self.delegate webView:self didObserveNetworkEvent:method params:params];
}

- (BOOL)forwardsDevToolsEvents {
  return _forwardsDevToolsEvents;
}

- (void)setForwardsDevToolsEvents:(BOOL)forwards {
  if (_forwardsDevToolsEvents == forwards) {
    return;
  }
  _forwardsDevToolsEvents = forwards;
  if (_browser) {
    _client->SetForwardingEvents(forwards);
    _client->SetNetworkOverrides(_browser, _cacheDisabled, _latency,
                                 _throughput);
  }
}

- (BOOL)picksForInspector {
  return _picksForInspector;
}

- (void)setPicksForInspector:(BOOL)picks {
  _picksForInspector = picks;
  _client->SetPicksForInspector(picks);
}

- (void)engineDevToolsEvent:(NSString*)method params:(NSDictionary*)params {
  [self.delegate webView:self didReceiveDevToolsEvent:method params:params];
}

- (void)engineDidPickNode:(int)backendNodeId {
  [self.delegate webView:self didPickNode:backendNodeId];
}

- (void)engineInspectAt:(NSPoint)point {
  [self.delegate webView:self inspectsElementAt:point];
}

- (void)focusContent {
  if (_browser) {
    _browser->GetHost()->SetFocus(true);
  }
}

- (void)runScript:(NSString*)script {
  if (_browser) {
    _browser->GetMainFrame()->ExecuteJavaScript(script.UTF8String, "", 0);
  }
}

- (void)probeMedia {
  if (_browser && !_capturing) {
    _browser->GetMainFrame()->ExecuteJavaScript(kMediaProbeScript, "", 0);
  }
}

- (void)setMediaPaused:(BOOL)paused {
  if (_browser) {
    _browser->GetMainFrame()->ExecuteJavaScript(
        paused ? kPauseMediaScript : kResumeMediaScript, "", 0);
  }
}

- (void)setFrozen:(BOOL)frozen {
  if (!_browser || _frozen == frozen) {
    return;
  }
  _frozen = frozen;
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("state", frozen ? "frozen" : "active");
  _browser->GetHost()->ExecuteDevToolsMethod(0, "Page.setWebLifecycleState",
                                             params);
}

- (void)close {
  if (_closing) {
    return;
  }
  if (DebugEvents()) {
    NSLog(@"tab %llu: close requested (frozen=%d, browser=%d)", _tabID, _frozen,
          _browser != nullptr);
  }
  for (MBPermissionPrompt* prompt in _prompts) {
    [prompt answer:NO];
  }
  _prompts = nil;
  if (_frozen) {
    [self setFrozen:NO];
  }
  _closing = YES;
  if (_browser) {
    _browser->GetHost()->CloseBrowser(true);
    [self scheduleCloseFallback];
  }
}

- (void)scheduleCloseFallback {
  __weak MBWebView* weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{
                   MBWebView* view = weakSelf;
                   if (view && view->_browser) {
                     if (DebugEvents()) {
                       NSLog(@"tab %llu: close fallback, %lu engine views",
                             view.tabID, (unsigned long)view.subviews.count);
                     }
                     [view engineWillCloseBrowser];
                   }
                 });
}

- (int)browserIdentifier {
  return _browser ? _browser->GetIdentifier() : 0;
}

- (void)engineDidCreateBrowser:(CefRefPtr<CefBrowser>)browser {
  _browser = browser;
  if (self.isHiddenOrHasHiddenAncestor) {
    NSView* host = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
    [host removeFromSuperview];
    [self addSubview:host];
  }
  [self applyEmulations];
  NSArray<dispatch_block_t>* pending = _pendingCommands;
  _pendingCommands = nil;
  for (dispatch_block_t command in pending) {
    command();
  }
  if (_closing) {
    _browser->GetHost()->CloseBrowser(true);
    [self scheduleCloseFallback];
  } else if (_pendingURL) {
    _client->CancelDeferredLoad();
    _browser->GetMainFrame()->LoadURL(_pendingURL.UTF8String);
    _pendingURL = nil;
  }
}

- (void)applyEmulations {
  if (_followsFrames) {
    _client->FollowFrames(_browser);
  }
  if (_forwardsDevToolsEvents) {
    _client->SetForwardingEvents(true);
  }
  if (_recordsNetwork || _forwardsDevToolsEvents) {
    _client->SetRecordingNetwork(_recordsNetwork);
    _client->SetNetworkOverrides(_browser, _cacheDisabled, _latency,
                                 _throughput);
  }
  if (_mediaFeatures.count > 0) {
    NSString* name = _mediaFeatures.allKeys.firstObject;
    [self emulateMediaFeature:name value:_mediaFeatures[name]];
  }
  if (_mobileUserAgent) {
    [self emulateMobileWithUserAgent:_mobileUserAgent];
  }
  if (_scriptsDisabled) {
    [self setScriptsDisabled:YES];
  }
  if (_cacheDisabled || _latency != 0 || _throughput != 0) {
    _client->SetNetworkOverrides(_browser, _cacheDisabled, _latency,
                                 _throughput);
  }
}

- (void)engineWillCloseBrowser {
  if (DebugEvents()) {
    NSLog(@"tab %llu: DoClose / teardown", _tabID);
  }
  _closing = YES;
  NSArray<dispatch_block_t>* pending = _pendingCommands;
  _pendingCommands = nil;
  for (dispatch_block_t command in pending) {
    command();
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    for (NSView* subview in [self.subviews copy]) {
      [subview removeFromSuperview];
    }
  });
}

- (void)engineDidCloseBrowser {
  if (DebugEvents()) {
    NSLog(@"tab %llu: closed", _tabID);
  }
  _browser = nullptr;
  [self.delegate webViewDidClose:self];
  [g_views removeObject:self];
}

- (void)engineSetMediaPlaying:(BOOL)playing {
  BOOL wasBusy = _mediaPlaying || _capturing;
  _mediaPlaying = playing;
  if (wasBusy != (_mediaPlaying || _capturing)) {
    [self.delegate webView:self didChangeBusy:!wasBusy];
  }
}

- (void)engineSetThemeColor:(NSString*)color {
  [self.delegate webView:self didChangeThemeColor:color];
}

- (void)engineSetBlockedCount:(NSUInteger)count {
  [self.delegate webView:self didChangeBlockedCount:count];
}

- (void)engineSetConsoleErrors:(NSUInteger)errors
                      warnings:(NSUInteger)warnings {
  [self.delegate webView:self didChangeConsoleErrors:errors warnings:warnings];
}

- (void)engineDidFinishLoad:(int)status duration:(NSTimeInterval)duration {
  [self.delegate webView:self didFinishLoadWithStatus:status duration:duration];
}

- (void)engineDidStopPicking {
  [self.delegate webViewDidStopPicking:self];
}

- (void)engineSetCapturing:(BOOL)capturing {
  BOOL wasBusy = _mediaPlaying || _capturing;
  _capturing = capturing;
  if (wasBusy != (_mediaPlaying || _capturing)) {
    [self.delegate webView:self didChangeBusy:!wasBusy];
  }
}

@end
