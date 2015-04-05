//
//  AdiumImgr.m
//  AdiumImgr
//
//  Created by Pavel Skaldin on 1/6/15.
//  Copyright (c) 2015 Pavel Skaldin. All rights reserved.
//

#import "AdiumImgr.h"
#import <Adium/AIContentObject.h>
#import <Adium/AITextAttachmentExtension.h>
#import <HTMLReader/HTMLReader.h>
#import <WebKit/WebKit.h>

typedef enum {
  ProcessPayloadStateInitialized = 0,
  ProcessPayloadStateProcessing,
  ProcessPayloadStateFailed,
  ProcessPayloadStateReady,
} ProcessPayloadState;

@interface ProcessPayload : NSObject
@property (assign, nonatomic) unsigned long long uniqueID;
@property (strong, nonatomic) id context;

@property (strong, nonatomic) NSURL *url;
@property (strong, nonatomic) NSString *mime;

@property (strong, nonatomic) NSAttributedString *attributedString;
@property (strong, nonatomic) NSAttributedString *attributedSuffixString;
@property (strong, nonatomic) NSDictionary *attributes;
@property (assign, nonatomic) NSRange range;

@property (strong, nonatomic) NSImage *image;
@property (strong, nonatomic) NSString *imagePath;
@property (strong, nonatomic) NSURL *imageURL;
@property (strong, nonatomic) NSURL *videoURL;

@property (assign, nonatomic) ProcessPayloadState state;

@property (readonly, nonatomic, getter=containsImageAttachment) BOOL containsImageAttachment;
@property (readonly, nonatomic, getter=containsVideoAttachment) BOOL containsVideoAttachment;
@property (readonly, nonatomic, getter=containsAnyAttachment) BOOL containsAnyAttachment;
@property (readonly, nonatomic, getter=referencesAnyAttachments) BOOL referencesAnyAttachments;
@end

@implementation ProcessPayload

- (BOOL)containsImageAttachment
{
  return self.image != nil && self.imagePath != nil;
}

- (BOOL)containsVideoAttachment
{
  return self.videoURL != nil;
}

- (BOOL)containsAnyAttachment
{
  return self.containsImageAttachment || self.containsVideoAttachment;
}

- (BOOL)referencesAnyAttachments
{
  return self.imageURL != nil || self.videoURL != nil;
}

- (NSString *)description {
  return [NSString stringWithFormat:@"[%@ imageURL=%@; videoURL=%@]", NSStringFromClass([self class]), self.imageURL, self.videoURL];
}

@end

@implementation AdiumImgr
{
  NSMutableSet *_processInfo;
  NSMutableDictionary *_parserInfo;
  NSMutableDictionary *_videoURLs;
}

#pragma mark - AIPlugin

- (void) installPlugin
{
  [self clearCache];
  [[adium contentController] registerDelayedContentFilter:self ofType:AIFilterMessageDisplay direction:AIFilterIncoming];
  
  _processInfo = [NSMutableSet set];
  _parserInfo = [NSMutableDictionary dictionary];
  _videoURLs = [NSMutableDictionary dictionary];
  NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
  [notificationCenter addObserver:self
                         selector:@selector(webProgressFinished:)
                             name:@"WebProgressFinishedNotification"
                           object:nil];
  [notificationCenter addObserver:self
                         selector:@selector(messageReceived:)
                             name:CONTENT_MESSAGE_RECEIVED
                           object:nil];
}

- (void) uninstallPlugin
{
  [[adium contentController] unregisterDelayedContentFilter:self];
  _processInfo = nil;
  _parserInfo = nil;
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - AIContentFilter

- (CGFloat)filterPriority
{
  return DEFAULT_FILTER_PRIORITY;
}

#pragma mark - AIDelayedCotentFilter

- (BOOL)delayedFilterAttributedString:(NSAttributedString *)inAttributedString
                              context:(id)context
                             uniqueID:(unsigned long long)uniqueID
{
  __block BOOL foundLink = NO;
  [inAttributedString enumerateAttributesInRange:NSMakeRange(0, inAttributedString.length)
                                         options:0
                                      usingBlock:^(NSDictionary *attrs, NSRange range, BOOL *stop) {
                                        NSURL *link = attrs[NSLinkAttributeName];
                                        NSString *scheme = [link scheme];
                                        
                                        if ([@"http" isEqualToString:scheme] == YES || [@"https" isEqualToString:scheme] == YES) {
                                          ProcessPayload *info = [[ProcessPayload alloc] init];
                                          info.attributedString = inAttributedString;
                                          info.attributes = attrs;
                                          info.uniqueID = uniqueID;
                                          info.range = range;
                                          info.url = link;
                                          info.context = context;
                                          [_processInfo addObject:info];
                                          foundLink = YES;
                                        }
                                      }];
  
  if (foundLink == YES) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      [self process];
    });
  }
  
  return foundLink;
}

#pragma mark - Processing

- (void)process
{
  NSMutableSet *processInfo = _processInfo;
  
  for (ProcessPayload *payload in processInfo) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      [self processPayload:payload];
    });
  }
}

- (void)willProcessPayload:(ProcessPayload *)payload
{
  payload.state = ProcessPayloadStateProcessing;
}

- (void)didProcessPayload:(ProcessPayload *)payload
{
  if (payload.containsAnyAttachment == YES) {
    payload.state = ProcessPayloadStateReady;
  }
  else {
    payload.state = ProcessPayloadStateFailed;
  }
  [self removePayload:payload];
}

- (void)processPayload:(ProcessPayload *)payload
{
  NSURL *url = payload.url;
  if (url == nil) {
    payload.state = ProcessPayloadStateReady;
  }
  
  ProcessPayloadState state = payload.state;
  
  if (state == ProcessPayloadStateProcessing) {
    return;
  }
  else if (state == ProcessPayloadStateFailed
           || state == ProcessPayloadStateReady) {
    [self didProcessPayload:payload];
    return;
  }
  
  [self willProcessPayload:payload];
  
  if (payload.mime == nil) {
    [self determineMimeForPayload:payload];
  }
  
  NSString *contentType = payload.mime;
  if ([contentType containsString:@"image/"] == YES) {
    payload.imageURL = url;
  }
  else if ([contentType containsString:@"video/"] == YES) {
    payload.videoURL = url;
  }
  else if ([contentType containsString:@"text/html"] == YES) {
    NSDictionary *rules = [self ruleForURL:url];
    if (rules.count > 0) {
      [self processHTMLFromURL:url forPayload:payload withRules:rules];
    }
  }
  
  if (payload.referencesAnyAttachments == NO) {
    [self didProcessPayload:payload];
    return;
  }
  
  if (payload.imageURL != nil
      && payload.containsImageAttachment == NO) {
    [self fetchImageForPayload:payload];
  }
  
  if (payload.containsAnyAttachment == YES) {
    [self finalizePayload:payload];
  }
  
  [self didProcessPayload:payload];
}

- (void)determineMimeForPayload:(ProcessPayload *)payload
{
  NSURL *url = payload.url;
  if (url == nil) {
    return;
  }
  
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                         cachePolicy:NSURLRequestReturnCacheDataElseLoad
                                                     timeoutInterval:3.0];
  [request setHTTPMethod:@"HEAD"];
  NSHTTPURLResponse *response = nil;
  NSError *urlConnectionError = nil;
  [NSURLConnection sendSynchronousRequest:request
                        returningResponse:&response
                                    error:&urlConnectionError];
  NSDictionary *headers = [response allHeaderFields];
  NSString *contentType = headers[@"Content-Type"];
  payload.mime = contentType;
}

- (void)finalizePayload:(ProcessPayload *)payload
{
  NSAttributedString *attributedString = payload.attributedString;
  NSRange range = payload.range;
  NSDictionary *attributes = payload.attributes;
  // use link's name if we have it, otherwise the actual url
  // i.e. link name could be "example" that points to http://example.com
  NSURL *url = payload.url;
  NSURL *link = attributes[NSLinkAttributeName];
  if (link == nil) {
    link = url;
  }
  
  // create image attachment if we have an image.
  // we need to have that image stored in a file on disk and have path to it
  // as that will be used to move the file to appropriate location during
  // conversion to HTML and insertion of HTML fragments into the chat's web view.
  // we don't really have control over that and can't guarantee that we know
  // the destaination path at the moment...
  NSImage *image = payload.image;
  NSString *imagePath = payload.imagePath;
  NSMutableAttributedString *imageString = nil;
  if (image != nil && imagePath != nil) {
    AITextAttachmentExtension *attachment = [[AITextAttachmentExtension alloc] init];
    NSTextAttachmentCell *cell = [[NSTextAttachmentCell alloc] initImageCell:image];
    [attachment setAttachmentCell:cell];
    [attachment setPath:imagePath];
    [attachment setHasAlternate:NO];
    // this class is actually defined in style sheets loaded by Adium but we may want to reconsider their usage
    [attachment setImageClass:@"scaledToFitImage"];
    [attachment setShouldAlwaysSendAsText:NO];
    
    NSString *altText = [NSString stringWithFormat:@"[Image: %@]", [[attributedString string] substringWithRange:range]];
    [attachment setString:altText];
    
    imageString = [[NSAttributedString attributedStringWithAttachment:attachment] mutableCopy];
    [imageString addAttribute:NSAttachmentAttributeName value:attachment range:NSMakeRange(0, imageString.length)];
  }
  else if (payload.videoURL != nil) {
    _videoURLs[url.absoluteString] = @{@"videoURL": payload.videoURL.absoluteString, @"type": payload.mime};
  }
  
  NSMutableAttributedString *newString = [attributedString mutableCopy];
  
  // if we have an image string - append optional suffix string,
  // and insert it into original string, separating it by new line
  if (imageString != nil) {
    NSMutableAttributedString *replacementString = [[NSMutableAttributedString alloc] init];
    NSMutableDictionary *textAttributes = [attributes mutableCopy];
    [textAttributes removeObjectForKey:NSLinkAttributeName];
    if (range.location > 0) {
      [replacementString appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:textAttributes]];
    }
    NSAttributedString *suffix = payload.attributedSuffixString;
    [replacementString appendAttributedString:imageString];
    if (suffix != nil) {
      [replacementString appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:textAttributes]];
      [replacementString appendAttributedString:suffix];
    }
    [replacementString appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:textAttributes]];
    [newString insertAttributedString:replacementString atIndex:range.location];
    payload.attributedString = newString;
  }
}

- (void)removePayload:(ProcessPayload *)payload
{
  [_processInfo removeObject:payload];
  unsigned long long uniqueID = payload.uniqueID;
  BOOL hasPendingProcesses = [self hasPendingProcessesForUniqueID:uniqueID];
  if (hasPendingProcesses == NO) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [[adium contentController] delayedFilterDidFinish:payload.attributedString uniqueID:uniqueID];
    });
  }
}

- (BOOL)hasPendingProcessesForUniqueID:(unsigned long long)uniqueID
{
  if (_processInfo.count == 0) {
    return NO;
  }
  for (ProcessPayload *payload in _processInfo) {
    if (payload.uniqueID == uniqueID) {
      return YES;
    }
  }
  return NO;
}

- (void)fetchImageForPayload:(ProcessPayload *)payload
{
  NSURL *imageURL = payload.imageURL;
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:imageURL
                                                         cachePolicy:NSURLRequestReturnCacheDataElseLoad
                                                     timeoutInterval:3.0];
  NSHTTPURLResponse *response = nil;
  NSError *error = nil;
  NSData *imageData = [NSURLConnection sendSynchronousRequest:request
                                            returningResponse:&response
                                                        error:&error];
  if (error != nil) {
    NSLog(@"Error fetching image from URL: %@", imageURL);
    return;
  }
  
  NSString *cachedPath = nil;
  NSURL *referencingURL = payload.url;
  if (imageData != nil && [self cacheImageData:imageData
                                        forURL:referencingURL
                                    cachedPath:&cachedPath] == YES) {
    NSImage *image = [[NSImage alloc] initWithData:imageData];
    payload.image = image;
    payload.imagePath = cachedPath;
  }
  else {
    NSLog(@"Failed to fetch and save image: %@ [Ref: %@]", imageURL, referencingURL);
  }
}

- (void)processHTMLFromURL:(NSURL *)url
                forPayload:(ProcessPayload *)payload
                 withRules:(NSDictionary *)rules
{
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                         cachePolicy:NSURLRequestReturnCacheDataElseLoad
                                                     timeoutInterval:3.0];
  NSHTTPURLResponse *response = nil;
  NSError *requestError = nil;
  NSData *htmlData = [NSURLConnection sendSynchronousRequest:request
                                           returningResponse:&response
                                                       error:&requestError];
  if (requestError != nil) {
    NSLog(@"Error fetching HTML from URL '%@': %@", [url absoluteString], requestError);
    return;
  }
  if (htmlData.length == 0){
    NSLog(@"Empty HTML from URL '%@'", [url absoluteString]);
    return;
  }
  
  NSString *html = [[NSString alloc] initWithData:htmlData
                                         encoding:NSUTF8StringEncoding];
  HTMLDocument *doc = [HTMLDocument documentWithString:html];
  NSMutableSet *foundURLs = [NSMutableSet set];
  NSMutableDictionary *foundTags = [NSMutableDictionary dictionary];
  for (NSString *query in rules) {
    @try {
      HTMLSelector *selector = [HTMLSelector selectorForString:query];
      NSArray *matchedNodes = [doc nodesMatchingParsedSelector:selector];
      for (HTMLElement *element in matchedNodes) {
        NSString *value = [element valueForKeyPath:[NSString stringWithFormat:@"attributes.%@", rules[query]]];
        if (value != nil) {
          if ([value rangeOfString:@"//"].location == 0) {
            value = [NSString stringWithFormat:@"%@:%@", url.scheme, value];
          }
          else if ([value rangeOfString:@"/"].location == 0) {
            value = [NSString stringWithFormat:@"%@://%@%@", url.scheme, url.host, value];
          }
          
          if (value != nil) {
            [foundURLs addObject:value];
            foundTags[value] = element;
          }
        }
      }
    }
    @catch(NSException *exception) {
      NSLog(@"Error finding HTML Element matching: %@ exception: %@", query, exception);
    }
  }
  
  NSAttributedString *postImageString = nil;
  if (foundURLs.count > 1) {
    NSDictionary *attrs = payload.attributes;
    NSMutableDictionary *textAttributes = [attrs mutableCopy];
    [textAttributes removeObjectForKey:NSLinkAttributeName];
    postImageString = [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"[1 of %i]", (int)foundURLs.count] attributes:textAttributes];
    payload.attributedSuffixString = postImageString;
  }
  
  NSString *firstURLString = [[foundURLs allObjects] firstObject];
  HTMLElement *element = (firstURLString != nil) ? foundTags[firstURLString] : nil;
  NSString *tagName = element.tagName;
  if (firstURLString != nil && tagName != nil) {
    if ([@"source" isEqualToString:tagName] == YES
        || [@"video" isEqualToString:tagName] == YES) {
      NSString *type = [element attributes][@"type"];
      if (type != nil) {
        payload.mime = type;
      }
      payload.videoURL = [NSURL URLWithString:firstURLString];
        }
    else {
      payload.imageURL = [NSURL URLWithString:firstURLString];
    }
  }
}

#pragma mark - Cache

- (NSString *)cacheDirectoryPath {
  NSArray *savePaths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
  if (savePaths.count == 0) {
    NSLog(@"Could not determine location of cache directory");
    return nil;
  }
  NSString *bundleIdentifier = [[self ourBundle] bundleIdentifier];
  NSString *cacheDir = [NSString stringWithFormat:@"%@/%@", [savePaths firstObject], bundleIdentifier];
  return cacheDir;
}

- (void)createCacheDirectory {
  NSString *cacheDir = [self cacheDirectoryPath];
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSError *error = nil;
  BOOL result = [fileManager createDirectoryAtPath:cacheDir withIntermediateDirectories:YES attributes:nil error:&error];
  if (result == NO) {
    NSLog(@"Error creating cache directory: %@", error);
  }
}

- (void) clearCache {
  NSString *cacheDir = [self cacheDirectoryPath];
  NSFileManager *fileManager = [NSFileManager defaultManager];
  if ([fileManager fileExistsAtPath:cacheDir] == YES) {
    NSError *error = nil;
    BOOL result = [fileManager removeItemAtPath:cacheDir error:&error];
    if (result == NO) {
      NSLog(@"Error clearing cache directory: %@; Error: %@", cacheDir, error);
      return;
    }
  }
  [self createCacheDirectory];
}

- (NSString *)cachePathForURL:(NSURL *)url {
  NSString *cacheDir = [self cacheDirectoryPath];
  NSString *fileName = @"";
  NSArray *pathComponents = [url pathComponents];
  if (pathComponents.count > 1) {
    fileName = [[pathComponents subarrayWithRange:NSMakeRange(1, pathComponents.count-1)] componentsJoinedByString:@"_"];
  }
  NSString *path = [NSString stringWithFormat:@"%@/adiumImgr_%@_%@", cacheDir, [url host], fileName];
  return path;
}

- (BOOL)cacheImageData:(NSData *)imageData forURL:(NSURL *)url {
  return [self cacheImageData:imageData forURL:url cachedPath:NULL];
}

- (BOOL)cacheImageData:(NSData *)imageData forURL:(NSURL *)url cachedPath:(NSString **)path {
  NSString *imagePath = [self cachePathForURL:url];
  if (path != nil) {
    *path = imagePath;
  }
  if (imageData == nil) {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *error = nil;
    [fileManager removeItemAtPath:imagePath error:&error];
    if (error != nil) {
      NSLog(@"Error removing cache file: %@", imagePath);
      return NO;
    }
    return YES;
  }
  else {
    return [imageData writeToFile:imagePath atomically:YES];
  }
}

//- (NSImage *)cachedImageForURL:(NSURL *)url path:(NSString **)cachedPath {
//  NSString *imagePath = [self cachePathForURL:url];
//  NSFileManager *fileManager = [NSFileManager defaultManager];
//  NSImage *image = nil;
//  if ([fileManager fileExistsAtPath:imagePath] == YES) {
//    image = [[NSImage alloc] initWithContentsOfFile:imagePath];
//  }
//  *cachedPath = imagePath;
//  return image;
//}

#pragma mark - Rules

- (NSDictionary *)ruleForURL:(NSURL *)url {
  NSString *rulesPList = [[self ourBundle] pathForResource:@"Rules" ofType:@"plist"];
  NSDictionary *rules = [NSDictionary dictionaryWithContentsOfFile:rulesPList];
  NSDictionary *result = nil;
  NSString *urlString = [url absoluteString];
  for (NSString *src in rules) {
    NSError *regexpError = nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:src options:NSRegularExpressionCaseInsensitive error:&regexpError];
    if (regexpError != nil) {
      NSLog(@"Error parsing regexp: %@; %@", src, regexpError);
      continue;
    }
    NSRange matchingRange = [re rangeOfFirstMatchInString:urlString options:NSMatchingReportCompletion range:NSMakeRange(0, [urlString length])];
    if (matchingRange.location == NSNotFound) {
      continue;
    }
    result = rules[src];
    break;
  }
  return result;
}

#pragma mark - Bundle

- (NSBundle *)ourBundle {
  return [NSBundle bundleForClass:[self class]];
}

#pragma mark - Chat Observing

- (void)webProgressFinished:(NSNotification *)aNotification {
  if ([aNotification.object isKindOfClass:[WebView class]] == YES) {
    [self initWebView:aNotification.object];
  }
}

- (void)messageReceived:(NSNotification *)aNotification {
  AIContentObject *contentObject = aNotification.userInfo[@"AIContentObject"];
  if (contentObject == nil) {
    return;
  }
  NSAttributedString *inAttributedString = contentObject.message;
  NSMutableArray *pathsToRemove = [NSMutableArray array];
  [inAttributedString enumerateAttributesInRange:NSMakeRange(0, inAttributedString.length)
                                         options:0
                                      usingBlock:^(NSDictionary *attrs, NSRange range, BOOL *stop) {
                                        NSURL *link = attrs[NSLinkAttributeName];
                                        NSString *cachedImagePath = nil;
                                        if (link != nil) {
                                          cachedImagePath = [self cachePathForURL:link];
                                        }
                                        
                                        if (cachedImagePath != nil) {
                                          [pathsToRemove addObject:cachedImagePath];
                                        }
                                        
                                      }];
  
  if (pathsToRemove.count > 0) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      NSFileManager *fileManager = [NSFileManager defaultManager];
      for (NSString *path in pathsToRemove) {
        if ([fileManager fileExistsAtPath:path] == YES) {
        NSError *error = nil;
        BOOL result = [fileManager removeItemAtPath:path error:&error];
        if (result == NO) {
          NSLog(@"Error removing cached image file: %@; Error: %@", path, error);
        }
      }
      }
    });
  }
}

- (void)initWebView:(WebView *)webView {
  NSString *cssPath = [[self ourBundle] pathForResource:@"AdiumImgr" ofType:@"css"];
  NSString *js = [NSString stringWithFormat:@"(function(){ \
                  var ourStyleID = \"adiumImgr\"; \
                  var ourStyle = document.querySelector(\"#\" + ourStyleID); \
                  if (!ourStyle) { \
                    ourStyle = document.createElement(\"link\"); \
                    ourStyle.id = ourStyleID; \
                    ourStyle.rel = \"stylesheet\"; \
                    ourStyle.type = \"text/css\"; \
                    ourStyle.href = \"file://%@\"; \
                    document.head.appendChild(ourStyle); \
                  }\
                  \
                  function fixupImages() {\
                    var imgs = document.querySelectorAll('img[src*=\"adiumImgr\"]');\
                    if (!imgs || imgs.length === 0) {\
                      console.log('no images found');\
                      return;\
                    }\
                    for (var i=0; i<imgs.length; i++) {\
                      var img = imgs[i];\
                      try {\
                        var a = img.parentElement.querySelector('a');\
                        if (a) {\
                          img.alt = \"[Image: \"+a.innerText+\"]\";\
                        }\
                      }\
                      catch(e) {\
                        console.log('Error fixing up image: ' + e);\
                      }\
                    }\
                  }\
                  function createVideoElement(url, type) {\
                    var v = document.createElement('video');\
                    v.addEventListener('click', function() {v.controls = !v.controls}, false);\
                    v.controls = false;\
                    v.autoplay = true;\
                    v.loop = true;\
                    var s = document.createElement('source');\
                    s.src = url;\
                    if (type) {\
                      s.type = type;\
                    }\
                    v.appendChild(s);\
                    return v;\
                  }\
                  function parentElementMatchingSelector(startNode, selector) {\
                    var parent = startNode.parentElement;\
                    while (parent) {\
                      if (parent.webkitMatchesSelector(selector)) {\
                        break;\
                      }\
                      parent = parent.parentElement;\
                    }\
                    return parent;\
                  }\
                  function fixupVideo() {\
                    if (window.client) {\
                      var videoURLs = JSON.parse(window.client.videoURLs());\
                      if (videoURLs) {\
                        var sel = window.getSelection();\
                        for (var url in videoURLs) {\
                          var videoURL = videoURLs[url]['videoURL'];\
                          var type = videoURLs[url]['type'];\
                          while (find(url)) {\
                            var baseNode = sel.baseNode;\
                            var a = (baseNode) ? parentElementMatchingSelector(baseNode, 'a') : null;\
                            var parent = (a) ? a.parentElement : null;\
                            if (parent && !parent.querySelector(\"video source[src=\\\"\"+videoURL+\"\\\"]\")) {\
                              var video = createVideoElement(videoURL, type); \
                              parent.insertBefore(video, a);\
                              parent.insertBefore(document.createElement('br', a));\
                            }\
                          }\
                        }\
                      }\
                    }\
                  }\
                  function domChangeHandler(){\
                    fixupImages();\
                    fixupVideo();\
                  }\
                  window['fixupImages'] = fixupImages;\
                  var fixupImagesTimeout = null;\
                  function domModified() {\
                    if (fixupImagesTimeout != null) {\
                      clearTimeout(fixupImagesTimeout); \
                    }\
                    setTimeout(domChangeHandler, 1000);\
                    document.removeEventListener('DOMSubtreeModified', domModified, false);\
                  }\
                  document.addEventListener('DOMSubtreeModified', domModified, false);\
                  })()", cssPath];
  [webView stringByEvaluatingJavaScriptFromString:js];
  [[webView windowScriptObject] setValue:self forKey:@"client"];
}

- (NSString *)videoURLs {
  NSLog(@"%s", __PRETTY_FUNCTION__);
  NSError *error;
  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:_videoURLs
                                                     options:NSJSONWritingPrettyPrinted
                                                       error:&error];
  NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
  return jsonString;
}

+ (BOOL)isSelectorExcludedFromWebScript:(SEL)selector {
  if (selector == @selector(videoURLs)) {
    return NO;
  }
  return YES;
}

+ (NSString *)webScriptNameForSelector:(SEL)selector {
  if (selector == @selector(videoURLs)) {
    return @"videoURLs";
  }
  return nil;
}

@end
