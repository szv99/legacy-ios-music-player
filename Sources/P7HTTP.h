#import <Foundation/Foundation.h>

// Blocking HTTP for background threads (the in-app server, the extractor script, Subsonic).
//
// iOS 7's trust store is from 2014: it lacks roots that most of today's sites chain to
// (Let's Encrypt's ISRG Root X1, Google Trust Services, ...). When the system rejects a
// certificate, it is evaluated again against the Mozilla root bundle shipped in the app
// (Resources/cacert.pem), so those sites still work over a properly verified connection.
@interface P7HTTP : NSObject

// Never call on the main thread. Returns the body (possibly empty) for any HTTP status;
// nil only on a network error.
+ (NSData *)sendRequest:(NSURLRequest *)request response:(NSHTTPURLResponse **)response error:(NSError **)error;
+ (NSData *)GET:(NSURL *)url response:(NSHTTPURLResponse **)response error:(NSError **)error;

// For NSURLSession delegates elsewhere in the app that should accept the same certificates.
+ (void)handleChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler;

@end
