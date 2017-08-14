/*
 * Copyright 2017 Google Inc. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "ViewController.h"
#import "Renderer.h"

// TODO: Should this be a percentage?
#define URL_TEXTFIELD_HEIGHT 30

@interface ViewController ()<MTKViewDelegate, ARSessionDelegate>

@property(nonatomic, strong) ARSession *session;
@property(nonatomic, strong) Renderer *renderer;

@end

@interface MTKView ()<RenderDestinationProvider>

@end

@implementation ViewController

- (void)showAlertDialog:(NSString *)message
      completionHandler:(void (^)(void))completionHandler {
  UIAlertController *alertController =
      [UIAlertController alertControllerWithTitle:message
                                          message:nil
                                   preferredStyle:UIAlertControllerStyleAlert];
  [alertController
      addAction:[UIAlertAction actionWithTitle:@"OK"
                                         style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction *action) {
                                         if (completionHandler) {
                                           completionHandler();
                                         }
                                       }]];
  [self presentViewController:alertController
                     animated:YES
                   completion:^{
                   }];
}

- (void)setWKWebViewScrollEnabled:(BOOL)enabled {
  self->wkWebView.scrollView.scrollEnabled = enabled;
  self->wkWebView.scrollView.panGestureRecognizer.enabled = enabled;
  self->wkWebView.scrollView.bounces = enabled;
}

- (bool)loadURLInWKWebView:(NSString *)urlString {
  bool result = true;
  // Try to create a url with the provided string
  NSURL *nsurl = [NSURL URLWithString:urlString];
  bool fileScheme = nsurl && nsurl.scheme &&
                    [[nsurl.scheme lowercaseString] isEqualToString:@"file"];
  // Quick hack: If the url string is not a proper URL, try to add http to it to
  // see if it is an actual URL
  if (!nsurl || !nsurl.scheme || !nsurl.host) {
    NSString *urlStringWithHTTP =
        [NSString stringWithFormat:@"http://%@", urlString];
    nsurl = [NSURL URLWithString:urlStringWithHTTP];
  }
  // If the string did not represent a url or is a filescheme url, the way the
  // page is loaded is different
  if (!nsurl || !nsurl.scheme || !nsurl.host || fileScheme) {
    NSString *nsurlPath = urlString;
    NSString *pathExtension = @"html";
    // If the file:// scheme was provided, remove the scheme and trim the
    // extension if included.
    if (fileScheme) {
      nsurlPath = [NSString stringWithFormat:@"%@%@", nsurl.host, nsurl.path];
      if ([[nsurl.pathExtension lowercaseString]
              isEqualToString:pathExtension]) {
        NSRange range =
            [[nsurlPath lowercaseString] rangeOfString:@".html"
                                               options:NSBackwardsSearch];
        nsurlPath = [nsurlPath stringByReplacingCharactersInRange:range
                                                       withString:@""];
      }
    } else {
      // If the file:// was not provided, trim the extension if included.
      NSRange range =
          [[nsurlPath lowercaseString] rangeOfString:@".html"
                                             options:NSBackwardsSearch];
      if (range.location != NSNotFound &&
          range.location == nsurlPath.length - 5) {
        nsurlPath = [nsurlPath stringByReplacingCharactersInRange:range
                                                       withString:@""];
      }
    }
    //        NSLog(@"nsurlPath = %@", nsurlPath);
    // Is the URL string a path to a file?
    NSString *path =
        [[NSBundle mainBundle] pathForResource:nsurlPath ofType:pathExtension];
    // If the path is incorrect, it could be because is a path to a folder
    // instead of a file
    if (!path) {
      path = [[NSBundle mainBundle] pathForResource:nsurlPath ofType:nil];
    }
    bool isDirectory = false;
    //        NSLog(@"Loading a file from resources with path = %@", path);
    // Make sure that the path exists and get a flag to indicate if the path
    // represents a directory
    if (path &&
        [[NSFileManager defaultManager] fileExistsAtPath:path
                                             isDirectory:&isDirectory]) {
      // If the path is to a directory, add the index at the end (try to load
      // index.html).
      if (isDirectory) {
        nsurlPath = [NSString stringWithFormat:@"%@/index", nsurlPath];
      }
      NSURL *url = [[NSBundle mainBundle] URLForResource:nsurlPath
                                           withExtension:pathExtension];
      // The final URL to the resource may fail so just in case...
      if (!url) {
        result = false;
      } else {
        //                NSLog(@"Loading a file from resources with url = %@",
        //                url.absoluteString);
        [self->wkWebView loadRequest:[NSURLRequest requestWithURL:url]];
      }
    } else {
      result = false;
    }
  } else {
    NSURLRequest *nsrequest = [NSURLRequest requestWithURL:nsurl];
    [self->wkWebView loadRequest:nsrequest];
  }
  return result;
}

- (NSString *)getURLFromUserDefaults {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  return [defaults stringForKey:@"url"];
}

- (void)storeURLInUserDefaults:(NSString *)urlString {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults setObject:urlString forKey:@"url"];
  [defaults synchronize];
}

- (void)viewDidLoad {
  [super viewDidLoad];

  self->near = 0.01f;
  self->far = 10000.0f;

  // Create an ARSession
  self.session = [ARSession new];
  self.session.delegate = self;

  // Set the view to use the default device
  MTKView *view = (MTKView *)self.view;
  view.device = MTLCreateSystemDefaultDevice();
  view.delegate = self;

  if (!view.device) {
    NSLog(@"Metal is not supported on this device");
    return;
  }

  // Configure the renderer to draw to the view
  self.renderer = [[Renderer alloc] initWithSession:self.session
                                        metalDevice:view.device
                          renderDestinationProvider:view];

  [self.renderer drawRectResized:view.bounds.size];

  UITapGestureRecognizer *tapGesture =
      [[UITapGestureRecognizer alloc] initWithTarget:self
                                              action:@selector(handleTap:)];
  NSMutableArray *gestureRecognizers = [NSMutableArray array];
  [gestureRecognizers addObject:tapGesture];
  [gestureRecognizers addObjectsFromArray:view.gestureRecognizers];
  view.gestureRecognizers = gestureRecognizers;

  // Clear the webview completely
  //    NSSet *websiteDataTypes = [NSSet setWithArray:@[
  //        WKWebsiteDataTypeDiskCache,
  //        //WKWebsiteDataTypeOfflineWebApplicationCache,
  //        WKWebsiteDataTypeMemoryCache,
  //        //WKWebsiteDataTypeLocalStorage,
  //        //WKWebsiteDataTypeCookies,
  //        //WKWebsiteDataTypeSessionStorage,
  //        //WKWebsiteDataTypeIndexedDBDatabases,
  //        //WKWebsiteDataTypeWebSQLDatabases
  //    ]];
  NSSet *websiteDataTypes = [WKWebsiteDataStore allWebsiteDataTypes];
  NSDate *dateFrom = [NSDate dateWithTimeIntervalSince1970:0];
  [[WKWebsiteDataStore defaultDataStore] removeDataOfTypes:websiteDataTypes
                                             modifiedSince:dateFrom
                                         completionHandler:^{
                                         }];
  // Make sure that WebARForARKit.js is injected at the beginning of any webpage
  // Load the WebARForARKit.js file
  NSString *WebARForARKitJSPath =
      [[NSBundle mainBundle] pathForResource:@"WebARForARKit" ofType:@"js"];
  //  NSLog(WebARForARKitJSPath);
  NSString *WebARForARKitJSContent =
      [NSString stringWithContentsOfFile:WebARForARKitJSPath
                                encoding:NSUTF8StringEncoding
                                   error:NULL];
  //  NSLog(WebARForARKitJSContent);
  // Setup the script injection
  WKUserScript *WebARForARKitJSUserScript = [[WKUserScript alloc]
        initWithSource:WebARForARKitJSContent
         injectionTime:WKUserScriptInjectionTimeAtDocumentStart
      forMainFrameOnly:true];
  WKUserContentController *userContentController =
      [[WKUserContentController alloc] init];
  [userContentController addScriptMessageHandler:self name:@"WebARForARKit"];
  [userContentController addUserScript:WebARForARKitJSUserScript];
  WKWebViewConfiguration *wkWebViewConfig =
      [[WKWebViewConfiguration alloc] init];
  wkWebViewConfig.userContentController = userContentController;
  // Create the WKWebView using the configuration/script injection and add it to
  // the top of the view graph
  self->wkWebView = [[WKWebView alloc]
      initWithFrame:CGRectMake(
                        0, URL_TEXTFIELD_HEIGHT, self.view.frame.size.width,
                        self.view.frame.size.height - URL_TEXTFIELD_HEIGHT)
      configuration:wkWebViewConfig];
  self->wkWebView.opaque = false;
  self->wkWebView.backgroundColor = [UIColor clearColor];
  self->wkWebView.scrollView.backgroundColor = [UIColor clearColor];
  [self->wkWebView.configuration.preferences
      setValue:@TRUE
        forKey:@"allowFileAccessFromFileURLs"];
  [self setWKWebViewScrollEnabled:false];
  // Needed to show alerts. Check the WKUIDelegate protocol and the
  // runJavaScriptAlertPanelWithMessage method in this file :(
  self->wkWebView.UIDelegate = self;
  self->wkWebView.navigationDelegate = self;
  [self.view addSubview:self->wkWebView];

  // Add a textfield for the URL on top of the webview
  self->urlTextField = [[UITextField alloc]
      initWithFrame:CGRectMake(0, 0, self.view.frame.size.width,
                               URL_TEXTFIELD_HEIGHT)];
  self->urlTextField.backgroundColor = [UIColor whiteColor];
  [self->urlTextField setKeyboardType:UIKeyboardTypeURL];
  self->urlTextField.autocapitalizationType = UITextAutocapitalizationTypeNone;
  self->urlTextField.delegate = self;
  [self.view addSubview:self->urlTextField];

  self->initialPageLoadedWhenTrackingBegins = false;

  UIDevice *device = [UIDevice currentDevice];
  [device beginGeneratingDeviceOrientationNotifications];
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(deviceOrientationDidChange:)
             name:UIDeviceOrientationDidChangeNotification
           object:nil];
  deviceOrientation = [device orientation];
  [self updateOrientation];
}

- (void)deviceOrientationDidChange:(NSNotification *)notification {
  [self->urlTextField setFrame:CGRectMake(0, 0, self.view.frame.size.width,
                                          URL_TEXTFIELD_HEIGHT)];
  [self->wkWebView
      setFrame:CGRectMake(0, URL_TEXTFIELD_HEIGHT, self.view.frame.size.width,
                          self.view.frame.size.height - URL_TEXTFIELD_HEIGHT)];
  updateWindowSize = true;
  [self updateOrientation];
}

- (void)updateOrientation {
  deviceOrientation = [[UIDevice currentDevice] orientation];
  switch (deviceOrientation) {
    case UIDeviceOrientationPortrait: {
      interfaceOrientation = UIInterfaceOrientationPortrait;
    } break;

    case UIDeviceOrientationPortraitUpsideDown: {
      interfaceOrientation = UIInterfaceOrientationPortraitUpsideDown;
    } break;

    case UIDeviceOrientationLandscapeLeft: {
      interfaceOrientation = UIInterfaceOrientationLandscapeRight;
    } break;

    case UIDeviceOrientationLandscapeRight: {
      interfaceOrientation = UIInterfaceOrientationLandscapeLeft;
    } break;

    default:
      break;
  }
  [self->_renderer setInterfaceOrientation:interfaceOrientation];
}
- (void)restartSession {
  ARWorldTrackingConfiguration *configuration =
      [ARWorldTrackingConfiguration new];
  configuration.planeDetection = ARPlaneDetectionHorizontal;
  [self.session runWithConfiguration:configuration
                             options:ARSessionRunOptionResetTracking];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];

  UIDevice *device = [UIDevice currentDevice];
  if (![device isGeneratingDeviceOrientationNotifications]) {
    [device beginGeneratingDeviceOrientationNotifications];
  }

  [self restartSession];
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];

  UIDevice *device = [UIDevice currentDevice];
  if ([device isGeneratingDeviceOrientationNotifications]) {
    [device endGeneratingDeviceOrientationNotifications];
  }
  [self.session pause];
}

- (void)didReceiveMemoryWarning {
  [super didReceiveMemoryWarning];
  // Release any cached data, images, etc that aren't in use.
}

- (void)handleTap:(UIGestureRecognizer *)gestureRecognize {
  ARFrame *currentFrame = [self.session currentFrame];

  // Create anchor using the camera's current position
  if (currentFrame) {
    // Create a transform with a translation of 0.2 meters in front of the
    // camera
    matrix_float4x4 translation = matrix_identity_float4x4;
    translation.columns[3].z = -0.2;
    matrix_float4x4 transform =
        matrix_multiply(currentFrame.camera.transform, translation);

    // Add a new anchor to the session
    ARAnchor *anchor = [[ARAnchor alloc] initWithTransform:transform];
    [self.session addAnchor:anchor];
  }
}

#pragma mark - MTKViewDelegate

// Called whenever view changes orientation or layout is changed
- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size {
  [self.renderer drawRectResized:view.bounds.size];
}

// Called whenever the view needs to render
- (void)drawInMTKView:(nonnull MTKView *)view {
  [self.renderer update];
}

#pragma mark - ARSessionDelegate

- (void)session:(ARSession *)session didFailWithError:(NSError *)error {
  // Present an error message to the user
}

- (void)sessionWasInterrupted:(ARSession *)session {
  // Inform the user that the session has been interrupted, for example, by
  // presenting an overlay
}

- (void)sessionInterruptionEnded:(ARSession *)session {
  // Reset tracking and/or remove existing anchors if consistent tracking is
  // required
}

- (void)session:(ARSession *)session didUpdateFrame:(ARFrame *)frame {
  // If the window size has changed, notify the JS side about it.
  // This is a hack due to the WKWebView not handling the
  // window.innerWidth/Height
  // correctly in the window.onresize events.
  // TODO: Remove this hack once the WKWebView has fixed the issue.
  if (updateWindowSize) {
    int width = self.view.frame.size.width;
    int height = self.view.frame.size.height - URL_TEXTFIELD_HEIGHT;
    NSString *updateWindowSizeJsCode = [NSString
        stringWithFormat:
            @"if(window.WebARForARKitSetWindowSize)"
            @"WebARForARKitSetWindowSize({\"width\":%i,\"height\":%i});",
            width, height];
    [self->wkWebView
        evaluateJavaScript:updateWindowSizeJsCode
         completionHandler:^(id data, NSError *error) {
           if (error) {
             [self showAlertDialog:
                       [NSString stringWithFormat:
                                     @"ERROR: Evaluating jscode to provide "
                                     @"window size: %@",
                                     error]
                 completionHandler:^{
                 }];
           }
         }];
    updateWindowSize = false;
  }

  // Send the per frame data needed in the JS side
  matrix_float4x4 viewMatrix =
      [frame.camera viewMatrixForOrientation:interfaceOrientation];
  matrix_float4x4 modelMatrix = matrix_invert(viewMatrix);
  matrix_float4x4 projectionMatrix = [frame.camera
      projectionMatrixForOrientation:interfaceOrientation
                        viewportSize:CGSizeMake(self.view.frame.size.width,
                                                self.view.frame.size.height -
                                                    URL_TEXTFIELD_HEIGHT)
                               zNear:self->near
                                zFar:self->far];

  const float *pModelMatrix = (const float *)(&modelMatrix);
  const float *pViewMatrix = (const float *)(&viewMatrix);
  const float *pProjectionMatrix = (const float *)(&projectionMatrix);

  simd_quatf orientationQuat = simd_quaternion(modelMatrix);
  const float *pOrientationQuat = (const float *)(&orientationQuat);
  float position[3];
  position[0] = pModelMatrix[12];
  position[1] = pModelMatrix[13];
  position[2] = pModelMatrix[14];

  // TODO: Testing to see if we can pass the whole frame to JS...
  //  size_t width = CVPixelBufferGetWidth(frame.capturedImage);
  //  size_t height = CVPixelBufferGetHeight(frame.capturedImage);
  //  size_t bytesPerRow = CVPixelBufferGetBytesPerRow(frame.capturedImage);
  //  void* pixels = CVPixelBufferGetBaseAddress(frame.capturedImage);
  //  OSType pixelFormatType =
  //  CVPixelBufferGetPixelFormatType(frame.capturedImage);
  //  NSLog(@"width = %d, height = %d, bytesPerRow = %d, ostype = %d", width,
  //  height, bytesPerRow, pixelFormatType);

  NSString *jsCode = [NSString
      stringWithFormat:@"if (window.WebARForARKitSetData) "
                       @"window.WebARForARKitSetData({"
                       @"\"position\":[%f,%f,%f],"
                       @"\"orientation\":[%f,%f,%f,%f],"
                       @"\"viewMatrix\":[%f,%f,%f,%f,%f,%f,%f,%"
                       @"f,%f,%f,%f,%f,%f,%f,%f,%f],"
                       @"\"projectionMatrix\":[%f,%f,%f,%f,%f,%f,%f,%"
                       @"f,%f,%f,%f,%f,%f,%f,%f,%f]"
                       @"});",
                       position[0], position[1], position[2],
                       pOrientationQuat[0], pOrientationQuat[1],
                       pOrientationQuat[2], pOrientationQuat[3], pViewMatrix[0],
                       pViewMatrix[1], pViewMatrix[2], pViewMatrix[3],
                       pViewMatrix[4], pViewMatrix[5], pViewMatrix[6],
                       pViewMatrix[7], pViewMatrix[8], pViewMatrix[9],
                       pViewMatrix[10], pViewMatrix[11], pViewMatrix[12],
                       pViewMatrix[13], pViewMatrix[14], pViewMatrix[15],
                       pProjectionMatrix[0], pProjectionMatrix[1],
                       pProjectionMatrix[2], pProjectionMatrix[3],
                       pProjectionMatrix[4], pProjectionMatrix[5],
                       pProjectionMatrix[6], pProjectionMatrix[7],
                       pProjectionMatrix[8], pProjectionMatrix[9],
                       pProjectionMatrix[10], pProjectionMatrix[11],
                       pProjectionMatrix[12], pProjectionMatrix[13],
                       pProjectionMatrix[14], pProjectionMatrix[15]];

  [self->wkWebView
      evaluateJavaScript:jsCode
       completionHandler:^(id data, NSError *error) {
         if (error) {
           [self showAlertDialog:
                     [NSString stringWithFormat:@"ERROR: Evaluating jscode: %@",
                                                error]
               completionHandler:^{
               }];
         }
       }];
}

#pragma mark - WKUIDelegate

- (void)webView:(WKWebView *)webView
    runJavaScriptAlertPanelWithMessage:(NSString *)message
                      initiatedByFrame:(WKFrameInfo *)frame
                     completionHandler:(void (^)(void))completionHandler {
  [self showAlertDialog:message completionHandler:completionHandler];
}

- (void)webView:(WKWebView *)webView
    runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt
                              defaultText:(nullable NSString *)defaultText
                         initiatedByFrame:(WKFrameInfo *)frame
                        completionHandler:(void (^)(NSString *_Nullable result))
                                              completionHandler {
  NSString *result = @"";
  NSArray *values = [prompt componentsSeparatedByString:@":"];
  if ([values count] > 1) {
    NSString *method = values[0];
    NSArray *params = [values[1] componentsSeparatedByString:@","];
    if ([method isEqualToString:@"hitTest"]) {
      float x = [params[0] floatValue];
      float y = [params[1] floatValue];
      CGPoint point = CGPointMake(x, y);
      ARFrame *currentFrame = [self.session currentFrame];
      // TODO: Play with the different types of hit tests to see what
      // corresponds best with what tango already provides.
      NSArray<ARHitTestResult *> *hits = [currentFrame
          hitTest:point
            types:(ARHitTestResultType)
                      ARHitTestResultTypeExistingPlaneUsingExtent];

      //        NSArray<ARHitTestResult *> * hits = [currentFrame hitTest:point
      //        types:(ARHitTestResultType)ARHitTestResultTypeExistingPlane];
      if (hits.count > 0) {
        result = @"{\"hits\":[";
        for (int i = 0; i < hits.count; i++) {
          matrix_float4x4 m4x4 = hits[i].worldTransform;
          const float *m = (const float *)(&m4x4);
          NSString *hit = [NSString
              stringWithFormat:
                  @"[%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f,%f]", m[0],
                  m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10],
                  m[11], m[12], m[13], m[14], m[15]];
          result = [result stringByAppendingString:hit];
          if (i < hits.count - 1) {
            result = [result stringByAppendingString:@","];
          }
        }
        result = [result stringByAppendingString:@"]}"];
      }
    }
    // TODO: This could actually be a message. It does not have to be
    // synchronous...
    else if ([method isEqualToString:@"resetPose"]) {
      [self restartSession];
    }
  }
  completionHandler(result);
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView
    didFinishNavigation:(WKNavigation *)navigation {
  [self restartSession];
}

- (void)webView:(WKWebView *)webView
    didFailNavigation:(WKNavigation *)navigation
            withError:(NSError *)error {
  [self showAlertDialog:error.localizedDescription completionHandler:nil];
  NSLog(@"ERROR: webview didFailNavigation with error %@", error);
}

- (void)webViewDidFinishLoad:(UIWebView *)webView {
  [self restartSession];
}

- (void)webView:(WKWebView *)webView
    didFailProvisionalNavigation:(WKNavigation *)navigation
                       withError:(NSError *)error {
  [self showAlertDialog:error.localizedDescription completionHandler:nil];
  NSLog(@"ERROR: webview didFailProvisionalNavigation with error %@", error);
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
  BOOL result = NO;
  NSString *urlString = self->urlTextField.text;
  if (![self loadURLInWKWebView:urlString]) {
    [self showAlertDialog:@"The URL is not valid." completionHandler:NULL];
  } else {
    [self storeURLInUserDefaults:urlString];
    [self->urlTextField resignFirstResponder];
    result = YES;
  }
  return result;
}

#pragma mark - ARSessionObserver

- (void)session:(ARSession *)session
    cameraDidChangeTrackingState:(ARCamera *)camera {
  NSString *trackingStateString = nil;
  if (camera.trackingState == ARTrackingStateNotAvailable) {
    trackingStateString = @"Not Available";
  } else if (camera.trackingState == ARTrackingStateLimited) {
    trackingStateString = @"Limited";
  } else if (camera.trackingState == ARTrackingStateNormal) {
    trackingStateString = @"Normal";
  }
  NSString *trackingStateReasonString = nil;
  if (camera.trackingStateReason == ARTrackingStateReasonExcessiveMotion) {
    trackingStateReasonString = @"Excessive Motion";
  } else if (camera.trackingStateReason ==
             ARTrackingStateReasonInsufficientFeatures) {
    trackingStateReasonString = @"Insufficient Featues";
  }
  NSLog(@"AR camera tracking state = %@%@", trackingStateString,
        (trackingStateReasonString != nil ? trackingStateReasonString : @""));

  // Only the first time the tacking state is something else but unavailable
  // load the initial page.
  if (camera.trackingState != ARTrackingStateNotAvailable &&
      !self->initialPageLoadedWhenTrackingBegins) {
    // Retore a URL from a previous execution and load it.
    NSString *urlString = [self getURLFromUserDefaults];
    if (urlString) {
      // As the code bellow does not allow to store invalid URLs, we will assume
      // that the URL is
      // correct.
      if (![self loadURLInWKWebView:urlString]) {
        [self showAlertDialog:@"The URL is not valid." completionHandler:NULL];
      }
      self->urlTextField.text = urlString;
    }
    self->initialPageLoadedWhenTrackingBegins = true;
  }
}

#pragma mark - WKScriptMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message {
  NSString *messageString = message.body;
  NSArray *values = [messageString componentsSeparatedByString:@":"];
  if ([values count] > 1) {
    NSString *method = values[0];
    NSArray *params = [values[1] componentsSeparatedByString:@","];
    if ([method isEqualToString:@"setDepthNear"]) {
      self->near = [params[0] floatValue];
    } else if ([method isEqualToString:@"setDepthFar"]) {
      self->far = [params[0] floatValue];
    } else if ([method isEqualToString:@"log"]) {
      // As a log command can have colons in its content, just get rid of the
      // 'log:' string and show the rest.
      NSRange range = NSMakeRange(4, messageString.length - 4);
      NSLog(@"%@", [message.body substringWithRange:range]);
    }
  }
}

@end