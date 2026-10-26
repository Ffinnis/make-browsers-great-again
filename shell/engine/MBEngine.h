#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MBApplication : NSApplication
@end

@class MBWebView;

typedef BOOL (^MBRequestFilter)(NSString* url, NSString* page, NSString* kind);
typedef NSString* _Nonnull (^MBPageScript)(NSString* page);
typedef NSString* _Nonnull (^MBPageReply)(NSString* page, NSString* report);
typedef BOOL (^MBEarlyScript)(NSString* page);
typedef void (^MBCredentialsHandler)(
    NSString* host,
    NSString* realm,
    BOOL proxy,
    NSWindow* _Nullable window,
    void (^reply)(NSString* _Nullable user, NSString* _Nullable password));

@protocol MBWebViewDelegate <NSObject>
- (void)webView:(MBWebView*)view didChangeURL:(NSString*)url;
- (void)webView:(MBWebView*)view didChangeTitle:(NSString*)title;
- (void)webView:(MBWebView*)view
    didChangeLoading:(BOOL)loading
           canGoBack:(BOOL)canGoBack
        canGoForward:(BOOL)canGoForward;
- (void)webView:(MBWebView*)view didReceiveFavicon:(NSData*)png;
- (void)webView:(MBWebView*)view didChangeBusy:(BOOL)busy;
- (void)webView:(MBWebView*)view
    requestsNewTabWithURL:(NSString*)url
               foreground:(BOOL)foreground;
- (void)webView:(MBWebView*)view didChangeFullscreen:(BOOL)fullscreen;
- (void)webViewRendererDidTerminate:(MBWebView*)view;
- (void)webView:(MBWebView*)view didChangeThemeColor:(NSString*)color;
- (void)webView:(MBWebView*)view didChangeBlockedCount:(NSUInteger)count;
- (void)webViewDidClose:(MBWebView*)view;
- (void)webView:(MBWebView*)view
    didChangeConsoleErrors:(NSUInteger)errors
                  warnings:(NSUInteger)warnings;
- (void)webView:(MBWebView*)view
    didFinishLoadWithStatus:(int)status
                   duration:(NSTimeInterval)duration;
- (void)webView:(MBWebView*)view
    opensExtensionsPage:(NSString*)url
               fromPage:(NSString*)page;
- (void)webViewDidStopPicking:(MBWebView*)view;
- (void)webViewDidChangeDevTools:(MBWebView*)view;
- (void)webView:(MBWebView*)view
    didLogConsoleMessage:(NSString*)message
                   level:(NSInteger)level
                  source:(NSString*)source
                    line:(int)line;
- (void)webView:(MBWebView*)view
    didObserveNetworkEvent:(NSString*)method
                    params:(NSDictionary*)params;
- (void)webView:(MBWebView*)view
    didReceiveDevToolsEvent:(NSString*)method
                     params:(NSDictionary*)params;
- (void)webView:(MBWebView*)view didPickNode:(NSInteger)backendNodeId;
- (void)webView:(MBWebView*)view inspectsElementAt:(NSPoint)point;
- (void)webView:(MBWebView*)view
    didReceiveFormMessage:(NSString*)message
                      url:(NSString*)url
                    frame:(NSString*)frameID;

@optional
- (void)webView:(MBWebView*)view
    didFindMatches:(NSInteger)count
            active:(NSInteger)active
          finished:(BOOL)finished;
- (NSArray<NSDictionary*>*)webView:(MBWebView*)view
               contextMenuItemsFor:(NSDictionary*)context;
- (void)webView:(MBWebView*)view
    choseContextMenuItem:(NSString*)itemID
                 context:(NSDictionary*)context;
- (void)webView:(MBWebView*)view requestsNewWindowWithURL:(NSString*)url;
- (nullable NSString*)searchEngineNameForWebView:(MBWebView*)view;
- (void)webView:(MBWebView*)view searchesFor:(NSString*)text;
- (void)webView:(MBWebView*)view didChangeStatus:(NSString*)status;
- (void)webView:(MBWebView*)view
    didReportScroll:(double)scroll
            editing:(BOOL)editing;
- (void)webView:(MBWebView*)view
    requestsCredentialsForHost:(NSString*)host
                         realm:(NSString*)realm
                         proxy:(BOOL)proxy
                         reply:(void (^)(NSString* _Nullable user,
                                         NSString* _Nullable password))reply;
@end

@interface MBNavigationEntry : NSObject
@property(nonatomic, copy) NSString* url;
@property(nonatomic, copy) NSString* title;
@end

@interface MBCookie : NSObject
@property(nonatomic, copy) NSString* domain;
@property(nonatomic, copy) NSString* name;
@property(nonatomic, copy) NSString* value;
@property(nonatomic, copy) NSString* path;
@property(nonatomic) BOOL secure;
@property(nonatomic) BOOL httpOnly;
@property(nonatomic) int64_t expires;
@property(nonatomic) int64_t created;
@property(nonatomic) int64_t lastUsed;
@property(nonatomic) int sameSite;
@property(nonatomic) int priority;
@end

typedef NS_ENUM(NSInteger, MBDownloadState) {
  MBDownloadStateRunning,
  MBDownloadStatePaused,
  MBDownloadStateDone,
  MBDownloadStateFailed,
  MBDownloadStateCanceled,
};

@interface MBDownload : NSObject
@property(nonatomic, readonly) uint32_t identifier;
@property(nonatomic, readonly, copy) NSString* url;
@property(nonatomic, readonly, copy) NSString* path;
@property(nonatomic, readonly) int64_t received;
@property(nonatomic, readonly) int64_t total;
@property(nonatomic, readonly) int64_t speed;
@property(nonatomic, readonly) MBDownloadState state;
@end

typedef NS_ENUM(NSInteger, MBChromeCommand) {
  MBChromeCommandBack = 33000,
  MBChromeCommandForward = 33001,
  MBChromeCommandReload = 33002,
  MBChromeCommandReloadIgnoringCache = 33007,
  MBChromeCommandNewTab = 34014,
  MBChromeCommandCloseTab = 34015,
  MBChromeCommandReopenTab = 34028,
  MBChromeCommandZoomIn = 38001,
  MBChromeCommandActualSize = 38002,
  MBChromeCommandFind = 37000,
  MBChromeCommandFindNext = 37001,
  MBChromeCommandFindPrevious = 37002,
  MBChromeCommandZoomOut = 38003,
  MBChromeCommandFocusLocation = 39001,
};

@interface MBEngine : NSObject

+ (BOOL)claimDevToolsPipe;
+ (void)setLoadsExtensionHelper:(BOOL)loads;
+ (void)setBrowserDevToolsHandler:(void (^)(NSString* message))handler;
+ (void)sendBrowserDevToolsMessage:(NSString*)json;

+ (BOOL)startWithArgc:(int)argc
                   argv:(char* _Nullable* _Nonnull)argv
          rootCachePath:(NSString*)rootCachePath
    strictSiteIsolation:(BOOL)strictSiteIsolation
        isolatedOrigins:(NSArray<NSString*>*)isolatedOrigins;

+ (void)runMessageLoop;

+ (void)closeAllAndQuit;
+ (void)quitAskingPages;
+ (void)setCredentialsHandler:(MBCredentialsHandler)handler;
@property(class, nonatomic, readonly) BOOL isQuitting;

+ (void)shutdown;

+ (void)setRejectsDrops:(BOOL)reject;

+ (void)importCookies:(NSArray<MBCookie*>*)cookies
      intoProfilePath:(NSString*)profilePath
           completion:(void (^)(NSInteger added,
                                NSInteger kept,
                                NSInteger refused))completion
    NS_SWIFT_NAME(importCookies(_:intoProfilePath:completion:));

+ (void)showExtensionsForProfilePath:(NSString*)profilePath url:(NSString*)url;

typedef void (^MBExtensionBridge)(NSString* profilePath,
                                  NSString* extensionID,
                                  int browserID,
                                  NSString* path,
                                  NSString* body,
                                  void (^reply)(NSString* json));

+ (void)setExtensionBridge:(MBExtensionBridge)bridge
                pageScript:(nullable MBPageScript)script;

+ (void)prepareProfilePath:(NSString*)profilePath;

+ (BOOL)isExtensionsWindow:(NSWindow*)window;

+ (BOOL)isExtensionsPage:(NSString*)url;

+ (BOOL)performChromeCommand:(MBChromeCommand)command
    NS_SWIFT_NAME(performChromeCommand(_:));

+ (void)setRequestFilter:(MBRequestFilter)filter
              pageScript:(MBPageScript)script
               pageReply:(MBPageReply)reply
             earlyScript:(MBEarlyScript)early;

+ (void)setFormScript:(NSString*)script;

+ (void)setConvertsVideo:(BOOL)converts;

+ (void)setDownloadHandler:(void (^)(MBDownload* download))handler;
+ (void)cancelDownload:(uint32_t)identifier;
+ (void)pauseDownload:(uint32_t)identifier;
+ (void)resumeDownload:(uint32_t)identifier;

@property(class, nonatomic, readonly) BOOL usesMockKeychain;

@end

@interface MBWebView : NSView

- (instancetype)initWithURL:(NSString*)url
                profilePath:(NSString*)profilePath
                      tabID:(uint64_t)tabID NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder*)coder NS_UNAVAILABLE;

@property(nonatomic, readonly) uint64_t tabID;
@property(nonatomic, readonly) int browserIdentifier;
@property(nonatomic, weak, nullable) id<MBWebViewDelegate> delegate;
@property(nonatomic, readonly, getter=isClosing) BOOL closing;

- (void)loadURL:(NSString*)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stopLoading;
- (void)printPage;
- (void)exitFullscreen;
@property(nonatomic) BOOL audioMuted;
@property(nonatomic, readonly) BOOL canGoBack;
@property(nonatomic, readonly) BOOL canGoForward;
- (void)replaceURL:(NSString*)url;
- (void)goBy:(NSInteger)offset;
- (NSArray<MBNavigationEntry*>*)navigationEntries:(NSInteger*)current;
- (void)saveURLAs:(NSString*)url;
- (void)zoomIn;
- (void)zoomOut;
- (void)resetZoom;
- (void)findText:(NSString*)text forward:(BOOL)forward next:(BOOL)next;
- (void)stopFinding:(BOOL)clearSelection;
- (void)showDevTools;
- (void)closeDevTools;
@property(nonatomic, readonly, nullable) NSWindow* devToolsWindow;

- (void)reloadIgnoringCache;
- (void)setPicking:(BOOL)picking;
- (void)emulateMediaFeature:(NSString*)name value:(NSString*)value;
- (void)emulateMobileWithUserAgent:(nullable NSString*)userAgent;
- (void)setCacheDisabled:(BOOL)disabled;
- (void)setScriptsDisabled:(BOOL)disabled;
- (void)emulateNetworkWithLatency:(double)latency throughput:(double)throughput;
- (void)clearSiteDataAndReload;
- (void)captureFullPage:(void (^)(NSData* _Nullable png))completion;

- (void)sendDevToolsCommand:(NSString*)method
                     params:(nullable NSString*)params
                 completion:(void (^)(NSString* _Nullable result,
                                      NSString* _Nullable error))completion;
- (void)sendDevToolsCommand:(NSString*)method
                     params:(nullable NSString*)params
                    session:(nullable NSString*)session
                 completion:(void (^)(NSString* _Nullable result,
                                      NSString* _Nullable error))completion;
- (void)attachToFrames;
@property(nonatomic, readonly)
    NSDictionary<NSString*, NSString*>* frameSessions;
@property(nonatomic) BOOL recordsNetwork;
@property(nonatomic) BOOL forwardsDevToolsEvents;
@property(nonatomic) BOOL picksForInspector;
- (void)focusContent;
- (void)runScript:(NSString*)script;
- (void)runScript:(NSString*)script inFrame:(NSString*)frameID;
- (void)probeMedia;
- (void)setMediaPaused:(BOOL)paused;
- (void)setFrozen:(BOOL)frozen;
- (void)close;
- (void)closeAskingPage:(void (^)(BOOL closed))reply;

@end

NS_ASSUME_NONNULL_END
