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

@implementation AdiumImgr {
  NSMutableDictionary *_processInfo;
  NSMutableDictionary *_parserInfo;
}

#pragma mark - AIPlugin

- (void) installPlugin {
  [self clearCache];
  [[adium contentController] registerDelayedContentFilter:self ofType:AIFilterMessageDisplay direction:AIFilterIncoming];
  
  _processInfo = [NSMutableDictionary dictionary];
  _parserInfo = [NSMutableDictionary dictionary];
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

- (void) uninstallPlugin {
  [[adium contentController] unregisterDelayedContentFilter:self];
  _processInfo = nil;
  _parserInfo = nil;
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - AIContentFilter

- (CGFloat)filterPriority {
  return DEFAULT_FILTER_PRIORITY;
}

#pragma mark - AIDelayedCotentFilter

- (BOOL)delayedFilterAttributedString:(NSAttributedString *)inAttributedString
                              context:(id)context
                             uniqueID:(unsigned long long)uniqueID
{
  //XXX dump strings to console so that we don't miss anything while debuggig
  NSLog(@"Delaying string: %@", inAttributedString.string);
  __block BOOL foundLink = NO;
  [inAttributedString enumerateAttributesInRange:NSMakeRange(0, inAttributedString.length)
                                         options:0
                                      usingBlock:^(NSDictionary *attrs, NSRange range, BOOL *stop) {
                                        NSURL *link = attrs[NSLinkAttributeName];
                                        NSString *scheme = [link scheme];
                                        
                                        if ([@"http" isEqualToString:scheme] == YES || [@"https" isEqualToString:scheme] == YES) {
                                          NSString *linkString = [link absoluteString];
                                          NSMutableArray *linkInfo = _processInfo[linkString];
                                          if (linkInfo == nil) {
                                            linkInfo = [NSMutableArray array];
                                            _processInfo[linkString] = linkInfo;
                                          }
                                          NSMutableDictionary *info = [NSMutableDictionary dictionary];
                                          if (inAttributedString != nil) {
                                            info[@"attributedString"] = inAttributedString;
                                          }
                                          if (attrs != nil) {
                                            info[@"attributes"] = attrs;
                                          }
                                          info[@"uniqueID"] = @(uniqueID);
                                          info[@"range"] = NSStringFromRange(range);
                                          if (link != nil) {
                                            info[@"url"] = link;
                                          }
                                          if (context != nil) {
                                            info[@"context"] = context;
                                          }
                                          [linkInfo addObject:info];
                                          foundLink = YES;
                                        }
                                      }];
  
  if (foundLink == YES) {
    [self preProcess];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      [self process];
    });
  }
  
  return foundLink;
}

#pragma mark - Processing

- (void)preProcess {
}

- (void)process {
  NSDictionary *processInfo = _processInfo;
  for (NSString *urlString in processInfo) {
    NSArray *infos = processInfo[urlString];
    for (NSDictionary *info in infos) {
      NSURL *url = info[@"url"];
      NSAttributedString *attributedString = info[@"attributedString"];
      unsigned long long uniqueID = [info[@"uniqueID"] unsignedLongLongValue];
      NSRange range = NSRangeFromString(info[@"range"]);
      NSDictionary *attributes = info[@"attributes"];
      id context = info[@"context"];
      
      NSString *imagePath = nil;
      NSImage *image = [self cachedImageForURL:url path:&imagePath];
      if (image != nil) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
          [self processImage:image
                         url:url
                        path:imagePath
   postImageAttributedString:nil
            attributedString:attributedString
                       range:range
                  attributes:attributes
                     context:context
                    uniqueID:uniqueID];
        });
      }
      else {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
          [self processURL:url
          attributedString:attributedString
                     range:range
                attributes:attributes
                   context:context
                  uniqueID:uniqueID];
        });
      }
    }
  }
}

- (BOOL)hasPendingProcessesForUniqueID:(unsigned long long)uniqueID {
  if (_processInfo.count == 0) {
    return NO;
  }
  NSArray *ids = [[_processInfo allValues] valueForKeyPath:@"@distinctUnionOfArrays.uniqueID"];
  for (NSNumber *i in ids) {
    if ([i unsignedLongLongValue] == uniqueID) {
      return YES;
    }
  }
  return NO;
}

- (void)processURL:(NSURL *)url
  attributedString:(NSAttributedString *)inAttributedString
             range:(NSRange)range
        attributes:(NSDictionary *)attributes
           context:(id)context
          uniqueID:(unsigned long long)uniqueID
{
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
  BOOL handled = NO;
  if ([contentType containsString:@"image/"] == YES) {
    handled = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      [self processImageFromURL:url
                     linkedFrom:url
      postImageAttributedString:nil
               attributedString:inAttributedString
                          range:range
                     attributes:attributes
                        context:context
                       uniqueID:uniqueID];
    });
  }
  else if ([contentType containsString:@"text/html"] == YES) {
    NSDictionary *rules = [self ruleForURL:url];
    if (rules.count > 0) {
      handled = YES;
      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self processHTMLFromURL:url
               forImageWithRules:rules
                attributedString:inAttributedString
                           range:range
                      attributes:attributes
                         context:context
                        uniqueID:uniqueID];
      });
    }
  }
  if (handled == NO) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self didProcessImageURL:url
              attributedString:inAttributedString
                      uniqueID:uniqueID];
    });
  }
}

- (void)processImageFromURL:(NSURL *)url
                 linkedFrom:(NSURL *)linkURL
  postImageAttributedString:(NSAttributedString *)postImageAttributedString
           attributedString:(NSAttributedString *)inAttributedString
                      range:(NSRange)range
                 attributes:(NSDictionary *)attributes
                    context:(id)context
                   uniqueID:(unsigned long long)uniqueID
{
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:3.0];
  NSHTTPURLResponse *response = nil;
  NSError *error = nil;
  NSData *imageData = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
  if (error != nil) {
    NSLog(@"Error fetching image from URL: %@", url);
    [self didProcessImageURL:url
            attributedString:inAttributedString
                    uniqueID:uniqueID];
    return;
  }
  NSString *cachedPath = nil;
  NSURL *referencingURL = (linkURL != nil) ? linkURL : url;
  if (imageData != nil && [self cacheImageData:imageData forURL:referencingURL cachedPath:&cachedPath] == YES) {
    NSImage *image = [[NSImage alloc] initWithData:imageData];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      [self processImage:image
                     url:url
                    path:cachedPath
postImageAttributedString:postImageAttributedString
        attributedString:inAttributedString
                   range:range
              attributes:attributes
                 context:context
                uniqueID:uniqueID];
    });
  }
  else {
    NSLog(@"Failed to fetch and save image: %@", url);
    [self didProcessImageURL:url
            attributedString:inAttributedString
                    uniqueID:uniqueID];
  }
}

- (void)processHTMLFromURL:(NSURL *)url
         forImageWithRules:(NSDictionary *)rules
          attributedString:(NSAttributedString *)inAttributedString
                     range:(NSRange)range
                attributes:(NSDictionary *)attrs
                   context:(id)context
                  uniqueID:(unsigned long long)uniqueID
{
  if ([NSThread isMainThread] == NO) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self processHTMLFromURL:url
             forImageWithRules:rules
              attributedString:inAttributedString
                         range:range
                    attributes:attrs
                       context:context
                      uniqueID:uniqueID];
    });
    return;
  }
  
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReturnCacheDataElseLoad timeoutInterval:3.0];
  NSHTTPURLResponse *response = nil;
  NSError *requestError = nil;
  NSData *htmlData = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&requestError];
  if (requestError != nil) {
    NSLog(@"Error fetching HTML from URL '%@': %@", [url absoluteString], requestError);
    [self didProcessImageURL:url
            attributedString:inAttributedString
                    uniqueID:uniqueID];
  }
  else if (htmlData.length == 0){
    NSLog(@"Empty HTML from URL '%@'", [url absoluteString]);
    [self didProcessImageURL:url
            attributedString:inAttributedString
                    uniqueID:uniqueID];
  }
  else {
    NSString *html = [[NSString alloc] initWithData:htmlData encoding:NSUTF8StringEncoding];
    HTMLDocument *doc = [HTMLDocument documentWithString:html];
    NSMutableSet *foundURLs = [NSMutableSet set];
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
      NSMutableDictionary *textAttributes = [attrs mutableCopy];
      [textAttributes removeObjectForKey:NSLinkAttributeName];
      postImageString = [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"[1 of %i]", (int)foundURLs.count] attributes:textAttributes];
    }
    
    NSURL *imageURL = [NSURL URLWithString:[[foundURLs allObjects] firstObject]];
    
    if (imageURL != nil) {
      [self didProcessHTMLFromURL:url uniqueID:uniqueID];
      [self processImageFromURL:imageURL
                     linkedFrom:url
      postImageAttributedString:postImageString
               attributedString:inAttributedString
                          range:range
                     attributes:attrs
                        context:context
                       uniqueID:uniqueID];
    }
    else {
      NSLog(@"Failed to process HTML for image URL");
      [self didProcessImageURL:url
              attributedString:inAttributedString
                      uniqueID:uniqueID];
    }
  }
}

- (void)processImage:(NSImage *)image
                 url:(NSURL *)url
                path:(NSString *)imagePath
postImageAttributedString:(NSAttributedString *)postImageAttributedString
    attributedString:(NSAttributedString *)inAttributedString
               range:(NSRange)range
          attributes:(NSDictionary *)attributes
             context:(id)context
            uniqueID:(unsigned long long)uniqueID
{
  AITextAttachmentExtension *attachment = [[AITextAttachmentExtension alloc] init];
  NSTextAttachmentCell *cell = [[NSTextAttachmentCell alloc] initImageCell:image];
  [attachment setAttachmentCell:cell];
  [attachment setPath:imagePath];
  [attachment setHasAlternate:NO];
  [attachment setImageClass:@"scaledToFitImage"];
  [attachment setShouldAlwaysSendAsText:NO];
  NSURL *link = attributes[NSLinkAttributeName];
  if (link == nil) {
    link = url;
  }
  NSString *altText = [NSString stringWithFormat:@"[Image: %@]", [[inAttributedString string] substringWithRange:range]];
  [attachment setString:altText];
  
  NSMutableAttributedString *imageString = [[NSAttributedString attributedStringWithAttachment:attachment] mutableCopy];
  [imageString addAttribute:NSAttachmentAttributeName value:attachment range:NSMakeRange(0, imageString.length)];
  
  NSMutableAttributedString *newString = [inAttributedString mutableCopy];
  NSMutableAttributedString *replacementString = [[NSMutableAttributedString alloc] init];
  NSMutableDictionary *textAttributes = [attributes mutableCopy];
  [textAttributes removeObjectForKey:NSLinkAttributeName];
  if (range.location > 0) {
    [replacementString appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:textAttributes]];
  }
  [replacementString appendAttributedString:imageString];
  if (postImageAttributedString != nil) {
    [replacementString appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:textAttributes]];
    [replacementString appendAttributedString:postImageAttributedString];
  }
  [replacementString appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:textAttributes]];
  [newString insertAttributedString:replacementString atIndex:range.location];
  
  [self didProcessImageURL:url
          attributedString:newString
                  uniqueID:uniqueID];
}

- (void)didProcessImageURL:(NSURL *)url
          attributedString:(NSAttributedString *)attributedString
                  uniqueID:(unsigned long long)uniqueID
{
  [self removeProcessInfoForURL:url uniqueID:uniqueID];
  
  BOOL hasPendingProcesses = [self hasPendingProcessesForUniqueID:uniqueID];
  if (hasPendingProcesses == NO) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [[adium contentController] delayedFilterDidFinish:attributedString uniqueID:uniqueID];
    });
  }
}

- (void)didProcessHTMLFromURL:(NSURL *)url uniqueID:(unsigned long long)uniqueID {
  [self removeProcessInfoForURL:url uniqueID:uniqueID];
}

- (void)removeProcessInfoForURL:(NSURL *)url uniqueID:(unsigned long long)uniqueID {
  NSMutableArray *infoArray = _processInfo[[url absoluteString]];
  if (infoArray == nil) {
    return;
  }
  for (NSDictionary *info in infoArray) {
    unsigned long long infoUniqueID = [info[@"uniqueID"] unsignedLongLongValue];
    if (infoUniqueID != uniqueID) {
      continue;
    }
    [infoArray removeObject:info];
    break;
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

- (NSImage *)cachedImageForURL:(NSURL *)url path:(NSString **)cachedPath {
  NSString *imagePath = [self cachePathForURL:url];
  NSFileManager *fileManager = [NSFileManager defaultManager];
  NSImage *image = nil;
  if ([fileManager fileExistsAtPath:imagePath] == YES) {
    image = [[NSImage alloc] initWithContentsOfFile:imagePath];
  }
  *cachedPath = imagePath;
  return image;
}

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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      NSFileManager *fileManager = [NSFileManager defaultManager];
      for (NSString *path in pathsToRemove) {
        NSError *error = nil;
        BOOL result = [fileManager removeItemAtPath:path error:&error];
        if (result == NO) {
          NSLog(@"Error removing cached image file: %@; Error: %@", path, error);
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
                  window['fixupImages'] = fixupImages;\
                  var fixupImagesTimeout = null;\
                  function doFixupImages() {\
                    if (fixupImagesTimeout != null) {\
                      clearTimeout(fixupImagesTimeout); \
                    }\
                    setTimeout(fixupImages, 1000);\
                    document.removeEventListener('DOMSubtreeModified', doFixupImages, false);\
                  }\
                  document.addEventListener('DOMSubtreeModified', doFixupImages, false);\
                  })()", cssPath];
  [webView stringByEvaluatingJavaScriptFromString:js];
}

@end
